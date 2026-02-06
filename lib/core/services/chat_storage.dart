import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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

  Future<void> _writeChats(List<String> chats) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_chatsKey, jsonEncode(chats));
  }
}

