// Meshenger relay daemon: a headless mesh gateway.
//
// Speaks the same LAN wire protocol as the Meshenger app:
//   - UDP discovery on port 45654 (signed announcements)
//   - newline-delimited JSON packets over TCP, acked per packet
//
// What it does:
//   - stores and forwards encrypted message envelopes it CANNOT read
//     (only the final recipient holds the private key)
//   - re-floods gossip so devices learn about nodes beyond radio range
//   - keeps envelopes spooled until the recipient appears or they expire
//
// Run it on a Raspberry Pi (or anything with the Dart SDK):
//   cd relay && dart pub get && dart run bin/relay.dart
// Or compile a native binary:
//   dart compile exe bin/relay.dart -o meshenger-relay
//
// Options:
//   --name <label>       Public name shown on peers' Mesh Maps (default: Relay)
//   --identity <path>    Where the relay keypair persists
//                        (default: relay-identity.json next to the binary)
//   --max-spool <n>      Max envelopes carried at once (default 256)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

const int discoveryPort = 45654;
const Duration announceInterval = Duration(seconds: 3);
const Duration peerTimeout = Duration(seconds: 10);
const Duration gossipInterval = Duration(seconds: 25);
const int defaultMaxHops = 6;
const Duration defaultEnvelopeLifetime = Duration(hours: 48);

late final SimpleKeyPair identityKeyPair;
late final String myAddress; // base64 Ed25519 public key
late final String myX25519; // base64 X25519 public key
String relayName = 'Relay';
int maxSpool = 256;

final Map<String, RelayPeer> peers = <String, RelayPeer>{};
final Set<String> seenEnvelopes = <String>{};
final List<String> seenOrder = <String>[];
final List<Map<String, Object?>> spool = <Map<String, Object?>>[];
final Map<String, Set<String>> offeredTo = <String, Set<String>>{};
final Map<String, int> gossipFreshness = <String, int>{}; // addr -> ts

ServerSocket? server;
RawDatagramSocket? udp;

void log(String message) {
  final now = DateTime.now().toIso8601String().substring(11, 19);
  stdout.writeln('[$now] $message');
}

Future<void> main(List<String> args) async {
  // A planted gateway must never die from a transient socket error.
  await runZonedGuarded(() => _run(args), (error, stack) {
    log('Recovered from error: $error');
  });
}

Future<void> _run(List<String> args) async {
  for (var i = 0; i < args.length - 1; i++) {
    switch (args[i]) {
      case '--name':
        relayName = args[i + 1];
      case '--max-spool':
        maxSpool = int.tryParse(args[i + 1]) ?? maxSpool;
    }
  }
  final identityPath = _argValue(args, '--identity') ??
      '${File(Platform.script.toFilePath()).parent.path}/relay-identity.json';

  await _loadOrCreateIdentity(identityPath);
  log('Meshenger relay "$relayName"');
  log('Address: $myAddress');
  log('This node forwards encrypted envelopes it cannot read.');

  // TCP packet server on an ephemeral port.
  server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
  server!.listen(_handleConnection);
  log('TCP inbox on port ${server!.port}');

  // UDP discovery.
  udp = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4,
    discoveryPort,
    reuseAddress: true,
  );
  udp!.broadcastEnabled = true;
  udp!.listen(
    (event) {
      if (event == RawSocketEvent.read) {
        final datagram = udp!.receive();
        if (datagram != null) _handleAnnouncement(datagram);
      }
    },
    onError: (Object _) {
      // Broadcast sends to unreachable interfaces surface here; harmless.
    },
  );

  await _announce();
  Timer.periodic(announceInterval, (_) => _announce());
  Timer.periodic(peerTimeout, (_) => _reapPeers());
  Timer.periodic(gossipInterval, (_) async {
    await _broadcastOwnGossip();
    _pruneSpool();
    await _offerSpool();
  });

  log('Relay running. Ctrl-C to stop.');
}

String? _argValue(List<String> args, String flag) {
  final idx = args.indexOf(flag);
  if (idx < 0 || idx + 1 >= args.length) return null;
  return args[idx + 1];
}

// ---------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------

Future<void> _loadOrCreateIdentity(String path) async {
  final ed25519 = Ed25519();
  final file = File(path);
  if (await file.exists()) {
    final decoded = jsonDecode(await file.readAsString()) as Map;
    final seed = base64Decode(decoded['seed'] as String);
    identityKeyPair = await ed25519.newKeyPairFromSeed(seed);
    log('Loaded relay identity from $path');
  } else {
    identityKeyPair = await ed25519.newKeyPair();
    final seed = await identityKeyPair.extractPrivateKeyBytes();
    await file.writeAsString(jsonEncode({'seed': base64Encode(seed)}));
    log('Created new relay identity at $path');
  }

  final publicKey = await identityKeyPair.extractPublicKey();
  myAddress = base64Encode(publicKey.bytes);

  // Deterministic X25519 key, same derivation as the app.
  final seed = await identityKeyPair.extractPrivateKeyBytes();
  final derived = await Sha256().hash(<int>[
    ...utf8.encode('meshenger-x25519-v1'),
    ...seed,
  ]);
  final x = await X25519().newKeyPairFromSeed(derived.bytes);
  final xPub = await x.extractPublicKey();
  myX25519 = base64Encode(xPub.bytes);
}

