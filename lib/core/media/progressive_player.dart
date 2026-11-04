import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'playback.dart';

/// A media_kit player that can start on a file that is still downloading:
/// it waits until the rest will arrive before it's needed, and when
/// playback does catch up with the download it picks up again where it
/// stopped once more has arrived.
///
/// Feed it what's on the device with [update] on every rebuild. The player
/// itself is created on the first play, so a feed of songs or videos costs
/// nothing until one is tapped.
class ProgressivePlayer extends ChangeNotifier {
  ProgressivePlayer({this.withVideo = false}) {
    nowPlaying.addListener(_onNowPlaying);
  }

  final bool withVideo;

  Player? _player;
  VideoController? _video;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _disposed = false;

  String? _path;
  GrowingFile? _partial;
  Duration? _knownLength;

  bool playing = false;

  /// Something is loaded into the player.
  bool opened = false;
  bool _openedPartial = false;

  Duration position = Duration.zero;
  Duration? _playerLength;
  int? width;
  int? height;

  /// "Starts in 0:12", "Buffering…".
  String? waitLabel;

  /// Set when the file turned out not to be playable here.
  String? failed;

  bool _playWhenReady = false;

  /// Where playback caught up with the download; it goes on from here once
  /// the rest will arrive in time.
  Duration? _resumeAt;

  VideoController? get video => _video;
  Duration? get length => _knownLength ?? _playerLength;

  /// Played from the partial file, which is still arriving.
  bool get onPartial => _openedPartial && _path == null;

  /// What's on this device: the complete [path], or the [partial] download
  /// when it can play early. [length] is the playing time when known
  /// ahead (tags), since a partial file's own is only what has arrived.
  void update({String? path, GrowingFile? partial, Duration? length}) {
    if (_path == null && path != null && _openedPartial && !playing) {
      opened = false; // finished while paused: play the whole file next
    }
    _path = path;
    _partial = partial;
    if (length != null) _knownLength = length;
    // Called while the widget rebuilds; start (and notify) right after.
    if (_playWhenReady || _resumeAt != null) {
      scheduleMicrotask(() {
        if (!_disposed) _tryStart();
      });
    }
  }

  /// How far in playback can seek: all of it, or what has arrived.
  double get seekLimit {
    final partial = _partial;
    if (!onPartial || partial == null) return 1;
    return max(0, partial.fraction - 0.02);
  }

  Future<void> toggle({VoidCallback? fetch}) async {
    if (playing) {
      await _player?.pause();
      return;
    }
    if (opened) {
      nowPlaying.value = this;
      await _player?.play();
      return;
    }
    if (_path == null && _partial == null) fetch?.call();
    _playWhenReady = true;
    failed = null;
    _tryStart();
    _notify();
  }

  Future<void> seekFraction(double fraction) async {
    final total = length;
    if (total == null) return;
    final target = min(fraction, seekLimit);
    await _player
        ?.seek(Duration(milliseconds: (target * total.inMilliseconds).round()));
  }

  void _tryStart() {
    final path = _path;
    if (path != null) {
      unawaited(_open(path, growing: false));
      return;
    }
    final partial = _partial;
    if (partial == null) return; // still looking for the file
    final wait = waitBeforePlaying(
      partial,
      from: _resumeAt ?? Duration.zero,
      minimumBytes: withVideo ? 512 * 1024 : 64 * 1024,
    );
    final resuming = _resumeAt != null;
    final label = wait == null
        ? (resuming ? 'Buffering…' : 'Starting…')
        : wait > Duration.zero
            ? (resuming
                ? 'Buffering… ${_clock(wait)}'
                : 'Starts in ${_clock(wait)}')
            : null;
    if (label != null) {
      if (label != waitLabel) {
        waitLabel = label;
        _notify();
      }
      return;
    }
    unawaited(_open(partial.path, growing: !partial.complete));
  }

  Future<void> _open(String path, {required bool growing}) async {
    final at = _resumeAt;
    _playWhenReady = false;
    _resumeAt = null;
    waitLabel = null;
    failed = null;
    opened = true;
    _openedPartial = growing;
    _notify();
    nowPlaying.value = this;
    try {
      await _ensurePlayer()
          .open(Media(playerUriFor(path, growing: growing), start: at));
    } catch (_) {
      opened = false;
      failed = "This device can't play that file";
      _notify();
    }
  }

  Player _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = Player();
    if (withVideo) _video = VideoController(player);
    _subs
      ..add(player.stream.playing.listen((value) {
        playing = value;
        _notify();
      }))
      ..add(player.stream.position.listen((value) {
        position = value;
        _notify();
      }))
      ..add(player.stream.duration.listen((value) {
        if (value > Duration.zero) {
          _playerLength = value;
          _notify();
        }
      }))
      ..add(player.stream.width.listen((value) {
        width = value;
        _notify();
      }))
      ..add(player.stream.height.listen((value) {
        height = value;
        _notify();
      }))
      ..add(player.stream.completed.listen((done) {
        if (done) _onEnded();
      }))
      ..add(player.stream.error.listen((_) => _onEnded(error: true)));
    return _player = player;
  }

  void _onEnded({bool error = false}) {
    final partial = _partial;
    if (onPartial && partial != null && !partial.complete) {
      // Ran out of downloaded bytes: carry on once the rest will arrive in
      // time from here.
      _resumeAt ??= position;
      waitLabel = 'Buffering…';
      opened = false;
      _notify();
      return;
    }
    if (error && !opened) return; // already handled
    if (error) failed = "This device can't play that file";
    position = Duration.zero;
    opened = false;
    _notify();
  }

  void _onNowPlaying() {
    if (nowPlaying.value != this && playing) unawaited(_player?.pause());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static String _clock(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _disposed = true;
    nowPlaying.removeListener(_onNowPlaying);
    if (nowPlaying.value == this) nowPlaying.value = null;
    for (final sub in _subs) {
      sub.cancel();
    }
    _player?.dispose();
    super.dispose();
  }
}
