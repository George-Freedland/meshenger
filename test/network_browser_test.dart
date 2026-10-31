import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/services/identity_scope.dart';
import 'package:meshenger/core/services/identity_service.dart';
import 'package:meshenger/core/services/mesh_activity.dart';
import 'package:meshenger/core/services/network_bookmarks.dart';
import 'package:meshenger/core/services/network_service.dart';
import 'package:meshenger/core/services/settings_service.dart';
import 'package:meshenger/core/transport/envelope_codec.dart';
import 'package:meshenger/features/apps/network_screen.dart';
import 'package:meshenger/features/network/page_editor_screen.dart';

void main() {
  late String myAddress;
  late String aliceAddress;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MeshActivityLog.instance.resetCache();
    final me = await Ed25519().newKeyPair();
    await IdentityService.instance.debugUnlockWithKeyPair(me, nickname: 'Me');
    myAddress = base64Encode((await me.extractPublicKey()).bytes);
    IdentityScope.setActive(myAddress);

    final alice = await Ed25519().newKeyPair();
    aliceAddress = base64Encode((await alice.extractPublicKey()).bytes);
    final now = DateTime.now().millisecondsSinceEpoch;
    final hourLater = now + const Duration(hours: 1).inMilliseconds;
    final store = NetworkService.instance;
    await store.upsert(NetworkPost(
      id: 'g1',
      author: aliceAddress,
      authorNick: 'Alice',
      text: 'hello square',
      tsMs: now,
      expiresMs: hourLater,
      hops: 1,
    ));
    await store.upsert(NetworkPost(
      id: 'home',
      author: aliceAddress,
      authorNick: 'Alice',
      text: '<h1>Alice home</h1><p><a href="/blog">read my blog</a></p>',
      tsMs: now,
      expiresMs: hourLater,
      hops: 1,
      scope: EnvelopeCodec.scopeSite,
      kind: 'page',
      path: '',
    ));
    await store.upsert(NetworkPost(
      id: 'blog',
      author: aliceAddress,
      authorNick: 'Alice',
      text: '<h1>Blog body</h1>',
      tsMs: now,
      expiresMs: hourLater,
      hops: 1,
      scope: EnvelopeCodec.scopeSite,
      kind: 'page',
      path: 'blog',
      title: 'My blog',
    ));
    await store.upsert(NetworkPost(
      id: 's1',
      author: aliceAddress,
      authorNick: 'Alice',
      text: 'a post on my site',
      tsMs: now,
      expiresMs: hourLater,
      hops: 1,
      scope: EnvelopeCodec.scopeSite,
    ));
  });

  testWidgets('global, then a pasted key opens that site and its pages',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NetworkScreen()));
    await tester.pumpAndSettle();

    expect(find.text('hello square'), findsOneWidget);
    expect(find.text('a post on my site'), findsNothing,
        reason: 'site posts stay off global');

    await tester.enterText(
        find.byKey(const ValueKey('network-address-bar')), aliceAddress);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();

    expect(find.text('Alice home', findRichText: true), findsOneWidget);
    expect(find.text('My blog'), findsOneWidget);
    expect(find.text('a post on my site'), findsOneWidget);
    expect(find.text('hello square'), findsNothing);

    await tester.tap(find.text('My blog'));
    await tester.pumpAndSettle();
    expect(find.text('Blog body', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Alice home', findRichText: true), findsOneWidget);
  });

  testWidgets('bookmark a site under a nickname, reopen, rename, remove',
      (tester) async {
    await tester
        .pumpWidget(MaterialApp(home: NetworkScreen(initialUrl: aliceAddress)));
    await tester.pumpAndSettle();
    expect(find.text('Alice home', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('Bookmark this page'));
    await tester.pumpAndSettle();
    expect(find.text('Add bookmark'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, "Alice's site"), 'Alice HQ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Edit bookmark'), findsOneWidget);
    final saved = (await NetworkBookmarks.instance.list()).single;
    expect(saved.name, 'Alice HQ');
    expect(saved.url, aliceAddress);

    await tester.enterText(
        find.byKey(const ValueKey('network-address-bar')), 'global');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    expect(find.text('hello square'), findsOneWidget);
    expect(find.byTooltip('Bookmark this page'), findsOneWidget);

    await tester.tap(find.byTooltip('Bookmarks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alice HQ'));
    await tester.pumpAndSettle();
    expect(find.text('Alice home', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('Edit bookmark'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Alice HQ'), 'Al');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect((await NetworkBookmarks.instance.list()).single.name, 'Al');

    await tester.tap(find.byTooltip('Edit bookmark'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove bookmark'));
    await tester.pumpAndSettle();
    expect(await NetworkBookmarks.instance.list(), isEmpty);
    expect(find.byTooltip('Bookmark this page'), findsOneWidget);
  });

  testWidgets('Home leaves the browser however deep you are', (tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, __) => const Scaffold(body: Text('main menu')),
        ),
        GoRoute(
          path: '/app/network',
          builder: (_, __) => const NetworkScreen(),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.push('/app/network');
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('network-address-bar')), aliceAddress);
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pumpAndSettle();
    await tester.tap(find.text('My blog'));
    await tester.pumpAndSettle();
    expect(find.text('Blog body', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();
    expect(find.text('main menu'), findsOneWidget);
    expect(find.byType(NetworkScreen), findsNothing);
  });

  testWidgets('on a phone the toolbar fits and refresh moves to the menu',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 740 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester
        .pumpWidget(MaterialApp(home: NetworkScreen(initialUrl: aliceAddress)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('My blog'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Home'), findsOneWidget);
    expect(find.byTooltip('Back'), findsNothing);
    expect(find.byTooltip('Refresh from nearby devices'), findsNothing);
    expect(find.byTooltip('Bookmark this page'), findsOneWidget);

    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    expect(find.text('Forward'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    await tester.tap(find.text('Forward'));
    await tester.pumpAndSettle();
    expect(find.text('Blog body', findRichText: true), findsOneWidget);
  });

  testWidgets('mesh activity minimizes to one line and expands',
      (tester) async {
    await MeshActivityLog.instance.recordJoin(aliceAddress, nickname: 'Alice');
    await MeshActivityLog.instance.recordLeave('bob-key', nickname: 'Bob');

    await tester.pumpWidget(const MaterialApp(home: NetworkScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Bob left · just now'), findsOneWidget,
        reason: 'minimized: only the latest event');
    expect(find.text('Alice joined your mesh'), findsNothing);

    await tester.tap(find.text('Bob left · just now'));
    await tester.pumpAndSettle();
    expect(find.text('Mesh activity'), findsOneWidget);
    expect(find.text('Alice joined your mesh'), findsOneWidget);
    expect(find.text('Bob left'), findsOneWidget);
    expect(await SettingsService.instance.getActivityExpanded(), isTrue);

    await tester.tap(find.text('Mesh activity'));
    await tester.pumpAndSettle();
    expect(find.text('Alice joined your mesh'), findsNothing);
    expect(await SettingsService.instance.getActivityExpanded(), isFalse);
  });

  testWidgets('posting on global shows up in the square', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NetworkScreen()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Message everyone on the mesh…'),
      'my words',
    );
    await tester.tap(find.byTooltip('Post to global'));
    await tester.pumpAndSettle();

    expect(find.text('my words'), findsOneWidget);
  });

  testWidgets('the editor publishes my home page', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) =>
                PageEditorScreen(myAddress: myAddress, initialPath: ''),
          )),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();

    final home = await NetworkService.instance.page(myAddress, '');
    expect(home, isNotNull);
    expect(home!.isPrivate, isFalse);
    expect(home.text, contains('<h1>'));
  });
}
