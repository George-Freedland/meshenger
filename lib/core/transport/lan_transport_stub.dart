import 'dart:async';

import '../models/incoming_message.dart';
import 'mesh_transport.dart';

/// No-op transport for platforms without dart:io sockets (web).
///
/// Messages queue as "pending" and the app stays fully usable; delivery
/// requires a platform with socket support (desktop/mobile).
class _StubLanTransport implements MeshTransport {
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
  Future<void> start() async {}

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

MeshTransport createTransport() => _StubLanTransport();
