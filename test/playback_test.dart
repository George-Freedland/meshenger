import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/core/media/playback.dart';

Uint8List _box(String type, int size) {
  final box = Uint8List(size);
  ByteData.sublistView(box).setUint32(0, size);
  box.setRange(4, 8, type.codeUnits);
  return box;
}

void main() {
  group('when a growing file can start', () {
    // A 4 MB, 4-minute song: 17 KB/s to keep up.
    const size = 4 * 1024 * 1024;
    const length = Duration(minutes: 4);

    GrowingFile file({required int have, required double rate}) => GrowingFile(
          path: '/tmp/song.part',
          totalBytes: size,
          availableBytes: have,
          bytesPerSecond: rate,
          duration: length,
        );

    test('right away when the download is faster than the song', () {
      expect(waitBeforePlaying(file(have: 128 * 1024, rate: 48 * 1024)),
          Duration.zero);
    });

    test('after a head start when it is slower', () {
      final wait = waitBeforePlaying(file(have: 0, rate: 10 * 1024))!;
      // Needs 4 MB − 0.85 × 10 KB/s × 240 s ≈ 2 MB first: about 205 s.
      expect(wait.inSeconds, inInclusiveRange(195, 215));
    });

    test('not before there is a speed to go on', () {
      expect(waitBeforePlaying(file(have: 0, rate: 0)), isNull);
      expect(
          waitBeforePlaying(const GrowingFile(
              path: '/tmp/x',
              totalBytes: size,
              availableBytes: 0,
              bytesPerSecond: 50000)),
          isNull,
          reason: 'no playing time known');
    });

    test('at once when it is all here', () {
      expect(
          waitBeforePlaying(const GrowingFile(
              path: '/x', totalBytes: 10, availableBytes: 10)),
          Duration.zero);
    });
  });

  group('MP4 layout', () {
    test('index first plays from the start; index last does not', () {
      final faststart = Uint8List.fromList(
          [..._box('ftyp', 24), ..._box('moov', 200), ..._box('mdat', 64)]);
      final recorded = Uint8List.fromList(
          [..._box('ftyp', 24), ..._box('free', 8), ..._box('mdat', 64)]);
      expect(playsFromStart(faststart), isTrue);
      expect(playsFromStart(recorded), isFalse);
    });

    test('other formats are not judged', () {
      expect(
          playsFromStart(Uint8List.fromList('ID3\x04\x00'.codeUnits)), isNull);
    });
  });

  test('growing files play through mpv\'s appending protocol', () {
    expect(playerUriFor('/data/a.part', growing: true),
        'appending:///data/a.part');
    expect(playerUriFor(r'C:\Users\a.part', growing: true),
        'appending://C:/Users/a.part');
    expect(playerUriFor('/data/a.mp3', growing: false), '/data/a.mp3');
  });
}
