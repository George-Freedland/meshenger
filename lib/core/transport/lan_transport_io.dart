import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/incoming_message.dart';
import '../services/identity_service.dart';
import 'envelope_codec.dart';
import 'mesh_transport.dart';

/// Desktop/mobile LAN transport.
///
/// Discovery: every device broadcasts a signed UDP announcement
/// (`address`, X25519 key, TCP port) on port 45654 every 3 seconds.
/// Delivery: messages are end-to-end encrypted (X25519 ECDH + AES-256-GCM),
/// signed with the sender's Ed25519 identity key, and sent over a direct
/// TCP connection. The receiver replies with an ack only after the
/// signature verifies and decryption succeeds.
class _IoLanTransport implements MeshTransport {
  static const int discoveryPort = 45654;
  static const Duration announceInterval = Duration(seconds: 3);
  static const Duration peerTimeout = Duration(seconds: 10);

  RawDatagramSocket? _udp;
  ServerSocket? _server;
  Timer? _announceTimer;
  Timer? _reapTimer;

  String? _myAddress;
  String? _myX25519Base64;

  final Map<String, _PeerInfo> _peers = <String, _PeerInfo>{};

  final _messages = StreamController<IncomingMessage>.broadcast();
  final _peersChanged = StreamController<Set<String>>.broadcast();

  @override
  bool get isRunning => _server != null;

  @override
  Set<String> get onlinePeers {
    final now = DateTime.now();
    return _peers.entries
        .where((e) => now.difference(e.value.lastSeen) < peerTimeout)
        .map((e) => e.key)
        .toSet();
  }

  @override
  Stream<IncomingMessage> get onMessage => _messages.stream;

  @override
  Stream<Set<String>> get onPeersChanged => _peersChanged.stream;

  @override
  Future<void> start() async {
    if (isRunning) return;

    final identity = IdentityService.instance;
    final address = await identity.getPublicAddressBase64();
    if (address == null || !identity.isUnlocked) {
      throw StateError('Identity must be unlocked before starting transport');
    }
    _myAddress = address;
    _myX25519Base64 = await EnvelopeCodec.myX25519Base64();

    // Inbound message server on an ephemeral port (announced over UDP).
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_handleConnection);

    _udp = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    _udp!.broadcastEnabled = true;
    _udp!.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = _udp!.receive();
        if (datagram != null) {
          _handleAnnouncement(datagram);
        }
      }
    });

    await _announce();
    _announceTimer = Timer.periodic(announceInterval, (_) => _announce());
    _reapTimer = Timer.periodic(peerTimeout, (_) => _reapStalePeers());
  }

  @override
  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _reapTimer?.cancel();
    _reapTimer = null;
    _udp?.close();
    _udp = null;
    await _server?.close();
    _server = null;
    _peers.clear();
    _peersChanged.add(const <String>{});
  }

  // ---------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------

  Future<void> _announce() async {
    final udp = _udp;
    final server = _server;
    final address = _myAddress;
    final x25519 = _myX25519Base64;
    if (udp == null || server == null || address == null || x25519 == null) {
      return;
    }

    final port = server.port;
    final signature = await IdentityService.instance
        .sign(utf8.encode('announce|$address|$x25519|$port'));

    final payload = utf8.encode(jsonEncode(<String, Object?>{
      't': 'announce',
      'addr': address,
      'x25519': x25519,
      'port': port,
      'sig': base64Encode(signature.bytes),
    }));

    // Global broadcast plus per-interface subnet broadcasts, since some
    // networks/routers drop 255.255.255.255.
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            targets.add(
              InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'),
            );
          }
        }
      }
    } catch (_) {
      // Interface enumeration is best-effort.
    }

    for (final target in targets) {
      try {
        udp.send(payload, target, discoveryPort);
      } catch (_) {
        // Some interfaces reject broadcast; ignore.
      }
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
      if (addr == null || x25519 == null || port == null || sig == null) {
        return;
      }
      if (addr == _myAddress) return;

      final valid = await IdentityService.verify(
        message: utf8.encode('announce|$addr|$x25519|$port'),
        signatureBytes: base64Decode(sig),
        publicKeyBase64: addr,
      );
      if (!valid) return;

      final wasOnline = onlinePeers;
      _peers[addr] = _PeerInfo(
        host: datagram.address,
        port: port,
        x25519Base64: x25519,
        lastSeen: DateTime.now(),
      );
      final nowOnline = onlinePeers;
      if (!setEquals(wasOnline, nowOnline)) {
        _peersChanged.add(nowOnline);
      }
    } catch (_) {
      // Malformed datagram; ignore.
    }
  }

  void _reapStalePeers() {
    final now = DateTime.now();
    final before = onlinePeers;
    _peers.removeWhere(
      (_, info) => now.difference(info.lastSeen) > peerTimeout * 3,
    );
    final after = onlinePeers;
    if (!setEquals(before, after)) {
      _peersChanged.add(after);
    }
  }

  static bool setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  // ---------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------

  @override
  Future<bool> sendMessage({
    required String peerAddress,
    required String messageId,
    required String text,
    required DateTime timestamp,
    String? groupId,
    List<String>? groupMembers,
  }) async {
    final peer = _peers[peerAddress];
    final from = _myAddress;
    if (peer == null || from == null) return false;

    try {
      final envelope = await EnvelopeCodec.encryptEnvelope(
        from: from,
        to: peerAddress,
        toX25519Base64: peer.x25519Base64,
        messageId: messageId,
        text: text,
        timestamp: timestamp,
        groupId: groupId,
        groupMembers: groupMembers,
      );

      final socket = await Socket.connect(
        peer.host,
        peer.port,
        timeout: const Duration(seconds: 5),
      );
      socket.write('${jsonEncode(envelope)}\n');
      await socket.flush();

      final response = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      socket.destroy();

      final ack = jsonDecode(response);
      return ack is Map && ack['t'] == 'ack' && ack['id'] == messageId;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------

  Future<void> _handleConnection(Socket socket) async {
    try {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));

      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        socket.destroy();
        return;
      }

      final incoming = await EnvelopeCodec.decryptEnvelope(
        decoded,
        myAddress: _myAddress ?? '',
      );
      if (incoming == null) {
        socket.destroy();
        return;
      }

      _messages.add(incoming);

      socket.write(
        '${jsonEncode(<String, Object?>{'t': 'ack', 'id': incoming.id})}\n',
      );
      await socket.flush();
      socket.destroy();
    } catch (_) {
      socket.destroy();
    }
  }
}

class _PeerInfo {
  final InternetAddress host;
  final int port;
  final String x25519Base64;
  final DateTime lastSeen;

  const _PeerInfo({
    required this.host,
    required this.port,
    required this.x25519Base64,
    required this.lastSeen,
  });
}

MeshTransport createTransport() => _IoLanTransport();
