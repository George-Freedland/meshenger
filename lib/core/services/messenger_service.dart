import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/message.dart';
import '../transport/ble_transport.dart';
import '../transport/lan_transport.dart';
import '../transport/mesh_transport.dart';
import 'chat_storage.dart';
import 'transport_settings.dart';

/// Coordinates the active transport (Bluetooth or LAN) and local storage.
///
/// - Outgoing messages are stored immediately; if the peer is offline they
///   stay "pending" and are retried automatically when the peer appears.
/// - Incoming messages are persisted and surfaced to the UI via [onChanged].
class MessengerService {
  MessengerService._();
  static final MessengerService instance = MessengerService._();

  final _uuid = const Uuid();

  MeshTransport? _transport;
  TransportMode _mode = TransportMode.bluetooth;

  /// Human-readable reason the transport failed to start, if it did.
  String? transportError;

  final _changed = StreamController<String>.broadcast();
  final _peers = StreamController<Set<String>>.broadcast();
  final _transportChanged = StreamController<TransportMode>.broadcast();

  StreamSubscription<dynamic>? _messageSub;
  StreamSubscription<dynamic>? _peersSub;

  /// Emits a peer address whenever that conversation changes.
  Stream<String> get onChanged => _changed.stream;

  Stream<Set<String>> get onPeersChanged => _peers.stream;

  /// Emits when the transport mode changes or the transport (re)starts.
  Stream<TransportMode> get onTransportChanged => _transportChanged.stream;

  Set<String> get onlinePeers => _transport?.onlinePeers ?? const <String>{};

  bool get isTransportRunning => _transport?.isRunning ?? false;

  TransportMode get mode => _mode;

  /// Starts the transport in the saved mode (Bluetooth by default).
  /// Call after the identity is unlocked.
  Future<void> start() async {
    _mode = await TransportSettings.instance.getMode();
    await _startTransport();
  }

  /// Switches transport (persisted), stopping the old one first.
  Future<void> setMode(TransportMode mode) async {
    if (mode == _mode && isTransportRunning) return;
    _mode = mode;
    await TransportSettings.instance.setMode(mode);
    await _stopTransport();
    await _startTransport();
  }

  Future<void> stop() => _stopTransport();

  Future<void> _startTransport() async {
    if (isTransportRunning) return;
    transportError = null;

    final transport = switch (_mode) {
      TransportMode.bluetooth => createBleTransport(),
      TransportMode.lan => createLanTransport(),
    };
    _transport = transport;

    try {
      await transport.start();
    } catch (e) {
      // Transport unavailable (Bluetooth off, web, ...); the app still
      // works and messages queue as pending.
      transportError = e is StateError ? e.message : e.toString();
      _transportChanged.add(_mode);
      _peers.add(const <String>{});
      return;
    }

    _messageSub = transport.onMessage.listen((incoming) async {
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

    _peersSub = transport.onPeersChanged.listen((peers) {
      _peers.add(peers);
      for (final peer in peers) {
        _flushPending(peer);
      }
    });

    _transportChanged.add(_mode);
    _peers.add(transport.onlinePeers);
  }

  Future<void> _stopTransport() async {
    await _messageSub?.cancel();
    _messageSub = null;
    await _peersSub?.cancel();
    _peersSub = null;
    await _transport?.stop();
    _transport = null;
    _peers.add(const <String>{});
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

    final delivered = await _transport?.sendMessage(
          peerAddress: peerAddress,
          messageId: message.id,
          text: message.text,
          timestamp: message.timestamp,
        ) ??
        false;

    if (delivered) {
      await ChatStorage.instance
          .updateMessageStatus(peerAddress, message.id, MessageStatus.sent);
      _changed.add(peerAddress);
      return message.copyWith(status: MessageStatus.sent);
    }
    return message;
  }

  Future<void> _flushPending(String peerAddress) async {
    final transport = _transport;
    if (transport == null) return;
    final messages = await ChatStorage.instance.listMessages(peerAddress);
    for (final message in messages) {
      if (!message.isMe || message.status != MessageStatus.pending) continue;
      final delivered = await transport.sendMessage(
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
