import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/models/post_attachment.dart';
import 'package:meshenger/core/services/blob_service.dart';
import 'package:meshenger/core/services/identity_scope.dart';
import 'package:meshenger/core/services/identity_service.dart';
import 'package:meshenger/core/services/mesh_activity.dart';
import 'package:meshenger/core/services/network_service.dart';
import 'package:meshenger/core/ui/audio_track_card.dart';
import 'package:meshenger/features/apps/network_screen.dart';

/// File work started by a widget advances one step per real-time pause
/// plus frame, so alternate the two until it settles.
Future<void> _settleFiles(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
}

void main() {
  late Directory blobs;
  late String aliceAddress;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MeshActivityLog.instance.resetCache();
    final me = await Ed25519().newKeyPair();
    await IdentityService.instance.debugUnlockWithKeyPair(me, nickname: 'Me');
    IdentityScope.setActive(base64Encode((await me.extractPublicKey()).bytes));
    final alice = await Ed25519().newKeyPair();
    aliceAddress = base64Encode((await alice.extractPublicKey()).bytes);
    blobs = Directory.systemTemp.createTempSync('blobs');
    BlobService.instance.directoryForTesting = blobs;
  });

  tearDown(() => blobs.deleteSync(recursive: true));

  Future<void> post(PostAttachment attachment, {String text = ''}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await NetworkService.instance.upsert(NetworkPost(
      id: attachment.sha256.substring(0, 8),
      author: aliceAddress,
      authorNick: 'Alice',
      text: text,
      tsMs: now,
      expiresMs: now + 3600000,
      hops: 1,
      attachment: attachment,
    ));
  }

  testWidgets('a song on global shows its tags and plays after fetching',
      (tester) async {
    await post(const PostAttachment(
      name: 'mesh_love.mp3',
      mime: 'audio/mpeg',
      size: 4 * 1024 * 1024,
      sha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      title: 'Mesh Love',
      artist: 'The Nodes',
      album: 'Offline',
      durationMs: 201000,
    ), text: 'new single');

    await tester.pumpWidget(const MaterialApp(home: NetworkScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Mesh Love'), findsOneWidget);
    expect(find.text('The Nodes — Offline'), findsOneWidget);
    expect(find.text('3:21'), findsOneWidget, reason: 'length from the tags');
    expect(find.text('new single'), findsOneWidget);

    await tester.tap(find.byTooltip('Play'));
    await _settleFiles(tester);
    expect(find.text('Looking for it nearby…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.runAsync(BlobService.instance.detach);
  });

  testWidgets('any other file gets a file card with a download button',
      (tester) async {
    await post(const PostAttachment(
      name: 'flyer.pdf',
      mime: 'application/pdf',
      size: 2500000,
      sha256:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    ));
    await tester.pumpWidget(const MaterialApp(home: NetworkScreen()));
    await tester.pumpAndSettle();
    expect(find.text('flyer.pdf'), findsOneWidget);
    expect(find.text('2.4 MB · PDF'), findsOneWidget);
    expect(find.byTooltip('Download'), findsOneWidget);
  });

  testWidgets('a song in a chat reads its tags from the file', (tester) async {
    final file = File('${blobs.path}/song.mp3');
    List<int> frame(String id, List<int> data) => [
          ...latin1.encode(id),
          (data.length >> 24) & 0xFF,
          (data.length >> 16) & 0xFF,
          (data.length >> 8) & 0xFF,
          data.length & 0xFF,
          0,
          0,
          ...data,
        ];
    final body = [
      ...frame('TIT2', [0, ...latin1.encode('Pocket Radio')]),
      ...frame('TPE1', [0, ...latin1.encode('Relay Kids')]),
    ];
    file.writeAsBytesSync([
      ...latin1.encode('ID3'), 3, 0, 0, 0, 0, 0, body.length, ...body,
    ]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AudioFileCard(path: file.path, fileName: 'track01.mp3'),
      ),
    ));
    expect(find.text('track01'), findsOneWidget,
        reason: 'the file name stands in until the tags are read');
    await _settleFiles(tester);
    expect(find.text('Pocket Radio'), findsOneWidget);
    expect(find.text('Relay Kids'), findsOneWidget);
  });

  test('"Artist - Title" file names become title and artist', () {
    expect(trackNameFromFile('Daft Punk - One More Time.mp3'),
        ('One More Time', 'Daft Punk'));
    expect(trackNameFromFile('voice_note_3.m4a'), ('voice note 3', null));
  });
}
