import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'identity.dart';
import 'transport.dart';

/// LAN link: signed UDP discovery on port 45654 + newline-delimited JSON
/// packets over TCP. Same wire protocol as the app's LAN transport, so the
/// relay bridges anything on the same Wi-Fi network, hotspot, or Ethernet.
class LanTransport implements RelayTransport {
  static const int defaultDiscoveryPort = 45654;
  static const Duration announceInterval = Duration(seconds: 3);
  static const Duration peerTimeout = Duration(seconds: 10);

  final RelayIdentity identity;
  final void Function(String) log;

  /// The app listens on 45654; tests use isolated ports.
  final int discoveryPort;

  LanTransport({
    required this.identity,
    required this.log,
    this.discoveryPort = defaultDiscoveryPort,
  });

  ServerSocket? _server;
  RawDatagramSocket? _udp;
  Timer? _announceTimer;
  Timer? _reapTimer;

  final Map<String, _LanPeer> _peers = <String, _LanPeer>{};
  final _packets = StreamController<Map<String, Object?>>.broadcast();
  final _peersChanged = StreamController<Set<String>>.broadcast();

  @override
  String get name => 'lan';

  /// The TCP port packets are accepted on (announced over UDP).
  int? get tcpPort => _server?.port;

  @override
  Set<String> get onlinePeers {
    final now = DateTime.now();
    return _peers.entries
        .where((e) => now.difference(e.value.lastSeen) < peerTimeout * 3)
        .map((e) => e.key)
        .toSet();
  }

  @override
  Stream<Map<String, Object?>> get onPacket => _packets.stream;

  @override
  Stream<Set<String>> get onPeersChanged => _peersChanged.stream;

  @override
  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server!.listen(_handleConnection);

    _udp = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    _udp!.broadcastEnabled = true;
    _udp!.listen(
      (event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udp!.receive();
          if (datagram != null) _handleAnnouncement(datagram);
        }
      },
      onError: (Object _) {
        // Broadcast sends to unreachable interfaces surface here; harmless.
      },
    );

    await _announce();
    _announceTimer = Timer.periodic(announceInterval, (_) => _announce());
    _reapTimer = Timer.periodic(peerTimeout, (_) => _reapPeers());
    log('LAN: listening on TCP port ${_server!.port}, '
        'announcing on UDP $discoveryPort');
  }

  @override
  Future<void> stop() async {
    _announceTimer?.cancel();
    _reapTimer?.cancel();
    _udp?.close();
    await _server?.close();
    _peers.clear();
  }

  // ---------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------

  Future<void> _announce() async {
    final server = _server;
    if (server == null) return;

    final sig = await identity
        .sign('announce|${identity.address}|${identity.x25519}|${server.port}');
    final payload = utf8.encode(jsonEncode(<String, Object?>{
      't': 'announce',
      'addr': identity.address,
      'x25519': identity.x25519,
      'port': server.port,
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

    // Send from a throwaway socket: a failed broadcast (networks that block
    // 255.255.255.255 surface errno 49) CLOSES the sending socket, which
    // would leave the receive socket deaf forever if they were shared.
    RawDatagramSocket? tx;
    try {
      tx = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      tx.broadcastEnabled = true;
      // Swallow the async send errors that would otherwise be unhandled.
      tx.listen((_) {}, onError: (Object _) {});
      for (final target in targets) {
        try {
          tx.send(payload, target, discoveryPort);
        } catch (_) {}
      }
      // Give the datagrams a moment to flush before closing.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } catch (_) {
    } finally {
      tx?.close();
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
      if (addr == identity.address) return;

      final valid = await RelayIdentity.verify(
        'announce|$addr|$x25519|$port',
        sig,
        addr,
      );
      if (!valid) return;

      final isNew = !onlinePeers.contains(addr);
      _peers[addr] = _LanPeer(
        host: datagram.address,
        port: port,
        lastSeen: DateTime.now(),
      );
      if (isNew) {
        log('LAN: peer online ${addr.substring(0, 12)}… '
            '(${datagram.address.address})');
        _peersChanged.add(onlinePeers);
      }
    } catch (_) {}
  }

  void _reapPeers() {
    final now = DateTime.now();
    final stale = _peers.entries
        .where((e) => now.difference(e.value.lastSeen) > peerTimeout * 3)
        .map((e) => e.key)
        .toList();
    if (stale.isEmpty) return;
    for (final addr in stale) {
      _peers.remove(addr);
      log('LAN: peer offline ${addr.substring(0, 12)}…');
    }
    _peersChanged.add(onlinePeers);
  }

  // ---------------------------------------------------------------------
  // Packets
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

      _packets.add(packet);
    } catch (_) {
      socket.destroy();
    }
  }

  @override
  Future<bool> sendPacket(
    String peerAddress,
    Map<String, Object?> packet,
  ) async {
    final peer = _peers[peerAddress];
    if (peer == null) return false;
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
}

class _LanPeer {
  final InternetAddress host;
  final int port;
  final DateTime lastSeen;

  const _LanPeer({
    required this.host,
    required this.port,
    required this.lastSeen,
  });
}
