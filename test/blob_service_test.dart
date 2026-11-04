import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/core/services/blob_service.dart';

/// Devices on an in-memory link: every packet is delivered asynchronously
/// to the named device's [BlobService.handlePacket].
class _Mesh {
  final Map<String, BlobService> devices = <String, BlobService>{};
  final Map<String, Duration> delayFrom = <String, Duration>{};
  final Map<String, int> dataFrom = <String, int>{};
  int dataPackets = 0;

  BlobService join(String name, Directory dir, Set<String> neighbors) {
    final service = BlobService()..directoryForTesting = dir;
    service.attach(
      send: (peer, packet, {bool bulk = false}) async {
        final target = devices[peer];
        if (target == null) return false;
        if (packet['t'] == 'bdat') {
          dataPackets++;
          dataFrom[name] = (dataFrom[name] ?? 0) + 1;
        }
        final delay = delayFrom[name] ?? Duration.zero;
        unawaited(Future<void>.delayed(delay, () => target.handlePacket(packet)));
        return true;
      },
      onlinePeers: () => neighbors,
      myAddress: () async => name,
    );
    devices[name] = service;
    return service;
  }
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory root;
  late File song;
  late String sha;
  final mesh = <_Mesh>[];

  setUp(() async {
    root = Directory.systemTemp.createTempSync('blob_test');
    // 4 full chunks and a short one.
    final bytes = Uint8List.fromList(
        List.generate(BlobService.chunkSize * 4 + 4000, (i) => (i * 31) % 251));
    song = File('${root.path}/song.mp3')..writeAsBytesSync(bytes);
    sha = await BlobService.sha256OfFile(song.path);
  });

  tearDown(() async {
    for (final m in mesh) {
      for (final device in m.devices.values) {
        await device.detach();
      }
    }
    mesh.clear();
    root.deleteSync(recursive: true);
  });

  Directory dirFor(String name) =>
      Directory('${root.path}/$name')..createSync();

  test('a nearby device that has the file serves it, verified', () async {
    final m = _Mesh();
    mesh.add(m);
    final alice = m.join('alice', dirFor('alice'), {'bob'});
    final bob = m.join('bob', dirFor('bob'), {'alice'});
    await alice.addLocalFile(song.path, sha: sha, name: 'song.mp3');

    expect(bob.progressOf(sha).state, BlobState.missing);
    await bob.fetch(sha: sha, size: song.lengthSync(), name: 'song.mp3');
    String? got;
    await _until(() {
      unawaited(bob.pathFor(sha).then((p) => got = p));
      return got != null;
    });

    expect(File(got!).readAsBytesSync(), song.readAsBytesSync());
    expect(got, endsWith('.mp3'), reason: 'players need the extension');
    expect(bob.progressOf(sha).state, BlobState.done);
    expect(m.dataPackets, BlobService.chunkCountFor(song.lengthSync()));
  });

  test('bytes that fail the hash are thrown away and someone else is used',
      () async {
    final m = _Mesh();
    mesh.add(m);
    final liarFile = File('${root.path}/fake.mp3')
      ..writeAsBytesSync(List.filled(song.lengthSync(), 7));
    final liar = m.join('liar', dirFor('liar'), {'bob'});
    final honest = m.join('honest', dirFor('honest'), {'bob'});
    final bob = m.join('bob', dirFor('bob'), {'liar', 'honest'});
    await liar.addLocalFile(liarFile.path, sha: sha, name: 'song.mp3');
    await honest.addLocalFile(song.path, sha: sha, name: 'song.mp3');
    m.delayFrom['honest'] = const Duration(milliseconds: 60);

    await bob.fetch(sha: sha, size: song.lengthSync(), name: 'song.mp3');
    String? got;
    await _until(() {
      unawaited(bob.pathFor(sha).then((p) => got = p));
      return got != null;
    });
    expect(File(got!).readAsBytesSync(), song.readAsBytesSync());
  });

