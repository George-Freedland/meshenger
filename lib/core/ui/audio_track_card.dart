import 'dart:async';
import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../media/audio_metadata.dart';
import 'media_widgets.dart';

/// Only one track plays at a time: starting one pauses whichever was on.
final ValueNotifier<Object?> _nowPlaying = ValueNotifier<Object?>(null);

/// "Artist - Title.mp3" gives (title, artist); otherwise the name without
/// its extension and no artist.
(String, String?) trackNameFromFile(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final stem = (dot > 0 ? fileName.substring(0, dot) : fileName)
      .replaceAll('_', ' ')
      .trim();
  final dash = stem.indexOf(' - ');
  if (dash > 0 && dash + 3 < stem.length) {
    return (stem.substring(dash + 3).trim(), stem.substring(0, dash).trim());
  }
  return (stem.isEmpty ? fileName : stem, null);
}

List<Color> _gradientFor(String seed) {
  final hue = (seed.hashCode.abs() % 360).toDouble();
  return [
    HSVColor.fromAHSV(1, hue, 0.55, 0.55).toColor(),
    HSVColor.fromAHSV(1, (hue + 50) % 360, 0.7, 0.28).toColor(),
  ];
}

/// A song with its cover art, played in place: play, pause, seek.
///
/// [path] may be null while the file is still on someone else's device:
/// tapping play calls [onFetch], and playback starts as soon as the file
/// arrives. The audio player is only created on the first play, so a feed
/// full of songs costs nothing until one is tapped.
class AudioTrackCard extends StatefulWidget {
  const AudioTrackCard({
    super.key,
    required this.title,
    this.path,
    this.artist,
    this.album,
    this.duration,
    this.art,
    this.onFetch,
    this.busy = false,
    this.downloadFraction,
    this.status,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? path;
  final String? artist;
  final String? album;
  final Duration? duration;
  final ImageProvider? art;
  final VoidCallback? onFetch;

  /// Fetching the file; shows [downloadFraction] when known.
  final bool busy;
  final double? downloadFraction;

  /// Shown instead of the track length while fetching.
  final String? status;
  final List<Widget> actions;

  @override
  State<AudioTrackCard> createState() => _AudioTrackCardState();
}

class _AudioTrackCardState extends State<AudioTrackCard> {
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  PlayerState _state = PlayerState.stopped;
  Duration _position = Duration.zero;
  Duration? _length;
  double? _dragging;
  bool _playWhenReady = false;

  @override
  void initState() {
    super.initState();
    _length = widget.duration;
    _nowPlaying.addListener(_onNowPlaying);
  }

  @override
  void didUpdateWidget(covariant AudioTrackCard old) {
    super.didUpdateWidget(old);
    _length ??= widget.duration;
    if (old.path != widget.path) {
      if (old.path != null) unawaited(_player?.stop());
      if (widget.path != null && _playWhenReady) {
        _playWhenReady = false;
        unawaited(_play());
      }
    }
  }

  @override
  void dispose() {
    _nowPlaying.removeListener(_onNowPlaying);
    if (_nowPlaying.value == this) _nowPlaying.value = null;
    for (final sub in _subs) {
      sub.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  void _onNowPlaying() {
    if (_nowPlaying.value != this && _state == PlayerState.playing) {
      unawaited(_player?.pause());
    }
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _subs
      ..add(player.onPlayerStateChanged.listen((state) {
        if (mounted) setState(() => _state = state);
      }))
      ..add(player.onPositionChanged.listen((position) {
        if (mounted) setState(() => _position = position);
      }))
      ..add(player.onDurationChanged.listen((length) {
        if (mounted && length > Duration.zero) {
          setState(() => _length = length);
        }
      }))
      ..add(player.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _position = Duration.zero);
      }));
    return _player = player;
  }

  Future<void> _play() async {
    final path = widget.path;
    if (path == null) return;
    _nowPlaying.value = this;
    final player = _ensurePlayer();
    try {
      if (_state == PlayerState.paused) {
        await player.resume();
      } else {
        await player.play(DeviceFileSource(path));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("This device can't play that file")));
      }
    }
  }

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) {
      await _player?.pause();
    } else if (widget.path == null) {
      setState(() => _playWhenReady = true);
      widget.onFetch?.call();
    } else {
      await _play();
    }
  }

  Future<void> _seek(double fraction) async {
    final length = _length;
    setState(() => _dragging = null);
    if (length == null) return;
    await _player
        ?.seek(Duration(milliseconds: (fraction * length.inMilliseconds).round()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const fg = Colors.white;
    final muted = fg.withValues(alpha: 0.72);
    final art = widget.art;
    final length = _length;
    final progress = length == null || length.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / length.inMilliseconds).clamp(0.0, 1.0);
    final subtitle =
        [widget.artist, widget.album].whereType<String>().join(' — ');
    final canSeek = _player != null && length != null;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Positioned.fill(
              child: art == null
                  ? DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: _gradientFor(widget.title),
                        ),
                      ),
                    )
                  : ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                      child: Image(image: art, fit: BoxFit.cover),
                    ),
            ),
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: art == null ? 0.15 : 0.42),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 6, 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Cover(art: art, seed: widget.title),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: fg,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (subtitle.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: muted),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      ...widget.actions,
                    ],
                  ),
                  Row(
                    children: [
                      _PlayButton(
                        playing: _state == PlayerState.playing,
                        busy: widget.busy,
                        fraction: widget.downloadFraction,
                        onPressed: _toggle,
                      ),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                // No handle until there is something to seek.
                                thumbShape: canSeek
                                    ? const RoundSliderThumbShape(
                                        enabledThumbRadius: 6)
                                    : SliderComponentShape.noThumb,
                                overlayShape: canSeek
                                    ? const RoundSliderOverlayShape(
                                        overlayRadius: 12)
                                    : SliderComponentShape.noOverlay,
                                activeTrackColor: fg,
                                inactiveTrackColor: fg.withValues(alpha: 0.25),
                                thumbColor: fg,
                                disabledActiveTrackColor:
                                    fg.withValues(alpha: 0.6),
                                disabledInactiveTrackColor:
                                    fg.withValues(alpha: 0.2),
                              ),
                              child: Slider(
                                value: _dragging ?? progress,
                                onChanged: canSeek
                                    ? (v) => setState(() => _dragging = v)
                                    : null,
                                onChangeEnd: canSeek ? _seek : null,
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              child: Row(
                                children: [
                                  if (widget.status == null) ...[
                                    Text(
                                      formatDuration(_position),
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(color: muted),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Expanded(
                                    child: Text(
                                      widget.status ??
                                          (length == null
                                              ? ''
                                              : formatDuration(length)),
                                      textAlign: widget.status == null
                                          ? TextAlign.end
                                          : TextAlign.start,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(color: muted),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({required this.art, required this.seed});

  final ImageProvider? art;
  final String seed;

  @override
  Widget build(BuildContext context) {
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _gradientFor(seed).reversed.toList(),
        ),
      ),
      child: const Center(
        child: Icon(Icons.music_note_rounded, color: Colors.white70, size: 30),
      ),
    );
    final image = art;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 3)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 68,
          height: 68,
          child: image == null
              ? placeholder
              : Image(
                  image: image,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder,
                ),
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.busy,
    required this.fraction,
    required this.onPressed,
  });

  final bool playing;
  final bool busy;
  final double? fraction;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (busy)
            SizedBox(
              width: 46,
              height: 46,
              child: CircularProgressIndicator(
                value: fraction,
                strokeWidth: 3,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
          IconButton(
            tooltip: playing ? 'Pause' : 'Play',
            onPressed: onPressed,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.18),
            ),
            icon: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
        ],
      ),
    );
  }
}

