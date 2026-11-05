import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/models/message.dart';
import 'package:meshenger/core/services/call_log_service.dart';
import 'package:meshenger/core/services/call_service.dart';
import 'package:meshenger/core/services/chat_storage.dart';
import 'package:meshenger/core/services/identity_scope.dart';
import 'package:meshenger/core/services/identity_service.dart';
import 'package:meshenger/core/services/messenger_service.dart';
import 'package:meshenger/features/chat/call_history_screen.dart';
import 'package:meshenger/features/chat/chat_screen.dart';

void main() {
  late String peer;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final me = await Ed25519().newKeyPair();
    await IdentityService.instance.debugUnlockWithKeyPair(me, nickname: 'Me');
    IdentityScope.setActive(base64Encode((await me.extractPublicKey()).bytes));
    final other = await Ed25519().newKeyPair();
    peer = base64Encode((await other.extractPublicKey()).bytes);
  });

  Future<void> addCall(String callId, DateTime start,
      {bool video = false, int seconds = 0}) async {
    await MessengerService.instance.noteCall(peer,
        id: 'call:$callId:started',
        text: CallService.chatLine(video: video, outgoing: true, outcome: null),
        at: start,
        video: video);
    final end = start.add(Duration(seconds: seconds));
    await MessengerService.instance.noteCall(peer,
        id: 'call:$callId:completed',
        text: CallService.chatLine(
            video: video,
            outgoing: true,
            outcome: CallOutcome.completed,
            durationSeconds: seconds),
        at: end,
        video: video);
    await CallLogService.instance.add(CallLogEntry(
      peer: peer,
      video: video,
      outgoing: true,
      tsMs: end.millisecondsSinceEpoch,
      outcome: CallOutcome.completed,
      durationSeconds: seconds,
      callId: callId,
    ));
  }

  testWidgets('the chat shows when a call started and ended', (tester) async {
    await tester.runAsync(
        () => addCall('a', DateTime(2026, 11, 3, 20, 12), seconds: 480));
    await tester.pumpWidget(MaterialApp(home: ChatScreen(peerAddress: peer)));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(find.text('Phone call started at 8:12 PM'), findsOneWidget);
    expect(find.text('Phone call ended at 8:20 PM · 8 min'), findsOneWidget);
  });

  testWidgets('call history filters, removes one, and clears the rest',
      (tester) async {
    await tester.runAsync(() async {
      await addCall('a', DateTime(2026, 11, 3, 20, 12), seconds: 60);
      await addCall('b', DateTime(2026, 11, 3, 21), video: true, seconds: 30);
    });
    await tester.pumpWidget(MaterialApp(home: CallHistoryScreen(peer: peer)));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(find.text('Phone call'), findsWidgets);
    expect(find.text('Video chat'), findsWidgets);
    await tester.tap(find.widgetWithText(Tab, 'Video'));
    await tester.pumpAndSettle();
    expect(find.text('Outgoing · 30 s'), findsOneWidget);
    expect(find.text('Outgoing · 1 min'), findsNothing);

    // Swiping a call away takes its lines out of the chat too.
    await tester.drag(find.text('Outgoing · 30 s'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    final lines =
        await tester.runAsync(() => ChatStorage.instance.listMessages(peer));
    expect(lines!.map((m) => m.id), ['call:a:started', 'call:a:completed']);

    await tester.tap(find.widgetWithText(Tab, 'All'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Clear call history'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();

    expect(find.text('No calls with them yet.'), findsOneWidget);
    final left = await tester.runAsync(() async => (
          await CallLogService.instance.list(),
          await ChatStorage.instance.listMessages(peer),
        ));
    expect(left!.$1, isEmpty);
    expect(left.$2.where(ChatStorage.isCallLine), isEmpty);
    expect(left.$2.whereType<ChatMessage>(), isEmpty);
  });
}
