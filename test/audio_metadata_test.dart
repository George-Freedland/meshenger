import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/core/media/audio_metadata.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xFF, 0xD9]);
final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9]);

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> _u32le(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
List<int> _syncsafe(int v) =>
    [(v >> 21) & 0x7F, (v >> 14) & 0x7F, (v >> 7) & 0x7F, v & 0x7F];

/// An ID3v2 tag of [major] version 3 or 4 holding [frames].
List<int> _id3(int major, List<List<int>> frames) {
  final body = frames.expand((f) => f).toList();
  return [...latin1.encode('ID3'), major, 0, 0, ..._syncsafe(body.length), ...body];
}

List<int> _frame(int major, String id, List<int> data) => [
      ...latin1.encode(id),
      ...(major == 4 ? _syncsafe(data.length) : _u32(data.length)),
      0,
      0,
      ...data,
    ];

List<int> _latin1Text(String s) => [0, ...latin1.encode(s)];
List<int> _utf8Text(String s) => [3, ...utf8.encode(s)];
List<int> _utf16Text(String s) {
  final out = <int>[1, 0xFF, 0xFE];
  for (final unit in s.codeUnits) {
    out.addAll([unit & 0xFF, unit >> 8]);
  }
  return out;
}

List<int> _apic(String mime, int type, List<int> image) =>
    [0, ...latin1.encode(mime), 0, type, ...latin1.encode('cover'), 0, ...image];

/// MPEG-1 Layer III, 128 kbps, 44.1 kHz, stereo: 417-byte frames.
List<int> _mp3Frame({int? xingFrames}) {
  final frame = List<int>.filled(417, 0);
  frame.setAll(0, [0xFF, 0xFB, 0x90, 0x00]);
  if (xingFrames != null) {
    frame.setAll(36, [...latin1.encode('Xing'), ..._u32(1), ..._u32(xingFrames)]);
  }
  return frame;
}

List<int> _box(String type, List<int> payload) =>
    [..._u32(8 + payload.length), ...latin1.encode(type), ...payload];

List<int> _flacBlock(int type, List<int> data, {bool last = false}) =>
    [(last ? 0x80 : 0) | type, (data.length >> 16) & 0xFF, (data.length >> 8) & 0xFF, data.length & 0xFF, ...data];

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('meta_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<AudioMetadata> read(String name, List<int> bytes) async {
    final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return readAudioMetadata(file.path);
  }

  test('ID3v2.3 tags, front cover and exact VBR length', () async {
    final meta = await read('song.mp3', [
      ..._id3(3, [
        _frame(3, 'TIT2', _latin1Text('Mesh Love')),
        _frame(3, 'TPE1', _utf16Text('Zoë & The Nodes')),
        _frame(3, 'TALB', _latin1Text('Offline')),
        _frame(3, 'APIC', _apic('image/png', 0, _png)),
        _frame(3, 'APIC', _apic('image/jpeg', 3, _jpeg)),
      ]),
      ..._mp3Frame(xingFrames: 1000),
      ..._mp3Frame(),
    ]);
    expect(meta.title, 'Mesh Love');
    expect(meta.artist, 'Zoë & The Nodes');
    expect(meta.album, 'Offline');
    expect(meta.art, _jpeg, reason: 'the front cover wins');
    expect(meta.artMime, 'image/jpeg');
    expect(meta.duration!.inMilliseconds, 26122); // 1000 × 1152 / 44100 s
  });

  test('ID3v2.4 UTF-8 text with syncsafe frame sizes', () async {
    final meta = await read('song.mp3', [
      ..._id3(4, [
        _frame(4, 'TIT2', _utf8Text('Bluetooth Blues 🎶')),
        _frame(4, 'TPE1', _utf8Text('Ann\u0000Bo')),
        _frame(4, 'APIC', _apic('image/png', 3, _png)),
      ]),
      ..._mp3Frame(),
      ..._mp3Frame(),
    ]);
    expect(meta.title, 'Bluetooth Blues 🎶');
    expect(meta.artist, 'Ann', reason: 'first of several values');
    expect(meta.artMime, 'image/png');
  });

  test('ID3v2.2 three-letter frames', () async {
    final tt2 = _latin1Text('Old Tag');
    final pic = [0, ...latin1.encode('JPG'), 3, 0, ..._jpeg];
    List<int> frame22(String id, List<int> data) => [
          ...latin1.encode(id),
          (data.length >> 16) & 0xFF,
          (data.length >> 8) & 0xFF,
          data.length & 0xFF,
          ...data,
        ];
    final body = [...frame22('TT2', tt2), ...frame22('PIC', pic)];
    final meta = await read('old.mp3', [
      ...latin1.encode('ID3'), 2, 0, 0, ..._syncsafe(body.length), ...body,
    ]);
    expect(meta.title, 'Old Tag');
    expect(meta.art, _jpeg);
  });

  test('ID3v1 only, length estimated from the bitrate', () async {
    final frames = [for (var i = 0; i < 20; i++) ..._mp3Frame()];
    List<int> field(String s) => [...latin1.encode(s), ...List.filled(30 - s.length, 0)];
    final meta = await read('cbr.mp3', [
      ...frames,
      ...latin1.encode('TAG'),
      ...field('Plain'),
      ...field('Someone'),
      ...field('Album One'),
      ...List.filled(35, 0),
    ]);
    expect(meta.title, 'Plain');
    expect(meta.artist, 'Someone');
    expect(meta.album, 'Album One');
    // 20 × 417 bytes at 128 kbps.
    expect(meta.duration!.inMilliseconds, 20 * 417 * 8 ~/ 128);
  });

  test('M4A iTunes tags, cover and length', () async {
    List<int> item(String type, int kind, List<int> value) =>
        _box(type, _box('data', [..._u32(kind), ..._u32(0), ...value]));
    final mvhd = _box('mvhd', [
      0, 0, 0, 0, ..._u32(0), ..._u32(0), ..._u32(1000), ..._u32(185500),
      ...List.filled(80, 0),
    ]);
    final ilst = _box('ilst', [
      ...item('\u00a9nam', 1, utf8.encode('Pocket Mesh')),
      ...item('\u00a9ART', 1, utf8.encode('The Relays')),
      ...item('\u00a9alb', 1, utf8.encode('Range')),
      ...item('covr', 13, _jpeg),
    ]);
    final meta = await read('song.m4a', [
      ..._box('ftyp', latin1.encode('M4A \u0000\u0000\u0000\u0000M4A mp42')),
      ..._box('mdat', List.filled(64, 7)),
      ..._box('moov', [
        ...mvhd,
        ..._box('udta', _box('meta', [
          ..._u32(0),
          ..._box('hdlr', List.filled(25, 0)),
          ...ilst,
        ])),
      ]),
    ]);
    expect(meta.title, 'Pocket Mesh');
    expect(meta.artist, 'The Relays');
    expect(meta.album, 'Range');
    expect(meta.art, _jpeg);
    expect(meta.duration, const Duration(milliseconds: 185500));
  });

  test('FLAC vorbis comments, picture and length', () async {
    const rate = 44100;
    const samples = rate * 60;
    final info = <int>[
      0, 16, 0, 16, 0, 0, 0, 0, 0, 0,
      rate >> 12, (rate >> 4) & 0xFF, ((rate & 0xF) << 4) | (1 << 1), 0xF0,
      ..._u32(samples),
      ...List.filled(16, 0),
    ];
    List<int> comment(String s) => [..._u32le(utf8.encode(s).length), ...utf8.encode(s)];
    final comments = [
      ..._u32le(6), ...utf8.encode('vendor'),
      ..._u32le(3),
      ...comment('TITLE=Lossless'),
      ...comment('artist=Quiet Room'),
      ...comment('ALBUM=Samples'),
    ];
    final picture = [
      ..._u32(3), ..._u32(10), ...latin1.encode('image/jpeg'),
      ..._u32(0), ...List.filled(16, 0),
      ..._u32(_jpeg.length), ..._jpeg,
    ];
    final meta = await read('song.flac', [
      ...latin1.encode('fLaC'),
      ..._flacBlock(0, info),
      ..._flacBlock(4, comments),
      ..._flacBlock(6, picture, last: true),
    ]);
    expect(meta.title, 'Lossless');
    expect(meta.artist, 'Quiet Room');
    expect(meta.album, 'Samples');
    expect(meta.art, _jpeg);
    expect(meta.duration, const Duration(seconds: 60));
  });

  test('anything else gives empty metadata instead of throwing', () async {
    final meta = await read('noise.bin', List.generate(5000, (i) => (i * 37) % 256));
    expect(meta.title, isNull);
    expect(meta.art, isNull);
    final missing = await readAudioMetadata('${dir.path}/missing.mp3');
    expect(missing.title, isNull);
  });
}
