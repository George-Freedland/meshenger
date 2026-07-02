import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';

class ChatStorage {
  ChatStorage._();
  static final ChatStorage instance = ChatStorage._();

  static const _chatsKey = 'chats_v1'; // list of peer addresses

  Future<List<String>> listChats() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_chatsKey);
    if (raw == null || raw.isEmpty) return const <String>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <String>[];
    return decoded.whereType<String>().toList();
  }

  Future<void> ensureChatExists(String peerAddress) async {
    final chats = await listChats();
    if (!chats.contains(peerAddress)) {
      chats.add(peerAddress);
      await _writeChats(chats);
    }
  }

  Future<void> deleteChat(String peerAddress) async {
    final prefs = await SharedPreferences.getInstance();
    final chats = await listChats();
    chats.removeWhere((a) => a == peerAddress);
    await _writeChats(chats);

    // Remove any per-chat stored data (future-proof).
    await prefs.remove(_messagesKey(peerAddress));
  }

  String _messagesKey(String peerAddress) => 'chat_messages_v1:$peerAddress';

  Future<List<ChatMessage>> listMessages(String peerAddress) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_messagesKey(peerAddress));
    if (raw == null || raw.isEmpty) return const <ChatMessage>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const <ChatMessage>[];
    return decoded
        .whereType<Map>()
        .map((m) => ChatMessage.fromJson(m.cast<String, Object?>()))
        .toList();
  }

  Future<void> appendMessage(String peerAddress, ChatMessage message) async {
    final messages = await listMessages(peerAddress);
    if (messages.any((m) => m.id == message.id)) return;
    messages.add(message);
    await _writeMessages(peerAddress, messages);
  }

  Future<void> updateMessageStatus(
    String peerAddress,
    String messageId,
    MessageStatus status,
  ) async {
    final messages = await listMessages(peerAddress);
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;
    messages[idx] = messages[idx].copyWith(status: status);
    await _writeMessages(peerAddress, messages);
  }

  Future<void> _writeMessages(
    String peerAddress,
    List<ChatMessage> messages,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _messagesKey(peerAddress),
      jsonEncode(messages.map((m) => m.toJson()).toList()),
    );
  }

  Future<void> _writeChats(List<String> chats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_chatsKey, jsonEncode(chats));
  }
}

