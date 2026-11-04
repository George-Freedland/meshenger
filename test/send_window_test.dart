import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/core/services/send_window.dart';

void main() {
  group('SendWindow', () {
    test('runs ahead by at most the window, then waits for confirmations',
        () {
      final w = SendWindow(total: 10, size: 3);
      for (var i = 0; i < 3; i++) {
        expect(w.blocked, isFalse);
        expect(w.next, i);
        w.sent();
      }
      expect(w.blocked, isTrue);
      w.report(2, nowMs: 0);
      expect(w.blocked, isFalse);
      expect(w.next, 3);
    });

    test('a missing chunk sends it back to the receiver\'s watermark', () {
      final w = SendWindow(total: 10, size: 8);
      for (var i = 0; i < 6; i++) {
        w.sent();
      }
      expect(w.report(2, missing: true, nowMs: 0), isTrue);
      expect(w.next, 2);
      expect(w.confirmed, 2);
    });

    test('a stale missing report changes nothing', () {
      final w = SendWindow(total: 10, size: 8);
      for (var i = 0; i < 6; i++) {
        w.sent();
      }
      w.report(4, nowMs: 0);
      expect(w.report(2, missing: true, nowMs: 10), isFalse);
      expect(w.next, 6);
      expect(w.confirmed, 4);
    });

    test('repeats for the same chunk are ignored briefly after going back',
        () {
      final w = SendWindow(total: 10, size: 8);
      for (var i = 0; i < 5; i++) {
        w.sent();
      }
      expect(w.report(1, missing: true, nowMs: 1000), isTrue);
      w.sent();
      w.sent();
      // Sent before our re-sent chunks reached the receiver.
      expect(w.report(1, missing: true, nowMs: 1500), isFalse);
      expect(w.next, 3);
      // The re-sent chunk got lost too.
      expect(w.report(1, missing: true, nowMs: 3000), isTrue);
      expect(w.next, 1);
    });

    test('a receiver ahead of us makes it skip forward', () {
      final w = SendWindow(total: 10, size: 4, confirmed: 2);
      expect(w.next, 2);
      w.report(6, nowMs: 0);
      expect(w.next, 6);
    });

    test('rewind re-sends whatever is outstanding', () {
      final w = SendWindow(total: 4, size: 8);
      expect(w.rewind(nowMs: 0), isFalse);
      for (var i = 0; i < 4; i++) {
        w.sent();
      }
      w.report(1, nowMs: 0);
      expect(w.blocked, isTrue, reason: 'everything sent, waiting');
      expect(w.rewind(nowMs: 0), isTrue);
      expect(w.next, 1);
      expect(w.outstanding, 0);
    });

    test('restartFrom forgets confirmations past the receiver\'s new start',
        () {
      final w = SendWindow(total: 10, size: 4, confirmed: 6);
      w.restartFrom(3);
      expect(w.confirmed, 3);
      expect(w.next, 3);
    });

    test('complete once the receiver has every chunk', () {
      final w = SendWindow(total: 2, size: 4);
      w.sent();
      w.sent();
      expect(w.complete, isFalse);
      w.report(2, nowMs: 0);
      expect(w.complete, isTrue);
    });

    test('finishes over a lossy link with an in-order receiver', () {
      const total = 120;
      final random = Random(7);
      final w = SendWindow(total: total, size: 16);
      final written = <int>[];
      var watermark = 0;
      var nowMs = 0;
      var lastProgressMs = 0;

      void deliver(int i) {
        if (i == watermark) {
          written.add(i);
          watermark++;
          if (random.nextDouble() < 0.9) w.report(watermark, nowMs: nowMs);
        } else if (random.nextDouble() < 0.9) {
          // Reports can be lost as well.
          w.report(watermark, missing: i > watermark, nowMs: nowMs);
        }
      }

      while (!w.complete && nowMs < 10000000) {
        nowMs += 100;
        if (w.confirmed > written.length) {
          fail('confirmed ${w.confirmed} past what was written');
        }
        if (w.blocked) {
          if (nowMs - lastProgressMs >= 15000 && w.rewind(nowMs: nowMs)) {
            lastProgressMs = nowMs;
          }
          if (w.next >= total && watermark >= total) {
            w.report(watermark, nowMs: nowMs);
          }
          continue;
        }
        final i = w.next;
        w.sent();
        final before = w.confirmed;
        if (random.nextDouble() >= 0.1) deliver(i);
        if (w.confirmed != before) lastProgressMs = nowMs;
      }

      expect(w.complete, isTrue);
      expect(written, List<int>.generate(total, (i) => i));
    });
  });
}