Future<String> _sign(String message) async {
  final signature =
      await Ed25519().sign(utf8.encode(message), keyPair: identityKeyPair);
  return base64Encode(signature.bytes);
}

// ---------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------

Future<void> _announce() async {
  final sock = udp;
  final srv = server;
  if (sock == null || srv == null) return;

  final sig = await _sign('announce|$myAddress|$myX25519|${srv.port}');
  final payload = utf8.encode(jsonEncode(<String, Object?>{
    't': 'announce',
    'addr': myAddress,
    'x25519': myX25519,
    'port': srv.port,
    'sig': sig,
  }));

  final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
  try {
    for (final iface
        in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final addr in iface.addresses) {
        final parts = addr.address.split('.');
        if (parts.length == 4) {
          targets.add(
              InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }
    }
  } catch (_) {}

  for (final target in targets) {
    try {
      sock.send(payload, target, discoveryPort);
    } catch (_) {}
  }
}

Future<void> _handleAnnouncement(Datagram datagram) async {
  try {
    final decoded = jsonDecode(utf8.decode(datagram.data));
    if (decoded is! Map || decoded['t'] != 'announce') return;

    final addr = decoded['addr'] as String?;
    final x25519 = decoded['x25519'] as String?;
    final port = (decoded['port'] as num?)?.toInt();
    final sig = decoded['sig'] as String?;
    if (addr == null || x25519 == null || port == null || sig == null) return;
    if (addr == myAddress) return;

    final valid = await _verify(
      'announce|$addr|$x25519|$port',
      sig,
      addr,
    );
    if (!valid) return;

    final isNew = !peers.containsKey(addr);
    peers[addr] = RelayPeer(
      address: addr,
      host: datagram.address,
      port: port,
      lastSeen: DateTime.now(),
    );
    if (isNew) {
      log('Peer online: ${_shortAddr(addr)} (${datagram.address.address})');
      await _offerSpoolToPeer(peers[addr]!);
      await _broadcastOwnGossip();
    }
  } catch (_) {}
}

Future<bool> _verify(String message, String sigB64, String addrB64) async {
  try {
    final publicKey = SimplePublicKey(
      base64Decode(addrB64),
      type: KeyPairType.ed25519,
    );
    return await Ed25519().verify(
      utf8.encode(message),
      signature: Signature(base64Decode(sigB64), publicKey: publicKey),
    );
  } catch (_) {
    return false;
  }
}

void _reapPeers() {
  final now = DateTime.now();
  final stale = peers.values
      .where((p) => now.difference(p.lastSeen) > peerTimeout * 3)
      .map((p) => p.address)
      .toList();
  for (final addr in stale) {
    peers.remove(addr);
    log('Peer offline: ${_shortAddr(addr)}');
  }
}

String _shortAddr(String address) =>
    address.length <= 12 ? address : '${address.substring(0, 12)}…';

// ---------------------------------------------------------------------
// Packet handling
// ---------------------------------------------------------------------

Future<void> _handleConnection(Socket socket) async {
  try {
    final line = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 20));

    final decoded = jsonDecode(line);
    if (decoded is! Map || decoded['t'] is! String) {
      socket.destroy();
      return;
    }
    final packet = decoded.cast<String, Object?>();

    socket.write(
        '${jsonEncode(<String, Object?>{'t': 'ack', 'id': packet['id']})}\n');
    await socket.flush();
    socket.destroy();

    switch (packet['t']) {
      case 'msg':
        await _relayEnvelope(packet);
      case 'gossip':
        await _handleGossip(packet);
    }
  } catch (_) {
    socket.destroy();
  }
}

