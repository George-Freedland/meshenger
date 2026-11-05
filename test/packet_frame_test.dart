import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/core/transport/packet_frame.dart';

String _b64(int length, int seed) {
  final random = Random(seed);
  return base64Encode(List<int>.generate(length, (_) => random.nextInt(256)));
}

void main() {
  test('a file chunk travels as raw bytes and comes back identical', () {
    final packet = <String, Object?>{
      't': 'ftc',
      'tid': 'transfer-1',
      'to': 'bob',
      'i': 7,
      'data': _b64(24 * 1024, 1),
      'mac': _b64(16, 2),
    };
    final binary = PacketFrame.encodeBinary(packet);
    final json = PacketFrame.encodeJson(packet);

    expect(binary[0], PacketFrame.binaryMarker);
    expect(binary.length, lessThan(json.length * 0.8),
        reason: 'base64 is a third bigger than the bytes it carries');
    expect(PacketFrame.decode(binary), packet);
    expect(PacketFrame.decode(json), packet);
  });

  test('signed fields survive exactly, so signatures still verify', () {
    final envelope = <String, Object?>{
      't': 'msg',
      'from': 'alice',
      'nonce': _b64(12, 3),
      'cipher': _b64(3000, 4),
      'mac': _b64(16, 5),
      'sig': _b64(64, 6),
      'hops': 0,
      'via': <String>[],
    };
    final decoded = PacketFrame.decode(PacketFrame.encodeBinary(envelope))!;
    expect(decoded['cipher'], envelope['cipher']);
    expect(decoded['sig'], envelope['sig']);
    expect(decoded, envelope);
  });

  test('text and non-canonical base64 stay as they are', () {
    final urlSafe = base64Url.encode(List<int>.filled(600, 0xfb));
    final unpadded = base64Encode(List<int>.filled(601, 1)).replaceAll('=', '');
    final packet = <String, Object?>{
      't': 'post',
      'text': 'A long caption ' * 40,
      'url': urlSafe,
      'raw': unpadded,
    };
    final frame = PacketFrame.encodeBinary(packet);
    expect(frame[0], isNot(PacketFrame.binaryMarker),
        reason: 'nothing to move, so plain JSON');
    expect(PacketFrame.decode(frame), packet);
  });

  test('broken frames are refused', () {
    final frame = PacketFrame.encodeBinary(<String, Object?>{
      't': 'bdat',
      'data': _b64(2048, 7),
    });
    expect(
        PacketFrame.decode(Uint8List.sublistView(frame, 0, frame.length - 1)),
        isNull);
    expect(PacketFrame.decode(Uint8List.fromList([...frame, 0])), isNull);
    expect(PacketFrame.decode(Uint8List.fromList(utf8.encode('not json'))),
        isNull);
  });

  group('chunks', () {
    List<Uint8List> chunk(List<int> payload, int size,
        {bool flagFirst = true}) {
      return [
        for (var offset = 0; offset < payload.length; offset += size)
          () {
            final end = min(offset + size, payload.length);
            var flags = ChunkFlags.of(offset, end, payload.length);
            if (!flagFirst) flags &= ~ChunkFlags.first;
            return Uint8List.fromList([flags, ...payload.sublist(offset, end)]);
          }(),
      ];
    }

    test('a packet comes back whole from its chunks', () {
      final payload = List<int>.generate(1000, (i) => i % 256);
      final assembler = ChunkAssembler();
      final pieces = chunk(payload, 300);
      expect(pieces.first[0], ChunkFlags.first);
      expect(pieces.last[0], ChunkFlags.last);
      for (final piece in pieces.take(pieces.length - 1)) {
        expect(assembler.add('mac', piece), isNull);
      }
      expect(assembler.add('mac', pieces.last), payload);
      expect(chunk([1, 2], 300).single[0], ChunkFlags.first | ChunkFlags.last);
    });

    test('a packet that broke off mid-way does not spoil the next one', () {
      final dropped = <int>[];
      final assembler =
          ChunkAssembler(onDropped: (_, bytes) => dropped.add(bytes));
      final broken = chunk(List<int>.filled(900, 7), 300);
      assembler.add('pc', broken[0]);
      assembler.add('pc', broken[1]);

      final next = List<int>.generate(500, (i) => i % 251);
      final pieces = chunk(next, 300);
      expect(assembler.add('pc', pieces[0]), isNull);
      expect(assembler.add('pc', pieces[1]), next);
      expect(dropped, [600]);
    });

    test('senders are kept apart, and older senders still work', () {
      final assembler = ChunkAssembler();
      final a = chunk(List<int>.filled(400, 1), 300, flagFirst: false);
      final b = chunk(List<int>.filled(400, 2), 300, flagFirst: false);
      assembler.add('a', a[0]);
      assembler.add('b', b[0]);
      expect(assembler.add('a', a[1]), List<int>.filled(400, 1));
      expect(assembler.add('b', b[1]), List<int>.filled(400, 2));
    });
  });
}
