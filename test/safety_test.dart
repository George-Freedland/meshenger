import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:meshenger/core/models/incoming_message.dart';
import 'package:meshenger/core/services/chat_storage.dart';
import 'package:meshenger/core/services/identity_scope.dart';
import 'package:meshenger/core/services/identity_service.dart';
import 'package:meshenger/core/services/mesh_activity.dart';
import 'package:meshenger/core/services/messenger_service.dart';
import 'package:meshenger/core/services/network_service.dart';
import 'package:meshenger/core/services/safety_service.dart';
import 'package:meshenger/core/services/settings_service.dart';
import 'package:meshenger/core/transport/envelope_codec.dart';
import 'package:meshenger/features/apps/network_screen.dart';
import 'package:meshenger/features/chat/chat_screen.dart';
import 'package:meshenger/features/onboarding/terms_screen.dart';

/// A device with no mail app: records what would have opened.
class _NoMailApp extends UrlLauncherPlatform with MockPlatformInterfaceMixin {
  final List<String> opened = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => false;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    opened.add(url);
    return false;
  }
}

void main() {
  late String myAddress;
  late String aliceAddress;
  late _NoMailApp launcher;
  String? clipboard;
  final safety = SafetyService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    launcher = _NoMailApp();
    UrlLauncherPlatform.instance = launcher;
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    MeshActivityLog.instance.resetCache();
    safety.resetCache();
    final me = await Ed25519().newKeyPair();
    await IdentityService.instance.debugUnlockWithKeyPair(me, nickname: 'Me');
    myAddress = base64Encode((await me.extractPublicKey()).bytes);
    IdentityScope.setActive(myAddress);

    final alice = await Ed25519().newKeyPair();
    aliceAddress = base64Encode((await alice.extractPublicKey()).bytes);
    final now = DateTime.now().millisecondsSinceEpoch;
    final later = now + const Duration(hours: 1).inMilliseconds;
    await NetworkService.instance.upsert(NetworkPost(
      id: 'g1',
      author: aliceAddress,
      authorNick: 'Alice',
      text: 'hello square',
      tsMs: now,
      expiresMs: later,
      hops: 1,
    ));
    await NetworkService.instance.upsert(NetworkPost(
      id: 'home',
      author: aliceAddress,
      authorNick: 'Alice',
      text: '<h1>Alice home</h1>',
      tsMs: now,
      expiresMs: later,
      hops: 1,
      scope: EnvelopeCodec.scopeSite,
      kind: 'page',
      path: '',
    ));
  });

  test('blocks and hidden posts persist per identity', () async {
    final changes = <void>[];
    final sub = safety.onChanged.listen(changes.add);

    await safety.block(aliceAddress);
    await safety.hidePost('g1');
    expect(await safety.isBlocked(aliceAddress), isTrue);
    expect(await safety.hiddenPosts(), {'g1'});

    IdentityScope.setActive('someone-else');
    expect(await safety.isBlocked(aliceAddress), isFalse);
    IdentityScope.setActive(myAddress);

    await safety.unblock(aliceAddress);
    await safety.unhideAllPosts();
    expect(await safety.blocked(), isEmpty);
    expect(await safety.hiddenPosts(), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(changes, hasLength(4));
    await sub.cancel();
  });

  test('messages and calls from a blocked person are dropped on arrival',
      () async {
    await SettingsService.instance.setSoundEnabled(false);
    final calls = <IncomingMessage>[];
    final sub = MessengerService.instance.onCallSignal.listen(calls.add);
    final hello = IncomingMessage(
      fromAddress: aliceAddress,
      id: 'm1',
      text: 'hi',
      timestamp: DateTime.now(),
    );
    final ring = IncomingMessage(
      fromAddress: aliceAddress,
      id: 'c1',
      text: '',
      timestamp: DateTime.now(),
      action: 'call-invite',
      targetId: 'call-1',
    );

    await safety.block(aliceAddress);
    await MessengerService.instance.debugHandleIncoming(hello);
    await MessengerService.instance.debugHandleIncoming(ring);
    await Future<void>.delayed(Duration.zero);
    expect(await ChatStorage.instance.listMessages(aliceAddress), isEmpty);
    expect(calls, isEmpty);

    await safety.unblock(aliceAddress);
    await MessengerService.instance.debugHandleIncoming(hello);
    await MessengerService.instance.debugHandleIncoming(ring);
    await Future<void>.delayed(Duration.zero);
    expect(
      (await ChatStorage.instance.listMessages(aliceAddress)).single.text,
      'hi',
    );
    expect(calls.single.targetId, 'call-1');
    await sub.cancel();
  });

  test('a report email carries the identity and post, nothing private', () {
    final post = NetworkPost(
      id: 'g1',
      author: aliceAddress,
      authorNick: 'Alice',
      text: 'buy   cheap\nstuff',
      tsMs: 0,
      expiresMs: 1,
      hops: 1,
    );
    final body = reportEmailBody(
      reason: ReportReason.spam,
      address: aliceAddress,
      name: 'Alice',
      post: post,
      details: ' keeps posting this ',
      now: DateTime.utc(2026, 10, 30),
    );
    expect(body, contains('Reason: Spam or scam'));
    expect(body, contains('Reported identity: $aliceAddress'));
    expect(body, contains('Global post (id g1)'));
    expect(body, contains('Text: buy cheap stuff'));
    expect(body, contains('Details: keeps posting this'));
    expect(body, contains('Reported at: 2026-10-30T00:00:00.000Z'));
  });

  testWidgets('blocking hides their posts and site until unblocked',
      (tester) async {
    await safety.block(aliceAddress);
    await tester.pumpWidget(const MaterialApp(home: NetworkScreen()));
    await tester.pumpAndSettle();
    expect(find.text('hello square'), findsNothing);

    await tester.enterText(
        find.byKey(const ValueKey('network-address-bar')), aliceAddress);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(find.text('You blocked Alice'), findsOneWidget);
    expect(find.text('Alice home', findRichText: true), findsNothing);

    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(find.text('Alice home', findRichText: true), findsOneWidget);
    expect(await safety.isBlocked(aliceAddress), isFalse);
  });

  testWidgets('reporting a post hides it and blocks the author',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NetworkScreen()));
    await tester.pumpAndSettle();
    expect(find.text('hello square'), findsOneWidget);

    await tester.tap(find.byTooltip('Post options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Report post…'));
    await tester.pumpAndSettle();

    final send = find.widgetWithText(FilledButton, 'Send report');
    expect(tester.widget<FilledButton>(send).onPressed, isNull,
        reason: 'a reason must be picked first');
    await tester.tap(find.text('Harassment or hate'));
    await tester.pumpAndSettle();
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(find.text('hello square'), findsNothing);
    expect(await safety.hiddenPosts(), {'g1'});
    expect(await safety.isBlocked(aliceAddress), isTrue);

    final mail = Uri.parse(launcher.opened.single);
    expect(mail.scheme, 'mailto');
    expect(mail.queryParameters['subject'],
        'Meshenger report: Harassment or hate');
    expect(mail.queryParameters['body'],
        contains('Reported identity: $aliceAddress'));
    expect(find.textContaining('Report copied'), findsOneWidget,
        reason: 'no mail app, so it falls back to the clipboard');
    expect(clipboard, startsWith('To: '));
    expect(clipboard, contains('Content: Global post (id g1)'));
  });

  testWidgets('a blocked chat shows the notice instead of the composer',
      (tester) async {
    await safety.block(aliceAddress);
    await tester
        .pumpWidget(MaterialApp(home: ChatScreen(peerAddress: aliceAddress)));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('You blocked'), findsOneWidget);
    expect(find.text('Unblock'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Message…'), findsNothing);
  });

  testWidgets('agreeing to the terms is remembered', (tester) async {
    final router = GoRouter(
      initialLocation: '/terms',
      routes: [
        GoRoute(path: '/terms', builder: (_, __) => const TermsScreen()),
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('login')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('Meshenger Terms of Use'), findsOneWidget);
    expect(find.text('Zero tolerance for abuse'), findsOneWidget);

    await tester.tap(find.text('Agree and continue'));
    await tester.pumpAndSettle();
    expect(find.text('login'), findsOneWidget);
    expect(await safety.termsAccepted(), isTrue);
  });
}
