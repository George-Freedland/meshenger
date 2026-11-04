import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../media/audio_metadata.dart';
import '../media/playback.dart';
import '../media/progressive_player.dart';
import 'media_widgets.dart';

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
/// tapping play calls [onFetch]. Once [partial] shows the download, play
/// starts as soon as the rest will arrive before it's needed, and seeking
/// stays inside what has arrived. The player is only created on the first
/// play, so a feed full of songs costs nothing until one is tapped.
class AudioTrackCard extends StatefulWidget {
  const AudioTrackCard({
    super.key,
    required this.title,
    this.path,
    this.partial,
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

  /// The complete file, once it's on this device.
  final String? path;

  /// The file while it downloads, when its bytes are checked as they land
  /// and its format can play from the start.
  final GrowingFile? partial;

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
  final ProgressivePlayer _player = ProgressivePlayer();
  double? _dragging;
  String? _shownFailure;

  @override
  void initState() {
    super.initState();
    _sync();
    _player.addListener(_onPlayer);
  }

  @override
  void didUpdateWidget(covariant AudioTrackCard old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() => _player.update(
        path: widget.path,
        partial: widget.partial,
        length: widget.duration,
      );

  void _onPlayer() {
    if (!mounted) return;
    final failure = _player.failed;
    if (failure != null && failure != _shownFailure) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(failure)));
    }
    _shownFailure = failure;
    setState(() {});
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayer);
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() => _player.toggle(fetch: widget.onFetch);

  Future<void> _seek(double fraction) async {
    setState(() => _dragging = null);
    await _player.seekFraction(fraction);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const fg = Colors.white;
    final muted = fg.withValues(alpha: 0.72);
    final art = widget.art;
    final player = _player;
    final length = player.length;
    final position = player.position;
    final progress = length == null || length.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / length.inMilliseconds).clamp(0.0, 1.0);
    final subtitle =
        [widget.artist, widget.album].whereType<String>().join(' — ');
    final canSeek = player.opened && length != null;
    final joined =
        [player.waitLabel, widget.status].whereType<String>().join(' · ');
    final status = joined.isEmpty ? null : joined;
    final partial = widget.path == null ? widget.partial : null;

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
                color:
                    Colors.black.withValues(alpha: art == null ? 0.15 : 0.42),
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
                        playing: player.playing,
                        busy: widget.busy || player.waitLabel != null,
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
                                // How much of the song has downloaded.
                                secondaryActiveTrackColor:
                                    fg.withValues(alpha: 0.45),
                              ),
                              child: Slider(
                                value: _dragging ?? progress,
                                secondaryTrackValue: partial?.fraction,
                                onChanged: canSeek
                                    ? (v) => setState(() =>
                                        _dragging = min(v, player.seekLimit))
                                    : null,
                                onChangeEnd: canSeek ? _seek : null,
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              child: Row(
                                children: [
                                  if (status == null || player.opened) ...[
                                    Text(
                                      formatDuration(position),
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(color: muted),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  Expanded(
                                    child: Text(
                                      status ??
                                          (length == null
                                              ? ''
                                              : formatDuration(length)),
                                      textAlign: status == null
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
          BoxShadow(
              color: Colors.black45, blurRadius: 10, offset: Offset(0, 3)),
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
///
/// While the file is still arriving, give [partial] instead of [path]: it's
/// the same card (and the same player) from the first bytes to the finished
/// file, so a song playing as it downloads keeps playing when it completes.
class AudioFileCard extends StatefulWidget {
  const AudioFileCard({
    super.key,
    required this.path,
    required this.fileName,
    this.partial,
    this.duration,
    this.busy = false,
    this.downloadFraction,
    this.actions = const <Widget>[],
  });

  final String? path;
  final String fileName;
  final GrowingFile? partial;

  /// Playing time known before the file is here.
  final Duration? duration;
  final bool busy;
  final double? downloadFraction;
  final List<Widget> actions;

  @override
  State<AudioFileCard> createState() => _AudioFileCardState();
}

class _AudioFileCardState extends State<AudioFileCard> {
  late Future<AudioMetadata> _meta = _metaFor(widget.path);

  static Future<AudioMetadata> _metaFor(String? path) =>
      path == null ? Future.value(AudioMetadata.empty) : _cachedMetadata(path);

  @override
  void didUpdateWidget(covariant AudioFileCard old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _meta = _metaFor(widget.path);
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
          partial: widget.partial,
          title: meta.title ?? title,
          artist: meta.artist ?? artist,
          album: meta.album,
          duration: meta.duration ?? widget.duration,
          art: art == null ? null : MemoryImage(art),
          busy: widget.busy,
          downloadFraction: widget.downloadFraction,
          actions: widget.actions,
        );
      },
    );
  }
}
