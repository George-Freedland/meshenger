import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/message.dart';
import '../transport/lan_transport.dart';
import 'chat_storage.dart';

/// Coordinates the transport and local storage.
///
/// - Outgoing messages are stored immediately; if the peer is offline they
///   stay "pending" and are retried automatically when the peer appears.
/// - Incoming messages are persisted and surfaced to the UI via [onChanged].
class MessengerService {
  MessengerService._();
  static final MessengerService instance = MessengerService._();

  final LanTransport _transport = createLanTransport();
  final _uuid = const Uuid();

  final _changed = StreamController<String>.broadcast();

  /// Emits a peer address whenever that conversation changes.
  Stream<String> get onChanged => _changed.stream;

  Stream<Set<String>> get onPeersChanged => _transport.onPeersChanged;

  Set<String> get onlinePeers => _transport.onlinePeers;

  bool get isTransportRunning => _transport.isRunning;

  StreamSubscription<dynamic>? _messageSub;
  StreamSubscription<dynamic>? _peersSub;

  /// Starts the transport. Call after the identity is unlocked.
  Future<void> start() async {
    if (_transport.isRunning) return;
    try {
      await _transport.start();
    } catch (_) {
      // Transport unavailable (e.g. web); app still works, messages queue.
      return;
    }

    _messageSub ??= _transport.onMessage.listen((incoming) async {
      await ChatStorage.instance.ensureChatExists(incoming.fromAddress);
      await ChatStorage.instance.appendMessage(
        incoming.fromAddress,
        ChatMessage(
          id: incoming.id,
          text: incoming.text,
          isMe: false,
          timestamp: incoming.timestamp,
          status: MessageStatus.sent,
        ),
      );
      _changed.add(incoming.fromAddress);
    });

    _peersSub ??= _transport.onPeersChanged.listen((peers) {
      for (final peer in peers) {
        _flushPending(peer);
      }
    });
  }

  Future<void> stop() async {
    await _messageSub?.cancel();
    _messageSub = null;
    await _peersSub?.cancel();
    _peersSub = null;
    await _transport.stop();
  }

  /// Stores and attempts to deliver [text] to [peerAddress].
  Future<ChatMessage> sendText(String peerAddress, String text) async {
    final message = ChatMessage(
      id: _uuid.v4(),
      text: text,
      isMe: true,
      timestamp: DateTime.now(),
      status: MessageStatus.pending,
    );

    await ChatStorage.instance.ensureChatExists(peerAddress);
    await ChatStorage.instance.appendMessage(peerAddress, message);
    _changed.add(peerAddress);

    final delivered = await _transport.sendMessage(
      peerAddress: peerAddress,
      messageId: message.id,
      text: message.text,
      timestamp: message.timestamp,
    );

    if (delivered) {
      await ChatStorage.instance
          .updateMessageStatus(peerAddress, message.id, MessageStatus.sent);
      _changed.add(peerAddress);
      return message.copyWith(status: MessageStatus.sent);
    }
    return message;
  }

  Future<void> _flushPending(String peerAddress) async {
    final messages = await ChatStorage.instance.listMessages(peerAddress);
    for (final message in messages) {
      if (!message.isMe || message.status != MessageStatus.pending) continue;
      final delivered = await _transport.sendMessage(
        peerAddress: peerAddress,
        messageId: message.id,
        text: message.text,
        timestamp: message.timestamp,
      );
      if (delivered) {
        await ChatStorage.instance
            .updateMessageStatus(peerAddress, message.id, MessageStatus.sent);
        _changed.add(peerAddress);
      }
    }
  }
}
