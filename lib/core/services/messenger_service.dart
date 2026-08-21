import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/group_info.dart';
import '../models/incoming_message.dart';
import '../models/message.dart';
import '../transport/ble_transport.dart';
import '../transport/lan_transport.dart';
import '../transport/mesh_transport.dart';
import 'chat_storage.dart';
import 'contacts_service.dart';
import 'identity_scope.dart';
import 'identity_service.dart';
import 'settings_service.dart';
import 'stories_service.dart';
import 'transport_settings.dart';

/// Coordinates the active transport (Bluetooth or LAN) and local storage.
class MessengerService {
  MessengerService._();
  static final MessengerService instance = MessengerService._();

  static const _controlOutboxKey = 'control_outbox_v1';

  final _uuid = const Uuid();

  MeshTransport? _transport;
  TransportMode _mode = TransportMode.bluetooth;
  Timer? _sweepTimer;

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

  /// Signal strength per online peer (dBm), when the transport measures it.
  Map<String, int> get peerSignal => _transport?.peerRssi ?? const {};

  bool get isTransportRunning => _transport?.isRunning ?? false;
  TransportMode get mode => _mode;

  Future<void> start() async {
    _mode = await TransportSettings.instance.getMode();
    await _startTransport();
    _sweepTimer ??=
        Timer.periodic(const Duration(seconds: 15), (_) => _sweepExpired());
    await _sweepExpired();
  }

  Future<void> setMode(TransportMode mode) async {
    if (mode == _mode && isTransportRunning) return;
    _mode = mode;
    await TransportSettings.instance.setMode(mode);
    await _stopTransport();
    await _startTransport();
  }

