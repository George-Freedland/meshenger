import 'dart:async';

import 'mesh_transport.dart';

/// No-op Bluetooth transport for platforms without BLE support (web).
class _StubBleTransport implements MeshTransport {
  final _packets = StreamController<Map<String, Object?>>.broadcast();
  final _peers = StreamController<Set<String>>.broadcast();

  @override
  bool invisible = false;

  @override
  bool get isRunning => false;

  @override
  Set<String> get hiddenPeers => const <String>{};

  @override
  String? get startupWarning => null;

  @override
  Set<String> get onlinePeers => const <String>{};

  @override
  Map<String, int> get peerRssi => const <String, int>{};

  @override
  String? x25519For(String peerAddress) => null;

  @override
  Stream<Map<String, Object?>> get onPacket => _packets.stream;

  @override
  Stream<Set<String>> get onPeersChanged => _peers.stream;

  @override
  Future<void> start() async {
    throw StateError('Bluetooth is not supported on this platform');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> rescan() async {}

  @override
  Future<bool> sendPacket(
    String peerAddress,
    Map<String, Object?> packet,
  ) async {
    return false;
  }
}

MeshTransport createTransport() => _StubBleTransport();
