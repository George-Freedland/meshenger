import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/models/message.dart';
import 'package:meshenger/core/services/call_log_service.dart';
import 'package:meshenger/core/services/call_service.dart';
import 'package:meshenger/core/services/chat_storage.dart';
import 'package:meshenger/core/services/identity_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  IdentityScope.setActive('callsTestKey');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('chat lines', () {
    String line(CallOutcome? outcome,
            {bool video = false, bool outgoing = true, int seconds = 0}) =>
        CallService.chatLine(
          video: video,
          outgoing: outgoing,
          outcome: outcome,
          durationSeconds: seconds,
        );

    test('say when a call started and ended, and how long it lasted', () {
      expect(line(null), 'Phone call started at {time}');
      expect(line(CallOutcome.completed, seconds: 480),
          'Phone call ended at {time} · 8 min');
      expect(line(null, video: true), 'Video chat started at {time}');
    });

    test('say what happened to calls that never connected', () {
      expect(line(CallOutcome.missed, outgoing: false, video: true),
          'Missed video chat at {time}');
      expect(line(CallOutcome.declined, outgoing: false),
          'You declined a phone call at {time}');
      expect(line(CallOutcome.declined), 'Phone call at {time} · declined');
      expect(line(CallOutcome.noAnswer), 'Phone call at {time} · no answer');
      expect(line(CallOutcome.canceled), 'Phone call at {time} · canceled');
      expect(line(CallOutcome.busy),
          'Phone call at {time} · they were on another call');
    });

    test('lengths read naturally', () {
      expect(CallService.callLength(45), '45 s');
      expect(CallService.callLength(60), '1 min');
      expect(CallService.callLength(3600), '1 h');
      expect(CallService.callLength(3900), '1 h 5 min');
    });
  });

  group('call history', () {
    final log = CallLogService.instance;

    CallLogEntry entry(String peer, int ts, {bool video = false}) =>
        CallLogEntry(
          peer: peer,
          video: video,
          outgoing: true,
          tsMs: ts,
          outcome: CallOutcome.completed,
          callId: 'call-$peer-$ts',
        );

    test('lists one person, or one kind, newest first', () async {
      await log.add(entry('ann', 1));
      await log.add(entry('bob', 2, video: true));
      await log.add(entry('ann', 3, video: true));

      expect((await log.list()).map((e) => e.tsMs), [3, 2, 1]);
      expect((await log.list(peer: 'ann')).map((e) => e.tsMs), [3, 1]);
      expect((await log.list(video: true)).map((e) => e.tsMs), [3, 2]);
      expect((await log.list()).first.callId, 'call-ann-3');
    });

    test('clears what was asked for and nothing else', () async {
      await log.add(entry('ann', 1));
      await log.add(entry('ann', 2, video: true));
      await log.add(entry('bob', 3));

      final removed = await log.clear(peer: 'ann', video: false);
      expect(removed.map((e) => e.tsMs), [1]);
      expect((await log.list()).map((e) => e.tsMs), [3, 2]);

      await log.remove(entry('bob', 3));
      expect((await log.list()).map((e) => e.tsMs), [2]);

      await log.clear();
      expect(await log.list(), isEmpty);
    });
  });

  test('call lines come out of a chat by kind or by call, messages stay',
      () async {
    final storage = ChatStorage.instance;
    const peer = 'callPeer';
    ChatMessage callLine(String id, {required bool video}) => ChatMessage(
          id: id,
          text: 'Phone call started at {time}',
          isMe: false,
          timestamp: DateTime(2026, 11, 3, 20, 12),
          status: MessageStatus.sent,
          isSystem: true,
          kind: video
              ? ChatStorage.videoCallLineKind
              : ChatStorage.callLineKind,
        );

    await storage.ensureChatExists(peer);
    await storage.appendMessage(
        peer,
        ChatMessage(
          id: 'hello',
          text: 'hi',
          isMe: true,
          timestamp: DateTime(2026, 11, 3, 20),
          status: MessageStatus.sent,
        ));
    await storage.appendMessage(peer, callLine('call:a:started', video: false));
    await storage.appendMessage(
        peer, callLine('call:a:completed', video: false));
    await storage.appendMessage(peer, callLine('call:b:missed', video: true));

    expect(await storage.removeCallLines(peer, callId: 'a'), isTrue);
    expect((await storage.listMessages(peer)).map((m) => m.id),
        ['hello', 'call:b:missed']);

    expect(await storage.removeCallLines(peer, video: false), isFalse);
    expect(await storage.removeCallLines(peer, video: true), isTrue);
    expect((await storage.listMessages(peer)).map((m) => m.id), ['hello']);
  });
}
