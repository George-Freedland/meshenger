import 'dart:async';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../models/group_info.dart';
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
class MessengerService {
  MessengerService._();
  static final MessengerService instance = MessengerService._();

  final _uuid = const Uuid();

  MeshTransport? _transport;
  TransportMode _mode = TransportMode.bluetooth;

  String? transportError;

  final _changed = StreamController<String>.broadcast();
  final _peers = StreamController<Set<String>>.broadcast();
  final _transportChanged = StreamController<TransportMode>.broadcast();

  StreamSubscription<dynamic>? _messageSub;
  StreamSubscription<dynamic>? _peersSub;

  Stream<String> get onChanged => _changed.stream;
  Stream<Set<String>> get onPeersChanged => _peers.stream;
  Stream<TransportMode> get onTransportChanged => _transportChanged.stream;

  Set<String> get onlinePeers => _transport?.onlinePeers ?? const <String>{};
  bool get isTransportRunning => _transport?.isRunning ?? false;
  TransportMode get mode => _mode;

  Future<void> start() async {
    _mode = await TransportSettings.instance.getMode();
    await _startTransport();
  }

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
      if (e is StateError) {
        transportError = e.message;
      } else if (e is PlatformException) {
        transportError = e.message ?? e.toString();
      } else {
        transportError = e.toString();
      }
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
    final allowAnyone =
        await SettingsService.instance.getAllowMessagesFromAnyone();
    if (!allowAnyone) {
      final contact =
          await ContactsService.instance.getContact(incoming.fromAddress);
      if (contact == null) return;
    }

    if (incoming.isGroupEvent) {
      await _handleGroupEvent(incoming);
      return;
    }

    final String chatKey;
    if (incoming.groupId != null) {
      chatKey = ChatStorage.groupChatKey(incoming.groupId!);
      final me = await IdentityService.instance.getPublicAddressBase64();
      final existing =
          await ChatStorage.instance.getGroupInfo(incoming.groupId!);
      if (me != null &&
          incoming.groupMembers != null &&
          !incoming.groupMembers!.contains(me)) {
        return;
      }
      await ChatStorage.instance.saveGroupInfo(GroupInfo(
        id: incoming.groupId!,
        adminAddress:
            incoming.groupAdmin ?? existing?.adminAddress ?? incoming.fromAddress,
        name: incoming.groupName ?? existing?.name,
        members: incoming.groupMembers ?? existing?.members ?? <String>[],
      ));
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
    await ChatStorage.instance.markUnread(chatKey);
    _changed.add(chatKey);
  }

  Future<void> _handleGroupEvent(IncomingMessage incoming) async {
    final groupId = incoming.groupId;
    final members = incoming.groupMembers;
    if (groupId == null || members == null) return;

    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) return;

    final event = GroupEvent(
      groupId: groupId,
      actorAddress: incoming.fromAddress,
      adminAddress: incoming.groupAdmin ?? incoming.fromAddress,
      members: members,
      name: incoming.groupName,
      action: incoming.groupEvent!,
    );

    final stillMember =
        await ChatStorage.instance.applyGroupEvent(event, me);
    if (!stillMember) {
      _changed.add(ChatStorage.groupChatKey(groupId));
      return;
    }