Future<void> _relayEnvelope(Map<String, Object?> packet) async {
  final id = packet['id'];
  final to = packet['to'];
  if (id is! String || to is! String) return;

  if (seenEnvelopes.contains(id)) return;
  seenEnvelopes.add(id);
  seenOrder.add(id);
  while (seenOrder.length > 8192) {
    seenEnvelopes.remove(seenOrder.removeAt(0));
  }

  final exp = (packet['exp'] as num?)?.toInt();
  if (exp != null && exp < DateTime.now().millisecondsSinceEpoch) return;

  final hops = ((packet['hops'] as num?)?.toInt() ?? 0) + 1;
  final maxHops = (packet['max'] as num?)?.toInt() ?? defaultMaxHops;

  final envelope = Map<String, Object?>.from(packet);
  envelope['hops'] = hops;
  envelope['via'] = [
    ...((packet['via'] as List?)?.whereType<String>() ?? const <String>[]),
    myAddress,
  ];
  if (envelope['exp'] == null) {
    envelope['exp'] = DateTime.now()
        .add(defaultEnvelopeLifetime)
        .millisecondsSinceEpoch;
  }

  // Direct delivery to the recipient doesn't count against the hop cap.
  final recipient = peers[to];
  if (recipient != null) {
    if (await _sendPacket(recipient, envelope)) {
      log('Delivered envelope ${id.substring(0, 8)} to ${_shortAddr(to)}');
      return;
    }
  }

  if (hops > maxHops) return;

  spool.add(envelope);
  while (spool.length > maxSpool) {
    final dropped = spool.removeAt(0);
    offeredTo.remove(dropped['id']);
  }
  log('Carrying envelope ${id.substring(0, 8)} for ${_shortAddr(to)} '
      '(hop $hops/$maxHops, spool ${spool.length})');

  final from = packet['from'] as String?;
  final via = (envelope['via'] as List).whereType<String>().toSet();
  for (final peer in peers.values) {
    if (peer.address == from || via.contains(peer.address)) continue;
    _noteOffered(id, peer.address);
    unawaited(_sendPacket(peer, envelope));
  }
}

Future<void> _handleGossip(Map<String, Object?> packet) async {
  final addr = packet['addr'] as String?;
  final ts = (packet['ts'] as num?)?.toInt();
  if (addr == null || ts == null || addr == myAddress) return;

  final known = gossipFreshness[addr];
  if (known != null && known >= ts) return;
  gossipFreshness[addr] = ts;

  final hops = ((packet['hops'] as num?)?.toInt() ?? 0) + 1;
  final maxHops = (packet['max'] as num?)?.toInt() ?? defaultMaxHops;
  if (hops > maxHops) return;

  final forwarded = Map<String, Object?>.from(packet);
  forwarded['hops'] = hops;
  for (final peer in peers.values) {
    if (peer.address == addr) continue;
    unawaited(_sendPacket(peer, forwarded));
  }
}

Future<void> _broadcastOwnGossip() async {
  final ts = DateTime.now().millisecondsSinceEpoch;
  final sig = await _sign('gossip|$myAddress|$myX25519|$relayName|$ts');
  final gossip = <String, Object?>{
    't': 'gossip',
    'addr': myAddress,
    'x25519': myX25519,
    'nick': relayName,
    'ts': ts,
    'sig': sig,
    'hops': 0,
    'max': defaultMaxHops,
  };
  for (final peer in peers.values) {
    unawaited(_sendPacket(peer, gossip));
  }
}

// ---------------------------------------------------------------------
// Spool
// ---------------------------------------------------------------------

void _noteOffered(String id, String peerAddress) {
  offeredTo.putIfAbsent(id, () => <String>{}).add(peerAddress);
}

void _pruneSpool() {
  final now = DateTime.now().millisecondsSinceEpoch;
  spool.removeWhere((envelope) {
    final exp = (envelope['exp'] as num?)?.toInt();
    final expired = exp != null && exp < now;
    if (expired) offeredTo.remove(envelope['id']);
    return expired;
  });
}

Future<void> _offerSpool() async {
  for (final peer in peers.values.toList()) {
    await _offerSpoolToPeer(peer);
  }
}

Future<void> _offerSpoolToPeer(RelayPeer peer) async {
  final delivered = <Map<String, Object?>>[];
  for (final envelope in spool.toList()) {
    final id = envelope['id'] as String? ?? '';
    final to = envelope['to'] as String?;
    final from = envelope['from'] as String?;
    final via =
        (envelope['via'] as List?)?.whereType<String>().toSet() ?? {};

    if (to == peer.address) {
      if (await _sendPacket(peer, envelope)) {
        delivered.add(envelope);
        log('Spooled envelope ${id.substring(0, 8)} reached '
            '${_shortAddr(peer.address)}');
      }
      continue;
    }
    if (peer.address == from || via.contains(peer.address)) continue;
    if (offeredTo[id]?.contains(peer.address) ?? false) continue;
    _noteOffered(id, peer.address);
    unawaited(_sendPacket(peer, envelope));
  }
  for (final envelope in delivered) {
    spool.remove(envelope);
    offeredTo.remove(envelope['id']);
  }
}

// ---------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------

Future<bool> _sendPacket(RelayPeer peer, Map<String, Object?> packet) async {
  try {
    final socket = await Socket.connect(
      peer.host,
      peer.port,
      timeout: const Duration(seconds: 5),
    );
    socket.write('${jsonEncode(packet)}\n');
    await socket.flush();
    final response = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    socket.destroy();
    final ack = jsonDecode(response);
    return ack is Map && ack['t'] == 'ack';
  } catch (_) {
    return false;
  }
}

class RelayPeer {
  final String address;
  final InternetAddress host;
  final int port;
  DateTime lastSeen;

  RelayPeer({
    required this.address,
    required this.host,
    required this.port,
    required this.lastSeen,
  });
}
