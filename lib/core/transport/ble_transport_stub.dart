import 'dart:async';

import '../models/incoming_message.dart';
import 'mesh_transport.dart';

/// No-op Bluetooth transport for platforms without BLE support (web).
class _StubBleTransport implements MeshTransport {
  final _messages = StreamController<IncomingMessage>.broadcast();
  final _peers = StreamController<Set<String>>.broadcast();

  @override
  bool get isRunning => false;

  @override
  Set<String> get onlinePeers => const <String>{};

  @override
  Stream<IncomingMessage> get onMessage => _messages.stream;

  @override
  Stream<Set<String>> get onPeersChanged => _peers.stream;

  @override
  Future<void> start() async {
    throw StateError('Bluetooth is not supported on this platform');
  }

  @override
  Future<void> stop() async {}

  @override
  Future<bool> sendMessage({
    required String peerAddress,
    required String messageId,
    required String text,
    required DateTime timestamp,
    String? groupId,
    List<String>? groupMembers,
    String? groupAdmin,
    String? groupName,
    String? groupEvent,
  }) async {
    return false;
  }
}

MeshTransport createTransport() => _StubBleTransport();
