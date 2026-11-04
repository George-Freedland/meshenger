import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/core/services/transfer_meter.dart';

void main() {
  test('speed is the bytes of the last few seconds', () {
    var now = 0;
    final meter = TransferMeter(clock: () => now);
    expect(meter.bytesPerSecond, 0);
    expect(meter.timeLeft(1000), isNull);

    // 24 KB every half second for 10 s: 48 KB/s.
    for (var i = 0; i < 20; i++) {
      now += 500;
      meter.add(24 * 1024);
    }
    expect(meter.bytesPerSecond, closeTo(48 * 1024, 2 * 1024));
    expect(meter.timeLeft(48 * 1024 * 60)!.inSeconds, closeTo(60, 3));

    // Nothing for a whole window: stalled.
    now += 9000;
    expect(meter.bytesPerSecond, 0);
  });

  test('the first chunk does not read as a burst', () {
    var now = 0;
    final meter = TransferMeter(clock: () => now)..add(24 * 1024);
    now += 50;
    expect(meter.bytesPerSecond, lessThanOrEqualTo(24 * 1024));
  });

  test('speed and time left read naturally', () {
    expect(formatRate(3.4 * 1024), '3.4 KB/s');
    expect(formatRate(48 * 1024), '48 KB/s');
    expect(formatRate(1.5 * 1024 * 1024), '1.5 MB/s');
    expect(formatTimeLeft(const Duration(seconds: 2)), 'a few seconds left');
    expect(formatTimeLeft(const Duration(seconds: 45)), '45 s left');
    expect(formatTimeLeft(const Duration(seconds: 200)), '3 min 20 s left');
    expect(formatTimeLeft(const Duration(minutes: 25)), '25 min left');
    expect(formatTimeLeft(const Duration(minutes: 65)), '1 h 5 min left');
  });
}
