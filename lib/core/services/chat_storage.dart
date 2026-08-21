import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/group_info.dart';
import '../models/message.dart';
import 'identity_scope.dart';

/// Chat keys are either a peer address (1:1) or `group:{id}` (group chat).
/// All storage is namespaced to the active identity via [IdentityScope].
class ChatStorage {
  ChatStorage._();
  static final ChatStorage instance = ChatStorage._();

  static const _chatsKey = 'chats_v1'; // list of chat keys
  static const groupPrefix = 'group:';

  static bool isGroupChat(String chatKey) => chatKey.startsWith(groupPrefix);

  static String groupChatKey(String groupId) => '$groupPrefix$groupId';

  static String groupIdOf(String chatKey) =>
      chatKey.substring(groupPrefix.length);

  Future<List<String>> listChats() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_chatsKey));
    if (raw == null || raw.isEmpty) return <String>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <String>[];
    return decoded.whereType<String>().toList();
  }

  Future<void> ensureChatExists(String chatKey) async {
    final chats = await listChats();
    if (!chats.contains(chatKey)) {
      chats.add(chatKey);
      await _writeChats(chats);
    }
  }

  /// Removes a 1:1 chat and all its messages.
  ///
  /// For group chats, use [hideChat] or [leaveGroup] instead.
  Future<void> deleteChat(String chatKey) async {
    if (isGroupChat(chatKey)) {
      throw StateError('Use hideChat or leaveGroup for group chats');
    }
    final prefs = await SharedPreferences.getInstance();
    final chats = await listChats();
    chats.removeWhere((a) => a == chatKey);
    await _writeChats(chats);
    await prefs.remove(IdentityScope.key(_messagesKey(chatKey)));
  }

  /// Hides a group chat from the list without leaving the group. Message
  /// history and membership are preserved; a new incoming message restores
  /// the chat to the list.
  Future<void> hideChat(String chatKey) async {
    if (!isGroupChat(chatKey)) {
      await deleteChat(chatKey);
      return;
    }
    final chats = await listChats();
    chats.removeWhere((a) => a == chatKey);
    await _writeChats(chats);
  }

  /// Deletes all messages in a chat but keeps the conversation itself.
  Future<void> clearMessages(String chatKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(IdentityScope.key(_messagesKey(chatKey)));
  }

  // ---------------------------------------------------------------------
  // Unread state
  // ---------------------------------------------------------------------

  static const _unreadKey = 'chats_unread_v1'; // set of chat keys

  Future<Set<String>> listUnread() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_unreadKey));
    if (raw == null || raw.isEmpty) return <String>{};
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <String>{};
    return decoded.whereType<String>().toSet();
  }

  Future<void> markUnread(String chatKey) async {
    final unread = await listUnread();
    if (unread.add(chatKey)) await _writeUnread(unread);
  }

  Future<void> markRead(String chatKey) async {
    final unread = await listUnread();
    if (unread.remove(chatKey)) await _writeUnread(unread);
  }

  Future<void> _writeUnread(Set<String> unread) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_unreadKey),
      jsonEncode(unread.toList()),
    );
  }

  // ---------------------------------------------------------------------
  // Group metadata
  // ---------------------------------------------------------------------

  String _groupMetaKey(String groupId) => 'group_meta_v2:$groupId';

  /// Legacy member-only storage (pre-admin/name support).
  String _legacyGroupInfoKey(String groupId) => 'group_info_v1:$groupId';

  Future<GroupInfo?> getGroupInfo(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_groupMetaKey(groupId)));
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return GroupInfo.fromJson(decoded.cast<String, Object?>());
      }
    }

    // Migrate legacy member-list-only records.
    final legacy =
        prefs.getString(IdentityScope.key(_legacyGroupInfoKey(groupId)));
    if (legacy == null || legacy.isEmpty) return null;
    final decoded = jsonDecode(legacy);
    if (decoded is! List) return null;
    final members = decoded.whereType<String>().toList();
    if (members.isEmpty) return null;
    final info = GroupInfo(
      id: groupId,
      adminAddress: members.first,
      members: members,
    );
    await saveGroupInfo(info);
    await prefs.remove(IdentityScope.key(_legacyGroupInfoKey(groupId)));
    return info;
  }

  Future<void> saveGroupInfo(GroupInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_groupMetaKey(info.id)),
      jsonEncode(info.toJson()),
    );
  }

  /// Merges [members] into an existing group, or creates a minimal record
  /// when learning membership from an incoming message.
  Future<void> upsertGroupMembers(String groupId, List<String> members) async {
    final existing = await getGroupInfo(groupId);
    if (existing == null) {
      await saveGroupInfo(GroupInfo(
        id: groupId,
        adminAddress: members.first,
        members: members.toSet().toList(),
      ));
      return;
    }
    final merged = <String>{...existing.members, ...members}.toList();
    await saveGroupInfo(existing.copyWith(members: merged));
  }

  Future<List<String>> getGroupMembers(String groupId) async {
    final info = await getGroupInfo(groupId);
    return info?.members ?? <String>[];
  }

  /// Removes this device from the group and deletes all local chat data.
  Future<void> leaveGroup(String groupId, String myAddress) async {
    final chatKey = groupChatKey(groupId);
    final prefs = await SharedPreferences.getInstance();
    final chats = await listChats();
    chats.removeWhere((a) => a == chatKey);
    await _writeChats(chats);
    await prefs.remove(IdentityScope.key(_messagesKey(chatKey)));
    await prefs.remove(IdentityScope.key(_groupMetaKey(groupId)));
    await prefs.remove(IdentityScope.key(_legacyGroupInfoKey(groupId)));
  }

  /// Applies a remote group metadata update. Returns false when this device
  /// is no longer a member (caller should treat as having left).
  Future<bool> applyGroupEvent(GroupEvent event, String myAddress) async {
    if (!event.members.contains(myAddress)) {
      await leaveGroup(event.groupId, myAddress);
      return false;
    }

    final existing = await getGroupInfo(event.groupId);
    final name = event.action == 'rename'
        ? event.name
        : (event.name ?? existing?.name);
    final info = GroupInfo(
      id: event.groupId,
      adminAddress: event.adminAddress,
      name: name,
      members: event.members,
    );
    await saveGroupInfo(info);
    await ensureChatExists(groupChatKey(event.groupId));
    return true;
  }

  // ---------------------------------------------------------------------
  // Messages
  // ---------------------------------------------------------------------

  String _messagesKey(String chatKey) => 'chat_messages_v1:$chatKey';

  Future<List<ChatMessage>> _rawMessages(String chatKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_messagesKey(chatKey)));
    if (raw == null || raw.isEmpty) return <ChatMessage>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <ChatMessage>[];
    return decoded
        .whereType<Map>()
        .map((m) => ChatMessage.fromJson(m.cast<String, Object?>()))
        .toList();
  }

  /// Messages in the chat, excluding ones past their auto-delete deadline.
  Future<List<ChatMessage>> listMessages(String chatKey) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final messages = await _rawMessages(chatKey);
    return messages
        .where((m) => m.expiresAtMs == null || m.expiresAtMs! > now)
        .toList();
  }

  Future<void> appendMessage(String chatKey, ChatMessage message) async {
    final messages = await _rawMessages(chatKey);
    if (messages.any((m) => m.id == message.id)) return;
    messages.add(message);
    await _writeMessages(chatKey, messages);
  }

  Future<ChatMessage?> getMessage(String chatKey, String messageId) async {
    final messages = await _rawMessages(chatKey);
    for (final message in messages) {
      if (message.id == messageId) return message;
    }
    return null;
  }

  Future<void> updateMessageStatus(
    String chatKey,
    String messageId,
    MessageStatus status,
  ) async {
    final messages = await _rawMessages(chatKey);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    messages[idx] = messages[idx].copyWith(status: status);
    await _writeMessages(chatKey, messages);
  }

  /// Applies an edit. When [requireSender] is set (remote edits), only a
  /// received message from that sender may be edited; otherwise only own
  /// messages are editable.
  Future<bool> editMessage(
    String chatKey,
    String messageId,
    String newText, {
    String? requireSender,
  }) async {
    final messages = await _rawMessages(chatKey);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return false;
    final message = messages[idx];
    if (!_mayModify(chatKey, message, requireSender)) return false;
    messages[idx] = message.copyWith(text: newText, edited: true);
    await _writeMessages(chatKey, messages);
    return true;
  }

  /// Removes a message entirely (delete for everyone). Same permission
  /// rules as [editMessage].
  Future<bool> deleteMessage(
    String chatKey,
    String messageId, {
    String? requireSender,
  }) async {
    final messages = await _rawMessages(chatKey);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return false;
    if (!_mayModify(chatKey, messages[idx], requireSender)) return false;
    messages.removeAt(idx);
    await _writeMessages(chatKey, messages);
    return true;
  }

  bool _mayModify(String chatKey, ChatMessage message, String? requireSender) {
    if (requireSender == null) return message.isMe;
    if (message.isMe) return false;
    final sender = message.senderAddress ?? chatKey;
    return sender == requireSender;
  }

  Future<void> markGroupMessageHandedOff(
    String chatKey,
    String messageId,
    String handedOffTo,
  ) async {
    final messages = await _rawMessages(chatKey);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final remaining =
        messages[idx].pendingTo.where((a) => a != handedOffTo).toList();
    messages[idx] = messages[idx].copyWith(
      pendingTo: remaining,
      status: remaining.isEmpty && messages[idx].status == MessageStatus.pending
          ? MessageStatus.sent
          : messages[idx].status,
    );
    await _writeMessages(chatKey, messages);
  }

  /// Applies an end-to-end delivery ack from [ackedBy] for [messageId].
  /// Returns true when the message state changed.
  Future<bool> applyDeliveryAck(
    String chatKey,
    String messageId,
    String ackedBy, {
    required List<String> allRecipients,
  }) async {
    final messages = await _rawMessages(chatKey);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return false;
    final message = messages[idx];
    if (!message.isMe) return false;

    if (allRecipients.length <= 1) {
      if (message.status == MessageStatus.delivered) return false;
      messages[idx] = message.copyWith(status: MessageStatus.delivered);
    } else {
      if (message.deliveredTo.contains(ackedBy)) return false;
      final delivered = [...message.deliveredTo, ackedBy];
      final allDelivered =
          allRecipients.every((recipient) => delivered.contains(recipient));
      messages[idx] = message.copyWith(
        deliveredTo: delivered,
        pendingTo: message.pendingTo.where((a) => a != ackedBy).toList(),
        status: allDelivered ? MessageStatus.delivered : message.status,
      );
    }
    await _writeMessages(chatKey, messages);
    return true;
  }

  /// Marks view-once media as viewed and detaches the (deleted) media file.
  Future<void> markMediaViewed(String chatKey, String messageId) async {
    final messages = await _rawMessages(chatKey);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    messages[idx] = messages[idx].copyWith(viewed: true, clearMedia: true);
    await _writeMessages(chatKey, messages);
  }

  /// Media ids referenced by messages in a chat (used to clean files up
  /// when messages are cleared or a chat is deleted).
  Future<List<String>> mediaIdsIn(String chatKey) async {
    final messages = await _rawMessages(chatKey);
    return [
      for (final m in messages)
        if (m.mediaId != null) m.mediaId!,
    ];
  }

  /// Physically purges expired messages. Returns the chat keys that changed
  /// and the media ids of purged attachments (files should be deleted).
  Future<(Set<String>, List<String>)> sweepExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final changed = <String>{};
    final mediaIds = <String>[];
    for (final chatKey in await listChats()) {
      final messages = await _rawMessages(chatKey);
      final kept = <ChatMessage>[];
      for (final message in messages) {
        if (message.expiresAtMs == null || message.expiresAtMs! > now) {
          kept.add(message);
        } else if (message.mediaId != null) {
          mediaIds.add(message.mediaId!);
        }
      }
      if (kept.length != messages.length) {
        await _writeMessages(chatKey, kept);
        changed.add(chatKey);
      }
    }
    return (changed, mediaIds);
  }

  Future<void> _writeMessages(
    String chatKey,
    List<ChatMessage> messages,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_messagesKey(chatKey)),
      jsonEncode(messages.map((m) => m.toJson()).toList()),
    );
  }

  Future<void> _writeChats(List<String> chats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(IdentityScope.key(_chatsKey), jsonEncode(chats));
  }
}
