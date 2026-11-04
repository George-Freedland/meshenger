import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Only one song or video plays at a time: whatever starts sets itself
/// here, and the others pause when it changes.
final ValueNotifier<Object?> nowPlaying = ValueNotifier<Object?>(null);

/// A file that may still be arriving. Its first [availableBytes] are on
/// disk and checked, so a player can start on them and wait for the rest.
@immutable
class GrowingFile {
  const GrowingFile({
    required this.path,
    required this.totalBytes,
    required this.availableBytes,
    this.bytesPerSecond = 0,
    this.duration,
  });

  final String path;
  final int totalBytes;
  final int availableBytes;
  final double bytesPerSecond;
  final Duration? duration;

  bool get complete => availableBytes >= totalBytes;
  double get fraction =>
      totalBytes == 0 ? 1 : (availableBytes / totalBytes).clamp(0.0, 1.0);
}

/// What to hand mpv for [path]. While the file is still growing,
/// `appending://` makes mpv wait for new bytes at the end instead of
/// stopping there (it gives up after about two seconds without any).
String playerUriFor(String path, {required bool growing}) =>
    growing ? 'appending://${path.replaceAll(r'\', '/')}' : path;

/// How long to wait before playing [file] from [from] so playback never
/// catches up with the download: zero to start now, null while there's no
/// speed or playing time to go on yet.
///
/// Played at its average bitrate S/D from position p, the bytes needed t
/// seconds in are S·(p + t)/D; downloaded by then are H + R·t. Both grow
/// linearly, so the gap is widest at the end: start once
/// H ≥ S − R·(D − p), with a margin for a speed that wobbles, and once a
/// few seconds past p have arrived.
Duration? waitBeforePlaying(
  GrowingFile file, {
  Duration from = Duration.zero,
  int minimumBytes = 64 * 1024,
}) {
  if (file.complete) return Duration.zero;
  final rate = file.bytesPerSecond;
  final duration = file.duration;
  if (rate <= 0 || duration == null || duration.inMilliseconds <= 0) {
    return null;
  }
  final total = file.totalBytes.toDouble();
  final seconds = duration.inMilliseconds / 1000;
  final position = (from.inMilliseconds / 1000).clamp(0.0, seconds);
  final bytesPerPlayedSecond = total / seconds;
  final headroom = max(minimumBytes.toDouble(), bytesPerPlayedSecond * 5);
  final needed = min(
    total,
    max(
      bytesPerPlayedSecond * position + headroom,
      total - rate * (seconds - position) * 0.8,
    ),
  );
  final missing = needed - file.availableBytes;
  if (missing <= 0) return Duration.zero;
  return Duration(milliseconds: (missing / rate * 1000).ceil());
}

/// MP4, MOV and M4A files need their index (the `moov` box) before a
/// single frame plays. Recorders often write it last, which a download
/// reaches last: false for those, true when it comes first, null when the
/// [head] doesn't tell (any other format plays from its first bytes).
bool? playsFromStart(Uint8List head) {
  if (head.length < 8 || String.fromCharCodes(head, 4, 8) != 'ftyp') {
    return null;
  }
  var pos = 0;
  while (pos + 8 <= head.length) {
    final data = ByteData.sublistView(head, pos);
    var size = data.getUint32(0);
    final type = String.fromCharCodes(head, pos + 4, pos + 8);
    if (type == 'moov') return true;
    if (type == 'mdat') return false;
    if (size == 1) {
      if (pos + 16 > head.length) return null;
      size = data.getUint64(8);
    }
    if (size < 8) return null;
    pos += size;
  }
  return null;
}

/// [playsFromStart] for the start of the file at [path].
Future<bool?> fileSupportsStreaming(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    return playsFromStart(await raf.read(64 * 1024));
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}
