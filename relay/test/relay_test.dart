import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:meshenger_relay/meshenger_relay.dart';
import 'package:test/test.dart';

/// Integration test of the relay over real sockets on localhost: two
/// simulated phones (real Ed25519 identities, real wire protocol) with the
/// relay in the middle. Proves store-and-forward for an offline recipient,
/// via-path/hop bookkeeping, dedup, and gossip re-flooding — all without
/// the relay ever holding a message key.
void main() {
  late Directory tmp;
  late RelayCore core;
  late LanTransport lan;
  late _Phone alice;
  late _Phone bob;

  // Isolated discovery port so a Meshenger app or relay running on this
  // machine (both bind 45654) can't swallow the test announcements.
  final discoveryPort =
      45700 + DateTime.now().millisecondsSinceEpoch % 200;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meshenger-relay-test');
    final identity =
        await RelayIdentity.loadOrCreate('${tmp.path}/identity.json');
    lan = LanTransport(
      identity: identity,
      log: (_) {},
      discoveryPort: discoveryPort,
    );
    core = RelayCore(
      identity: identity,
      name: 'Test Relay',
      maxSpool: 16,
      transports: [lan],
    );
    await lan.start();
    await core.start();

    alice = await _Phone.create('alice');
    bob = await _Phone.create('bob');
  });

  tearDown(() async {
    await core.stop();
    await alice.close();
    await bob.close();
    await tmp.delete(recursive: true);
  });

  test('spools for an offline peer, delivers on arrival, dedups', () async {
    // Alice comes into the relay's range; Bob is nowhere to be seen.
    await alice.announceTo(discoveryPort);
    await _until(() => lan.onlinePeers.contains(alice.address));

    final envelope = <String, Object?>{
      't': 'msg',
      'id': 'env-1',
      'from': alice.address,
      'to': bob.address,
      'fromX': 'ciphertext-key-material',
      'cipher': base64Encode(utf8.encode('sealed-bytes-the-relay-cant-read')),
      'hops': 0,
      'max': 6,
      'via': const <String>[],
      'exp': DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    };

    // Alice hands the envelope to the relay (transport ack must succeed).
    expect(await alice.sendTo(lan.tcpPort!, envelope), isTrue);

    // Give the relay a beat: nothing can be delivered yet.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(bob.received, isEmpty);

    // Bob walks into range.
    await bob.announceTo(discoveryPort);
    final delivered = await bob.nextPacketWhere((p) => p['t'] == 'msg');

    expect(delivered['id'], 'env-1');
    expect(delivered['to'], bob.address);
    expect(delivered['hops'], 1);
    expect(
      (delivered['via'] as List).cast<String>(),
      contains(core.identity.address),
    );
    // The sealed content passed through untouched.
    expect(delivered['cipher'], envelope['cipher']);

    // A duplicate from Alice is dropped, not re-delivered.
    final before = bob.received.where((p) => p['t'] == 'msg').length;
    await alice.sendTo(lan.tcpPort!, envelope);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final after = bob.received.where((p) => p['t'] == 'msg').length;
    expect(after, before);
  });

  test('re-floods gossip so strangers learn about each other', () async {
    await alice.announceTo(discoveryPort);
    await bob.announceTo(discoveryPort);
    await _until(() =>
        lan.onlinePeers.containsAll({alice.address, bob.address}));

    final gossip = await alice.buildGossip(nickname: 'Alice');
    expect(await alice.sendTo(lan.tcpPort!, gossip), isTrue);

    final heard = await bob.nextPacketWhere(
      (p) => p['t'] == 'gossip' && p['addr'] == alice.address,
    );
    expect(heard['nick'], 'Alice');
    expect(heard['hops'], 1);

    // The relay also gossips its own presence with its public name.
    final relayGossip = await bob.nextPacketWhere(
      (p) => p['t'] == 'gossip' && p['addr'] == core.identity.address,
      timeout: const Duration(seconds: 30),
    );
    expect(relayGossip['nick'], 'Test Relay');
  });
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// A minimal "phone": an Ed25519 identity plus a TCP inbox speaking the
/// Meshenger LAN wire protocol (newline JSON + ack).
class _Phone {
  final String label;
  final SimpleKeyPair keyPair;
  final String address;
  final String x25519;
  final ServerSocket server;
  final List<Map<String, Object?>> received = [];
  final StreamController<Map<String, Object?>> _incoming =
      StreamController.broadcast();

  _Phone._(this.label, this.keyPair, this.address, this.x25519, this.server) {
    server.listen((socket) async {
      try {
        final line = await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        final packet =
            (jsonDecode(line) as Map).cast<String, Object?>();
        socket.write('${jsonEncode({'t': 'ack', 'id': packet['id']})}\n');
        await socket.flush();
        socket.destroy();
        received.add(packet);
        _incoming.add(packet);
      } catch (_) {
        socket.destroy();
      }
    });
  }

  static Future<_Phone> create(String label) async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final address = base64Encode(publicKey.bytes);

    final seed = await keyPair.extractPrivateKeyBytes();
    final derived = await Sha256().hash(<int>[
      ...utf8.encode('meshenger-x25519-v1'),
      ...seed,
    ]);
    final x = await X25519().newKeyPairFromSeed(derived.bytes);
    final xPub = base64Encode((await x.extractPublicKey()).bytes);

    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _Phone._(label, keyPair, address, xPub, server);
  }

  Future<String> _sign(String message) async {
    final sig = await Ed25519().sign(utf8.encode(message), keyPair: keyPair);
    return base64Encode(sig.bytes);
  }

  /// Announces this phone to the relay's UDP discovery port — unicast to
  /// localhost so the test is deterministic.
  Future<void> announceTo(int discoveryPort) async {
    final sig = await _sign('announce|$address|$x25519|${server.port}');
    final payload = utf8.encode(jsonEncode({
      't': 'announce',
      'addr': address,
      'x25519': x25519,
      'port': server.port,
      'sig': sig,
    }));
    final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    udp.send(payload, InternetAddress.loopbackIPv4, discoveryPort);
    // A couple of repeats in case the first datagram races the bind.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    udp.send(payload, InternetAddress.loopbackIPv4, discoveryPort);
    udp.close();
  }

  Future<Map<String, Object?>> buildGossip({required String nickname}) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await _sign('gossip|$address|$x25519|$nickname|$ts');
    return {
      't': 'gossip',
      'addr': address,
      'x25519': x25519,
      'nick': nickname,
      'ts': ts,
      'sig': sig,
      'hops': 0,
      'max': 6,
    };
  }

  Future<bool> sendTo(int tcpPort, Map<String, Object?> packet) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        tcpPort,
        timeout: const Duration(seconds: 5),
      );
      socket.write('${jsonEncode(packet)}\n');
      await socket.flush();
      final response = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      socket.destroy();
      final ack = jsonDecode(response);
      return ack is Map && ack['t'] == 'ack';
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, Object?>> nextPacketWhere(
    bool Function(Map<String, Object?>) predicate, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    for (final packet in received) {
      if (predicate(packet)) return packet;
    }
    return _incoming.stream.firstWhere(predicate).timeout(timeout);
  }

  Future<void> close() async {
    await server.close();
    await _incoming.close();
  }
}