  Future<void> stop() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    await _stopTransport();
  }

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
      transportError = e is StateError ? e.message : e.toString();
      _transportChanged.add(_mode);
      _peers.add(const <String>{});
      return;
    }

    _messageSub = transport.onMessage.listen(_handleIncoming);
    _peersSub = transport.onPeersChanged.listen((peers) {
      _peers.add(peers);
      _flushPendingFor(peers);
      _flushControlOutbox(peers);
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

  Future<void> _sweepExpired() async {
    if (!IdentityScope.hasActive) return;
    final changed = await ChatStorage.instance.sweepExpired();
    for (final chatKey in changed) {
      _changed.add(chatKey);
    }
    await StoriesService.instance.sweepExpired();
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

    switch (incoming.action) {
      case 'edit':
        await _handleRemoteEdit(incoming);
        return;
      case 'delete':
        await _handleRemoteDelete(incoming);
        return;
      case 'story':
        await _handleRemoteStory(incoming);
        return;
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
        adminAddress: incoming.groupAdmin ??
            existing?.adminAddress ??
            incoming.fromAddress,
        name: incoming.groupName ?? existing?.name,
        members: incoming.groupMembers ?? existing?.members ?? <String>[],
      ));
    } else {
      chatKey = incoming.fromAddress;
    }

    final expiresAtMs = await _incomingExpiry(incoming);

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
        expiresAtMs: expiresAtMs,
      ),
    );
    await ChatStorage.instance.markUnread(chatKey);
    _changed.add(chatKey);
  }

  /// The earliest applicable auto-delete deadline: the sender's TTL and my
  /// own auto-delete setting both apply.
  Future<int?> _incomingExpiry(IncomingMessage incoming) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final candidates = <int>[];
    final senderTtl = incoming.ttlSeconds;
    if (senderTtl != null && senderTtl > 0) {
      candidates.add(now + senderTtl * 1000);
    }
    final mine = await SettingsService.instance.getAutoDeleteSeconds();
    if (mine > 0) {
      candidates.add(now + mine * 1000);
    }
    if (candidates.isEmpty) return null;
    candidates.sort();
    return candidates.first;
  }

  String _chatKeyForIncoming(IncomingMessage incoming) =>
      incoming.groupId != null
          ? ChatStorage.groupChatKey(incoming.groupId!)
          : incoming.fromAddress;

  Future<void> _handleRemoteEdit(IncomingMessage incoming) async {
    final target = incoming.targetId;
    if (target == null) return;
    final chatKey = _chatKeyForIncoming(incoming);
    final applied = await ChatStorage.instance.editMessage(
      chatKey,
      target,
      incoming.text,
      requireSender: incoming.fromAddress,
    );
    if (applied) _changed.add(chatKey);
  }

  Future<void> _handleRemoteDelete(IncomingMessage incoming) async {
    final target = incoming.targetId;
    if (target == null) return;
    final chatKey = _chatKeyForIncoming(incoming);
    final applied = await ChatStorage.instance.deleteMessage(
      chatKey,
      target,
      requireSender: incoming.fromAddress,
    );
    if (applied) _changed.add(chatKey);
  }

  Future<void> _handleRemoteStory(IncomingMessage incoming) async {
    final ttl = incoming.ttlSeconds ?? 86400;
    await StoriesService.instance.upsert(Story(
      // The story's stable id travels in targetId; the envelope id varies
      // per delivery attempt.
      id: incoming.targetId ?? incoming.id,
      author: incoming.fromAddress,
      text: incoming.text,
      tsMs: incoming.timestamp.millisecondsSinceEpoch,
      expiresMs: incoming.timestamp.millisecondsSinceEpoch + ttl * 1000,
    ));
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
    if (notice != null && !await _hasMessage(chatKey, incoming.id)) {
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
    final ttl = await SettingsService.instance.getAutoDeleteSeconds();
    final now = DateTime.now();
    final message = ChatMessage(
      id: _uuid.v4(),
      text: text,
      isMe: true,
      timestamp: now,
      status: MessageStatus.pending,
      expiresAtMs:
          ttl > 0 ? now.millisecondsSinceEpoch + ttl * 1000 : null,
    );

    await ChatStorage.instance.ensureChatExists(peerAddress);
    await ChatStorage.instance.appendMessage(peerAddress, message);
    _changed.add(peerAddress);

    final delivered = await _transport?.sendMessage(
          peerAddress: peerAddress,
          messageId: message.id,
          text: message.text,
          timestamp: message.timestamp,
          ttlSeconds: ttl > 0 ? ttl : null,
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
      name: (trimmedName != null && trimmedName.isNotEmpty)
          ? trimmedName
          : null,
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

    final ttl = await SettingsService.instance.getAutoDeleteSeconds();
    final now = DateTime.now();
    final recipients = info.members.where((a) => a != me).toList();
    final message = ChatMessage(
      id: _uuid.v4(),
      text: text,
      isMe: true,
      timestamp: now,
      status: MessageStatus.pending,
      pendingTo: recipients,
      expiresAtMs:
          ttl > 0 ? now.millisecondsSinceEpoch + ttl * 1000 : null,
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
            ttlSeconds: ttl > 0 ? ttl : null,
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
  // Edit / delete own messages (synced to peers)
  // ---------------------------------------------------------------------

  Future<void> sendEditMessage(
    String chatKey,
    String messageId,
    String newText,
  ) async {
    final applied =
        await ChatStorage.instance.editMessage(chatKey, messageId, newText);
    if (!applied) return;
    _changed.add(chatKey);
    await _enqueueControl(
      act: 'edit',
      chatKey: chatKey,
      target: messageId,
      text: newText,
    );
  }

  Future<void> sendDeleteMessage(String chatKey, String messageId) async {
    final applied =
        await ChatStorage.instance.deleteMessage(chatKey, messageId);
    if (!applied) return;
    _changed.add(chatKey);
    await _enqueueControl(
      act: 'delete',
      chatKey: chatKey,
      target: messageId,
    );
  }

  // ---------------------------------------------------------------------
  // Stories
  // ---------------------------------------------------------------------

  /// Posts a status update, visible to all current contacts.
  Future<void> postStory(String text, {int ttlSeconds = 86400}) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) throw StateError('Identity is locked');

    final now = DateTime.now().millisecondsSinceEpoch;
    final story = Story(
      id: _uuid.v4(),
      author: me,
      text: text,
      tsMs: now,
      expiresMs: now + ttlSeconds * 1000,
    );
    await StoriesService.instance.upsert(story);

    final contacts = await ContactsService.instance.listContacts();
    await _enqueueControl(
      act: 'story',
      chatKey: '',
      target: story.id,
      text: text,
      ttl: ttlSeconds,
      recipients: contacts.map((c) => c.address).toList(),
    );
  }

  Future<void> deleteStory(String id) async {
    await StoriesService.instance.remove(id);
    await _pruneControlOps(target: id);
  }

  // ---------------------------------------------------------------------
  // Control outbox (edits/deletes/stories with store-and-forward retry)
  // ---------------------------------------------------------------------

  Future<void> _enqueueControl({
    required String act,
    required String chatKey,
    required String target,
    String? text,
    int? ttl,
    List<String>? recipients,
  }) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    List<String> to;
    String? gid;
    if (recipients != null) {
      to = recipients;
    } else if (ChatStorage.isGroupChat(chatKey)) {
      gid = ChatStorage.groupIdOf(chatKey);
      final info = await ChatStorage.instance.getGroupInfo(gid);
      to = (info?.members ?? const <String>[])
          .where((a) => a != me)
          .toList();
    } else {
      to = [chatKey];
    }
    if (to.isEmpty) return;

    final ops = await _readControlOps();
    ops.add(<String, Object?>{
      'act': act,
      'chatKey': chatKey,
      'gid': gid,
      'target': target,
      'text': text,
      'ttl': ttl,
      'to': to,
    });
    await _writeControlOps(ops);
    await _flushControlOutbox(onlinePeers);
  }

  Future<void> _pruneControlOps({required String target}) async {
    final ops = await _readControlOps();
    ops.removeWhere((op) => op['target'] == target);
    await _writeControlOps(ops);
  }

  Future<void> _flushControlOutbox(Set<String> onlineNow) async {
    final transport = _transport;
    if (transport == null || onlineNow.isEmpty) return;
    final ops = await _readControlOps();
    if (ops.isEmpty) return;

    var changed = false;
    for (final op in ops) {
      final to = (op['to'] as List?)?.whereType<String>().toList() ?? [];
      final remaining = <String>[];
      for (final recipient in to) {
        if (!onlineNow.contains(recipient)) {
          remaining.add(recipient);
          continue;
        }
        final gid = op['gid'] as String?;
        GroupInfo? info;
        if (gid != null) {
          info = await ChatStorage.instance.getGroupInfo(gid);
        }
        final delivered = await transport.sendMessage(
          peerAddress: recipient,
          messageId: '${op['act']}:${op['target']}:$recipient',
          text: (op['text'] as String?) ?? '',
          timestamp: DateTime.now(),
          groupId: gid,
          groupMembers: info?.members,
          groupAdmin: info?.adminAddress,
          groupName: info?.name,
          action: op['act'] as String,
          targetId: op['target'] as String,
          ttlSeconds: (op['ttl'] as num?)?.toInt(),
        );
        if (!delivered) remaining.add(recipient);
      }
      if (remaining.length != to.length) {
        changed = true;
        op['to'] = remaining;
      }
    }

    if (changed) {
      ops.removeWhere(
          (op) => ((op['to'] as List?) ?? const []).isEmpty);
      await _writeControlOps(ops);
    }
  }

  Future<List<Map<String, Object?>>> _readControlOps() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_controlOutboxKey));
    if (raw == null || raw.isEmpty) return <Map<String, Object?>>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <Map<String, Object?>>[];
    return decoded
        .whereType<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList();
  }

  Future<void> _writeControlOps(List<Map<String, Object?>> ops) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        IdentityScope.key(_controlOutboxKey), jsonEncode(ops));
  }

  // ---------------------------------------------------------------------
  // Group management
  // ---------------------------------------------------------------------

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

  /// Immediately retries everything pending in [chatKey].
  Future<void> retryChat(String chatKey) async {
    if (ChatStorage.isGroupChat(chatKey)) {
      await _flushGroupPending(chatKey, onlinePeers);
    } else {
      await _flushDirectPending(chatKey);
    }
    await _flushControlOutbox(onlinePeers);
  }

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