  test('a stopped download picks up where it left off', () async {
    final m = _Mesh();
    mesh.add(m);
    final alice = m.join('alice', dirFor('alice'), {'bob'});
    final bobDir = dirFor('bob');
    final bob = m.join('bob', bobDir, {'alice'});
    await alice.addLocalFile(song.path, sha: sha, name: 'song.mp3');

    // Two chunks already on disk from an earlier attempt.
    final whole = song.readAsBytesSync();
    File('${bobDir.path}/$sha.part')
        .writeAsBytesSync(whole.sublist(0, BlobService.chunkSize * 2 + 100));

    await bob.fetch(sha: sha, size: whole.length, name: 'song.mp3');
    String? got;
    await _until(() {
      unawaited(bob.pathFor(sha).then((p) => got = p));
      return got != null;
    });
    expect(File(got!).readAsBytesSync(), whole);
    expect(m.dataPackets, BlobService.chunkCountFor(whole.length) - 2,
        reason: 'only the missing chunks travel');
  });

  test('files no post points to are cleaned up', () async {
    final dir = dirFor('solo');
    final solo = BlobService()..directoryForTesting = dir;
    await solo.addLocalFile(song.path, sha: sha, name: 'song.mp3');
    expect(await solo.pathFor(sha), isNotNull);

    await solo.retain({sha});
    expect(await solo.pathFor(sha), isNotNull);
    await solo.retain(<String>{});
    expect(await solo.pathFor(sha), isNull);
    expect(dir.listSync(), isEmpty);
  });

  test('one pass gives the file hash and a hash per chunk', () async {
    final (fileSha, pieces) = await BlobService.hashFile(song.path);
    expect(fileSha, sha);
    expect(pieces.length, 32 * BlobService.chunkCountFor(song.lengthSync()));
  });

  test('with a piece list, a bad source is caught at its first chunk',
      () async {
    final m = _Mesh();
    mesh.add(m);
    // 40 chunks: without per-chunk checks the liar would serve all of it
    // before the whole-file hash caught it.
    final bytes = Uint8List.fromList(List.generate(
        BlobService.chunkSize * 40, (i) => (i * 7 + 3) % 253));
    final big = File('${root.path}/big.mp3')..writeAsBytesSync(bytes);
    final bigSha = await BlobService.sha256OfFile(big.path);
    final fake = File('${root.path}/fake-big.mp3')
      ..writeAsBytesSync(List.filled(bytes.length, 9));
    final (_, list) = await BlobService.hashFile(big.path);

    final liar = m.join('liar', dirFor('liar'), {'bob'});
    final honest = m.join('honest', dirFor('honest'), {'bob'});
    final bob = m.join('bob', dirFor('bob'), {'liar', 'honest'});
    await liar.addLocalFile(fake.path, sha: bigSha, name: 'big.mp3');
    await honest.addLocalFile(big.path, sha: bigSha, name: 'big.mp3');
    final pieces = await honest.addPieceList(list);
    m.delayFrom['honest'] = const Duration(milliseconds: 40);

    await bob.fetch(
        sha: bigSha, size: bytes.length, name: 'big.mp3', pieces: pieces);
    String? got;
    await _until(() {
      unawaited(bob.pathFor(bigSha).then((p) => got = p));
      return got != null;
    });
    expect(File(got!).readAsBytesSync(), bytes);
    expect(m.dataFrom['liar'] ?? 0, lessThanOrEqualTo(BlobService.window),
        reason: 'dropped after one window at most, not after 40 chunks');
    expect(await bob.pathFor(pieces), isNotNull,
        reason: 'bob keeps the list, so he can serve it too');
  });

  test('bytes inside a post are kept only when they match the hash',
      () async {
    final solo = BlobService()..directoryForTesting = dirFor('inline');
    final bytes = song.readAsBytesSync();
    expect(
        await solo.addBytes(Uint8List.fromList(List.filled(10, 1)),
            sha: sha, name: 'song.mp3'),
        isNull);
    expect(await solo.addBytes(bytes, sha: sha, name: 'song.mp3'), isNotNull);
  });
}