    final chatKey = ChatStorage.groupChatKey(groupId);
    final notice = _systemNoticeForEvent(event, me);
    if (notice != null &&
        !await _hasMessage(chatKey, incoming.id)) {
      await ChatStorage.instance.appendMessage(
        chatKey,
        ChatMessage(
          id: incoming.id,
          text: notice,
          isMe: incoming.fromAddress == me,
          timestamp: incoming.timestamp,
          status: MessageStatus.sent,
          isSystem: true,
        ),
      );
      await ChatStorage.instance.markUnread(chatKey);
    }
    _changed.add(chatKey);
  }

  Future<bool> _hasMessage(String chatKey, String id) async {
    final messages = await ChatStorage.instance.listMessages(chatKey);
    return messages.any((m) => m.id == id);
  }

  String? _systemNoticeForEvent(GroupEvent event, String me) {
    switch (event.action) {
      case 'rename':
        final name = event.name?.trim();
        if (name == null || name.isEmpty) return null;
        return event.actorAddress == me
            ? 'You renamed the group to "$name"'
            : 'Group renamed to "$name"';
      case 'members':
        return event.actorAddress == me
            ? 'You updated the group members'
            : 'Group members were updated';
      case 'leave':
        return event.actorAddress == me
            ? 'You left the group'
            : 'A member left the group';
      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------
  // Outgoing: 1:1
  // ---------------------------------------------------------------------

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

  Future<String> createGroup(
    List<String> memberAddresses, {
    String? name,
  }) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) throw StateError('Identity is locked');

    final groupId = _uuid.v4();
    final members = <String>{...memberAddresses, me}.toList();
    final trimmedName = name?.trim();
    await ChatStorage.instance.saveGroupInfo(GroupInfo(
      id: groupId,
      adminAddress: me,
      name: (trimmedName != null && trimmedName.isNotEmpty) ? trimmedName : null,
      members: members,
    ));
    final chatKey = ChatStorage.groupChatKey(groupId);
    await ChatStorage.instance.ensureChatExists(chatKey);
    _changed.add(chatKey);
    return chatKey;
  }

  Future<void> sendGroupText(String chatKey, String text) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (info == null) return;

    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null || !info.contains(me)) return;

    final recipients = info.members.where((a) => a != me).toList();
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
            groupMembers: info.members,
            groupAdmin: info.adminAddress,
            groupName: info.name,
          ) ??
          false;
      if (delivered) {
        await ChatStorage.instance
            .markGroupMessageDelivered(chatKey, message.id, recipient);
        _changed.add(chatKey);
      }
    }
  }

  Future<void> renameGroup(String chatKey, String name) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final me = await IdentityService.instance.getPublicAddressBase64();
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (me == null || info == null || !info.isAdmin(me)) {
      throw StateError('Only the group admin can rename the group');
    }

    final trimmed = name.trim();
    final updated = info.copyWith(
      name: trimmed.isEmpty ? null : trimmed,
      clearName: trimmed.isEmpty,
    );
    await ChatStorage.instance.saveGroupInfo(updated);
    await _broadcastGroupEvent(
      info: updated,
      action: 'rename',
      systemText: trimmed.isEmpty
          ? 'You cleared the group name'
          : 'You renamed the group to "$trimmed"',
    );
    _changed.add(chatKey);
  }

  Future<void> addGroupMembers(String chatKey, List<String> addresses) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final me = await IdentityService.instance.getPublicAddressBase64();
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (me == null || info == null || !info.isAdmin(me)) {
      throw StateError('Only the group admin can add members');
    }

    final merged = <String>{...info.members, ...addresses}.toList();
    final updated = info.copyWith(members: merged);
    await ChatStorage.instance.saveGroupInfo(updated);
    await _broadcastGroupEvent(
      info: updated,
      action: 'members',
      systemText: 'You added ${addresses.length} member(s)',
    );
    _changed.add(chatKey);
  }

  Future<void> removeGroupMember(String chatKey, String memberAddress) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final me = await IdentityService.instance.getPublicAddressBase64();
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (me == null || info == null || !info.isAdmin(me)) {
      throw StateError('Only the group admin can remove members');
    }
    if (memberAddress == me) {
      throw StateError('Use leave group to remove yourself');
    }

    final updatedMembers =
        info.members.where((a) => a != memberAddress).toList();
    final updated = info.copyWith(members: updatedMembers);
    await ChatStorage.instance.saveGroupInfo(updated);
    await _broadcastGroupEvent(
      info: updated,
      action: 'members',
      systemText: 'You removed a member from the group',
      alsoNotify: [memberAddress],
    );
    _changed.add(chatKey);
  }

  Future<void> leaveGroup(String chatKey) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final me = await IdentityService.instance.getPublicAddressBase64();
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (me == null || info == null) return;

    final remaining = info.members.where((a) => a != me).toList();
    if (remaining.isNotEmpty) {
      final updated = info.copyWith(members: remaining);
      await _broadcastGroupEvent(
        info: updated,
        action: 'leave',
        systemText: 'You left the group',
      );
    }

    await ChatStorage.instance.leaveGroup(groupId, me);
    _changed.add(chatKey);
  }

  Future<void> _broadcastGroupEvent({
    required GroupInfo info,
    required String action,
    required String systemText,
    List<String> alsoNotify = const <String>[],
  }) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) return;

    final chatKey = ChatStorage.groupChatKey(info.id);
    final eventId = _uuid.v4();
    final timestamp = DateTime.now();

    await ChatStorage.instance.appendMessage(
      chatKey,
      ChatMessage(
        id: eventId,
        text: systemText,
        isMe: true,
        timestamp: timestamp,
        status: MessageStatus.pending,
        isSystem: true,
      ),
    );

    final recipients = <String>{
      ...info.members.where((a) => a != me),
      ...alsoNotify.where((a) => a != me),
    };
    for (final recipient in recipients) {
      await _transport?.sendMessage(
        peerAddress: recipient,
        messageId: eventId,
        text: '',
        timestamp: timestamp,
        groupId: info.id,
        groupMembers: info.members,
        groupAdmin: info.adminAddress,
        groupName: info.name,
        groupEvent: action,
      );
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
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (info == null) return;

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
          groupMembers: info.members,
          groupAdmin: info.adminAddress,
          groupName: info.name,
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
