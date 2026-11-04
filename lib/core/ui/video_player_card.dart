import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../media/playback.dart';
import '../media/progressive_player.dart';
import 'media_widgets.dart';

/// A video played inside the app. Until it's tapped: a dark poster with a
/// play button and the file's name; then the video with its own controls
/// (seek, volume, full screen).
///
/// [path] is the complete file; [partial] the download, when it can play
/// early. With neither, play calls [onFetch].
class VideoPlayerCard extends StatefulWidget {
  const VideoPlayerCard({
    super.key,
    required this.title,
    this.path,
    this.partial,
    this.duration,
    this.onFetch,
    this.busy = false,
    this.downloadFraction,
    this.status,
    this.actions = const <Widget>[],
  });

  final String title;
  final String? path;
  final GrowingFile? partial;
  final Duration? duration;
  final VoidCallback? onFetch;

  /// Fetching the file; shows [downloadFraction] when known.
  final bool busy;
  final double? downloadFraction;

  /// Download progress, speed and time left.
  final String? status;
  final List<Widget> actions;

  @override
  State<VideoPlayerCard> createState() => _VideoPlayerCardState();
}

class _VideoPlayerCardState extends State<VideoPlayerCard> {
  final ProgressivePlayer _player = ProgressivePlayer(withVideo: true);
  String? _shownFailure;

  @override
  void initState() {
    super.initState();
    _sync();
    _player.addListener(_onPlayer);
  }

  @override
  void didUpdateWidget(covariant VideoPlayerCard old) {
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

  /// The video's own shape once known; portrait phone clips stay tall.
  double get _aspect {
    final width = _player.width;
    final height = _player.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      return 16 / 9;
    }
    return (width / height).clamp(9 / 16, 21 / 9);
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final video = player.video;
    final showVideo = video != null && player.opened;
    final joined =
        [player.waitLabel, widget.status].whereType<String>().join(' · ');
    final status = joined.isEmpty ? null : joined;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: ColoredBox(
          color: Colors.black,
          child: AspectRatio(
            aspectRatio: _aspect,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (showVideo)
                  Video(controller: video, controls: AdaptiveVideoControls)
                else
                  _poster(context, status),
                if (showVideo && status != null)
                  Positioned(left: 8, top: 8, right: 8, child: _Chip(status)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _poster(BuildContext context, String? status) {
    final theme = Theme.of(context);
    final length = _player.length;
    final details = status ?? (length == null ? null : formatDuration(length));
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1C2333), Color(0xFF05070A)],
            ),
          ),
        ),
        Center(
          child: _PlayCircle(
            busy: widget.busy || _player.waitLabel != null,
            fraction: widget.downloadFraction,
            onPressed: () => _player.toggle(fetch: widget.onFetch),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 10,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (details != null)
                Text(
                  details,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: Colors.white70),
                ),
            ],
          ),
        ),
        if (widget.actions.isNotEmpty)
          Positioned(
            top: 4,
            right: 4,
            child:
                Row(mainAxisSize: MainAxisSize.min, children: widget.actions),
          ),
      ],
    );
  }
}

class _PlayCircle extends StatelessWidget {
  const _PlayCircle({
    required this.busy,
    required this.fraction,
    required this.onPressed,
  });

  final bool busy;
  final double? fraction;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (busy)
            SizedBox(
              width: 66,
              height: 66,
              child: CircularProgressIndicator(
                value: fraction,
                strokeWidth: 3,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
          IconButton(
            tooltip: 'Play',
            onPressed: onPressed,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              minimumSize: const Size(56, 56),
            ),
            icon: const Icon(Icons.play_arrow_rounded,
                color: Colors.white, size: 38),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
