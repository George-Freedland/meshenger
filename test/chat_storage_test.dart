import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/models/message.dart';
import 'package:meshenger/core/services/chat_storage.dart';
import 'package:meshenger/core/services/identity_scope.dart';

/// Unread bookkeeping + full-chat deletion, the two behaviors behind the
/// chat-list badge staying fresh.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IdentityScope.setActive('chatStorageTestKey');

  const peer = 'peerAddressAAAA';
  final storage = ChatStorage.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('markRead reports whether anything was cleared', () async {
    await storage.ensureChatExists(peer);
    expect(await storage.markRead(peer), isFalse,
        reason: 'nothing unread yet — no change ping needed');

    await storage.markUnread(peer);
    await storage.markUnread(peer);
    expect(await storage.unreadCounts(), {peer: 2});

    expect(await storage.markRead(peer), isTrue,
        reason: 'badge cleared — this is what pings the chat list');
    expect(await storage.markRead(peer), isFalse,
        reason: 'second call is a no-op, so ping loops cannot happen');
    expect(await storage.totalUnread(), 0);
  });

  test('deleteChat removes the conversation, its messages, and its badge',
      () async {
    await storage.ensureChatExists(peer);
    await storage.appendMessage(
      peer,
      ChatMessage(
        id: 'm1',
        text: 'hello',
        isMe: false,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
      ),
    );
    await storage.markUnread(peer);

    await storage.deleteChat(peer);

    expect(await storage.listChats(), isEmpty);
    expect(await storage.listMessages(peer), isEmpty);
    expect(await storage.totalUnread(), 0);
  });
}