final Map<String, Future<AudioMetadata>> _metadataCache =
    <String, Future<AudioMetadata>>{};

Future<AudioMetadata> _cachedMetadata(String path) {
  if (_metadataCache.length >= 64) {
    _metadataCache.remove(_metadataCache.keys.first);
  }
  return _metadataCache.putIfAbsent(path, () => readAudioMetadata(path));
}

/// [AudioTrackCard] for a file on this device: tags and cover come from
/// the file, falling back to its name.
class AudioFileCard extends StatefulWidget {
  const AudioFileCard({
    super.key,
    required this.path,
    required this.fileName,
    this.actions = const <Widget>[],
  });

  final String path;
  final String fileName;
  final List<Widget> actions;

  @override
  State<AudioFileCard> createState() => _AudioFileCardState();
}

class _AudioFileCardState extends State<AudioFileCard> {
  late Future<AudioMetadata> _meta = _cachedMetadata(widget.path);

  @override
  void didUpdateWidget(covariant AudioFileCard old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _meta = _cachedMetadata(widget.path);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AudioMetadata>(
      future: _meta,
      builder: (context, snapshot) {
        final meta = snapshot.data ?? AudioMetadata.empty;
        final (title, artist) = trackNameFromFile(widget.fileName);
        final art = meta.art;
        return AudioTrackCard(
          path: widget.path,
          title: meta.title ?? title,
          artist: meta.artist ?? artist,
          album: meta.album,
          duration: meta.duration,
          art: art == null ? null : MemoryImage(art),
          actions: widget.actions,
        );
      },
    );
  }
}
