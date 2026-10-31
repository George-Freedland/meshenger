import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/media/post_file.dart';
import 'package:meshenger/core/models/post_attachment.dart';
import 'package:meshenger/core/services/blob_service.dart';
import 'package:meshenger/core/services/identity_scope.dart';
import 'package:meshenger/core/services/identity_service.dart';
import 'package:meshenger/core/services/media_store.dart';
import 'package:meshenger/core/services/messenger_service.dart';
import 'package:meshenger/core/services/network_service.dart';
import 'package:meshenger/core/transport/envelope_codec.dart';

class _Folders extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Folders(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2]);

/// A small tagged MP3 (tags + cover + a few frames).
List<int> _song() {
  List<int> frame(String id, List<int> data) => [
        ...latin1.encode(id),
        (data.length >> 24) & 0xFF, (data.length >> 16) & 0xFF,
        (data.length >> 8) & 0xFF, data.length & 0xFF, 0, 0, ...data,
      ];
  final body = [
    ...frame('TIT2', [0, ...latin1.encode('Mesh Love')]),
    ...frame('TPE1', [0, ...latin1.encode('The Nodes')]),
    ...frame('APIC', [0, ...latin1.encode('image/png'), 0, 3, 0, ..._png]),
  ];
  return [
    ...latin1.encode('ID3'), 3, 0, 0, 0, 0, 0, body.length, ...body,
    for (var i = 0; i < 4; i++) ...[0xFF, 0xFB, 0x90, 0x00, ...List.filled(413, 0)],
  ];
}

void main() {
  late Directory root;
  late SimpleKeyPair me;
  late SimpleKeyPair alice;
  late String myAddress;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('flow');
    PathProviderPlatform.instance = _Folders(root.path);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    me = await Ed25519().newKeyPair();
    alice = await Ed25519().newKeyPair();
    myAddress = base64Encode((await me.extractPublicKey()).bytes);
    await IdentityService.instance.debugUnlockWithKeyPair(me, nickname: 'Me');
    IdentityScope.setActive(myAddress);
    BlobService.instance.directoryForTesting = Directory('${root.path}/blobs');
  });

  tearDown(() async {
    await BlobService.instance.detach();
    root.deleteSync(recursive: true);
  });

  test('a song post that arrives brings its cover and (small) file along',
      () async {
    final bytes = Uint8List.fromList(_song());
    final sha = await BlobService.sha256OfBytes(bytes);
    await IdentityService.instance.debugUnlockWithKeyPair(alice, nickname: 'Alice');
    final now = DateTime.now().millisecondsSinceEpoch;
    final packet = await EnvelopeCodec.buildNetworkPost(
      id: 'song-1',
      text: 'listen',
      tsMs: now,
      expMs: now + 3600000,
      nickname: 'Alice',
      attachment: PostAttachment(
        name: 'mesh_love.mp3',
        mime: 'audio/mpeg',
        size: bytes.length,
        sha256: sha,
        title: 'Mesh Love',
        artist: 'The Nodes',
      ),
      artB64: base64Encode(_png),
      mediaB64: base64Encode(bytes),
    );
    await IdentityService.instance.debugUnlockWithKeyPair(me, nickname: 'Me');

    await MessengerService.instance
        .debugHandlePacket(jsonDecode(jsonEncode(packet)) as Map<String, Object?>);

    final post = await NetworkService.instance.byId('song-1');
    expect(post, isNotNull);
    expect(post!.kind, 'file');
    expect(post.attachment!.title, 'Mesh Love');
    expect(await MediaStore.instance.readBytes(post.artMediaId!), _png);
    final file = await BlobService.instance.pathFor(sha);
    expect(file, isNotNull, reason: 'small files arrive with the post');
    expect(File(file!).readAsBytesSync(), bytes);
  });

  test('posting my song keeps a copy to share and reads its tags', () async {
    final original = File('${root.path}/Mesh Love.mp3')..writeAsBytesSync(_song());
    final prepared = await preparePostFile(
        path: original.path, name: 'Mesh Love.mp3', mime: 'audio/mpeg');
    expect(prepared.attachment.title, 'Mesh Love');
    expect(prepared.attachment.artist, 'The Nodes');
    expect(prepared.cover, _png);
    expect(prepared.inlineBytes, isNotNull, reason: 'under 512 KB');

    await MessengerService.instance.postToNetwork('my song', file: prepared);
    original.deleteSync(); // the shared copy must not depend on it

    final mine = (await NetworkService.instance.listActive()).single;
    expect(mine.kind, 'file');
    expect(mine.attachment!.sha256, prepared.attachment.sha256);
    expect(mine.artMediaId, isNotNull);
    expect(await BlobService.instance.pathFor(prepared.attachment.sha256),
        isNotNull);

    // Deleting the post lets the file go too.
    await MessengerService.instance.deleteNetworkPost(mine.id);
    expect(await BlobService.instance.pathFor(prepared.attachment.sha256),
        isNull);
  });
}
