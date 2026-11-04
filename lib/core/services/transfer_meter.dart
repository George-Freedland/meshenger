import 'dart:collection';
import 'dart:math';

/// How fast a transfer is moving: the bytes of the last few seconds.
class TransferMeter {
  TransferMeter({
    this.window = const Duration(seconds: 8),
    int Function()? clock,
  }) : _clock = clock ?? _now;

  final Duration window;
  final int Function() _clock;
  final ListQueue<(int, int)> _samples = ListQueue<(int, int)>();
  int _windowBytes = 0;
  int? _startedMs;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  void add(int bytes) {
    if (bytes <= 0) return;
    final now = _clock();
    _startedMs ??= now;
    _samples.add((now, bytes));
    _windowBytes += bytes;
    _trim(now);
  }

  /// A sample stands for the bytes that arrived up to its time, so one a
  /// whole window old covers time before the window.
  void _trim(int now) {
    while (_samples.isNotEmpty &&
        now - _samples.first.$1 >= window.inMilliseconds) {
      _windowBytes -= _samples.removeFirst().$2;
    }
  }

  /// Zero once nothing has moved for a whole window.
  double get bytesPerSecond {
    final now = _clock();
    _trim(now);
    final started = _startedMs;
    if (_samples.isEmpty || started == null) return 0;
    // A young transfer divides by its age (at least a second, so the first
    // chunk doesn't read as a burst of megabytes per second).
    final spanMs =
        min(window.inMilliseconds, max(1000, now - started)).toDouble();
    return _windowBytes * 1000 / spanMs;
  }

  /// Null while there's no speed to go on.
  Duration? timeLeft(int remainingBytes) {
    final rate = bytesPerSecond;
    if (rate <= 0) return null;
    return Duration(
        milliseconds: (max(0, remainingBytes) / rate * 1000).round());
  }
}

/// "38 KB/s", "1.2 MB/s".
String formatRate(double bytesPerSecond) {
  const kb = 1024.0;
  if (bytesPerSecond >= kb * kb) {
    return '${(bytesPerSecond / (kb * kb)).toStringAsFixed(1)} MB/s';
  }
  if (bytesPerSecond >= 10 * kb) return '${(bytesPerSecond / kb).round()} KB/s';
  return '${(bytesPerSecond / kb).toStringAsFixed(1)} KB/s';
}

/// "45 s left", "3 min 20 s left", "1 h 5 min left".
String formatTimeLeft(Duration left) {
  final seconds = left.inSeconds;
  if (seconds < 5) return 'a few seconds left';
  if (seconds < 60) return '$seconds s left';
  if (seconds < 3600) {
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return minutes >= 10 || rest == 0
        ? '$minutes min left'
        : '$minutes min $rest s left';
  }
  return '${seconds ~/ 3600} h ${(seconds % 3600) ~/ 60} min left';
}

/// "in 42 s at 48 KB/s", for the connection log when a transfer finishes.
String formatAverage(int bytes, int elapsedMs) {
  final seconds = max(1, elapsedMs) / 1000;
  return 'in ${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)} s at '
      '${formatRate(bytes / seconds)}';
}

/// "48 KB/s · 1 min 15 s left", or null before there's a speed to show.
String? speedLine(TransferMeter? meter, int remainingBytes) {
  if (meter == null) return null;
  final rate = meter.bytesPerSecond;
  if (rate <= 0) return null;
  final left = meter.timeLeft(remainingBytes);
  return [formatRate(rate), if (left != null) formatTimeLeft(left)].join(' · ');
}
