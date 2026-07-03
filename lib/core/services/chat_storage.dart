import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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

  Future<void> deleteChat(String chatKey) async {
    final prefs = await SharedPreferences.getInstance();
    final chats = await listChats();
    chats.removeWhere((a) => a == chatKey);
    await _writeChats(chats);

    await prefs.remove(_messagesKey(chatKey));
    if (isGroupChat(chatKey)) {
      await prefs.remove(_groupInfoKey(groupIdOf(chatKey)));
    }
  }

  // ---------------------------------------------------------------------
  // Group membership
  // ---------------------------------------------------------------------

  String _groupInfoKey(String groupId) => 'group_info_v1:$groupId';

  /// Stores (or merges) the member list for a group.
  Future<void> upsertGroupMembers(String groupId, List<String> members) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await getGroupMembers(groupId);
    final merged = <String>{...existing, ...members}.toList();
    await prefs.setString(_groupInfoKey(groupId), jsonEncode(merged));
  }

  Future<List<String>> getGroupMembers(String groupId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_groupInfoKey(groupId));
    if (raw == null || raw.isEmpty) return <String>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <String>[];
    return decoded.whereType<String>().toList();
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

  /// Records that [deliveredTo] received the group message; flips the
  /// message to "sent" once no members remain pending.
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
