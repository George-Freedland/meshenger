import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/services/identity_scope.dart';
import 'package:meshenger/core/services/identity_service.dart';
import 'package:meshenger/core/services/network_service.dart';
import 'package:meshenger/core/transport/envelope_codec.dart';
import 'package:meshenger/features/apps/network_screen.dart';
import 'package:meshenger/features/network/page_editor_screen.dart';

void main() {
  late String myAddress;
  late String aliceAddress;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
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
