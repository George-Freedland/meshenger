import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/group_info.dart';
import '../models/message.dart';

/// Chat keys are either a peer address (1:1) or `group:{id}` (group chat).
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
    final raw = prefs.getString(_chatsKey);
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
    await prefs.remove(_messagesKey(chatKey));
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

  // ---------------------------------------------------------------------
  // Group metadata
  // ---------------------------------------------------------------------

  String _groupMetaKey(String groupId) => 'group_meta_v2:$groupId';

  /// Legacy member-only storage (pre-admin/name support).
  String _legacyGroupInfoKey(String groupId) => 'group_info_v1:$groupId';

  Future<GroupInfo?> getGroupInfo(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_groupMetaKey(groupId));
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return GroupInfo.fromJson(decoded.cast<String, Object?>());
      }
    }

    // Migrate legacy member-list-only records.
    final legacy = prefs.getString(_legacyGroupInfoKey(groupId));
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
    await prefs.remove(_legacyGroupInfoKey(groupId));
    return info;
  }

  Future<void> saveGroupInfo(GroupInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_groupMetaKey(info.id), jsonEncode(info.toJson()));
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
    final info = await getGroupInfo(groupId);
    if (info == null) return;
    final chatKey = groupChatKey(groupId);
    final prefs = await SharedPreferences.getInstance();
    final chats = await listChats();
    chats.removeWhere((a) => a == chatKey);
    await _writeChats(chats);
    await prefs.remove(_messagesKey(chatKey));
    await prefs.remove(_groupMetaKey(groupId));
    await prefs.remove(_legacyGroupInfoKey(groupId));
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

  Future<List<ChatMessage>> listMessages(String chatKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_messagesKey(chatKey));
    if (raw == null || raw.isEmpty) return <ChatMessage>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <ChatMessage>[];
    return decoded
        .whereType<Map>()
        .map((m) => ChatMessage.fromJson(m.cast<String, Object?>()))
        .toList();
  }

  Future<void> appendMessage(String chatKey, ChatMessage message) async {
    final messages = await listMessages(chatKey);
    if (messages.any((m) => m.id == message.id)) return;
    messages.add(message);
    await _writeMessages(chatKey, messages);
  }

  Future<void> updateMessageStatus(
    String chatKey,
    String messageId,
    MessageStatus status,
  ) async {
    final messages = await listMessages(chatKey);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    messages[idx] = messages[idx].copyWith(status: status);
    await _writeMessages(chatKey, messages);
  }

  Future<void> markGroupMessageDelivered(
    String chatKey,
    String messageId,
    String deliveredTo,
  ) async {
    final messages = await listMessages(chatKey);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    final remaining =
        messages[idx].pendingTo.where((a) => a != deliveredTo).toList();
    messages[idx] = messages[idx].copyWith(
      pendingTo: remaining,
      status: remaining.isEmpty ? MessageStatus.sent : MessageStatus.pending,
    );
    await _writeMessages(chatKey, messages);
  }

  Future<void> _writeMessages(
    String chatKey,
    List<ChatMessage> messages,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _messagesKey(chatKey),
      jsonEncode(messages.map((m) => m.toJson()).toList()),
    );
  }

  Future<void> _writeChats(List<String> chats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_chatsKey, jsonEncode(chats));
  }
}
