import 'dart:async';

import 'package:uuid/uuid.dart';

import '../models/incoming_message.dart';
import '../models/message.dart';
import '../transport/ble_transport.dart';
import '../transport/lan_transport.dart';
import '../transport/mesh_transport.dart';
import 'chat_storage.dart';
import 'contacts_service.dart';
import 'identity_service.dart';
import 'settings_service.dart';
import 'transport_settings.dart';

/// Coordinates the active transport (Bluetooth or LAN) and local storage.
///
/// - Outgoing messages are stored immediately; if the peer is offline they
///   stay "pending" and are retried automatically when the peer appears.
///   Group messages track pending state per member.
/// - Incoming messages are persisted and surfaced to the UI via [onChanged],
///   subject to the "allow messages from anyone" setting.
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

  /// Emits a chat key whenever that conversation changes.
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

    _messageSub = transport.onMessage.listen(_handleIncoming);

    _peersSub = transport.onPeersChanged.listen((peers) {
      _peers.add(peers);
      _flushPendingFor(peers);
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

  // ---------------------------------------------------------------------
  // Incoming
  // ---------------------------------------------------------------------

  Future<void> _handleIncoming(IncomingMessage incoming) async {
    // Message policy: with "contacts only", messages from unknown
    // addresses are discarded (history is kept; delivery resumes when the
    // sender is re-added as a contact or the setting is relaxed).
    final allowAnyone =
        await SettingsService.instance.getAllowMessagesFromAnyone();
    if (!allowAnyone) {
      final contact =
          await ContactsService.instance.getContact(incoming.fromAddress);
      if (contact == null) return;
    }

    final String chatKey;
    if (incoming.groupId != null) {
      chatKey = ChatStorage.groupChatKey(incoming.groupId!);
      await ChatStorage.instance.upsertGroupMembers(
        incoming.groupId!,
        <String>{
          ...?incoming.groupMembers,
          incoming.fromAddress,
        }.toList(),
      );
    } else {
      chatKey = incoming.fromAddress;
    }

    await ChatStorage.instance.ensureChatExists(chatKey);
    await ChatStorage.instance.appendMessage(
      chatKey,
      ChatMessage(
        id: incoming.id,
        text: incoming.text,
        isMe: false,
        timestamp: incoming.timestamp,
        status: MessageStatus.sent,
        senderAddress: incoming.fromAddress,
      ),
    );
    _changed.add(chatKey);
  }

  // ---------------------------------------------------------------------
  // Outgoing: 1:1
  // ---------------------------------------------------------------------

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

  // ---------------------------------------------------------------------
  // Outgoing: groups
  // ---------------------------------------------------------------------

  /// Creates a group chat with [memberAddresses] (mine is added
  /// automatically) and returns its chat key.
  Future<String> createGroup(List<String> memberAddresses) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    final groupId = _uuid.v4();
    final members = <String>{...memberAddresses, if (me != null) me}.toList();
    await ChatStorage.instance.upsertGroupMembers(groupId, members);
    final chatKey = ChatStorage.groupChatKey(groupId);
    await ChatStorage.instance.ensureChatExists(chatKey);
    _changed.add(chatKey);
    return chatKey;
  }

  /// Stores and attempts to deliver [text] to every member of the group.
  Future<void> sendGroupText(String chatKey, String text) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final me = await IdentityService.instance.getPublicAddressBase64();
    final members = await ChatStorage.instance.getGroupMembers(groupId);
    final recipients = members.where((a) => a != me).toList();

    final message = ChatMessage(
      id: _uuid.v4(),
      text: text,
      isMe: true,
      timestamp: DateTime.now(),
      status: MessageStatus.pending,
      pendingTo: recipients,
    );

    await ChatStorage.instance.ensureChatExists(chatKey);
    await ChatStorage.instance.appendMessage(chatKey, message);
    _changed.add(chatKey);

    for (final recipient in recipients) {
      final delivered = await _transport?.sendMessage(
            peerAddress: recipient,
            messageId: message.id,
            text: message.text,
            timestamp: message.timestamp,
            groupId: groupId,
            groupMembers: members,
          ) ??
          false;
      if (delivered) {
        await ChatStorage.instance
            .markGroupMessageDelivered(chatKey, message.id, recipient);
        _changed.add(chatKey);
      }
    }
  }

  // ---------------------------------------------------------------------
  // Store-and-forward retries
  // ---------------------------------------------------------------------

  Future<void> _flushPendingFor(Set<String> onlineNow) async {
    if (onlineNow.isEmpty) return;
    final chats = await ChatStorage.instance.listChats();
    for (final chatKey in chats) {
      if (ChatStorage.isGroupChat(chatKey)) {
        await _flushGroupPending(chatKey, onlineNow);
      } else if (onlineNow.contains(chatKey)) {
        await _flushDirectPending(chatKey);
      }
    }
  }

  Future<void> _flushDirectPending(String peerAddress) async {
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

  Future<void> _flushGroupPending(String chatKey, Set<String> onlineNow) async {
    final transport = _transport;
    if (transport == null) return;
    final groupId = ChatStorage.groupIdOf(chatKey);
    final members = await ChatStorage.instance.getGroupMembers(groupId);
    final messages = await ChatStorage.instance.listMessages(chatKey);
    for (final message in messages) {
      if (!message.isMe || message.pendingTo.isEmpty) continue;
      for (final recipient in message.pendingTo) {
        if (!onlineNow.contains(recipient)) continue;
        final delivered = await transport.sendMessage(
          peerAddress: recipient,
          messageId: message.id,
          text: message.text,
          timestamp: message.timestamp,
          groupId: groupId,
          groupMembers: members,
        );
        if (delivered) {
          await ChatStorage.instance
              .markGroupMessageDelivered(chatKey, message.id, recipient);
          _changed.add(chatKey);
        }
      }
    }
  }
}
