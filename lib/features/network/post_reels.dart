import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/network_service.dart';
import 'network_common.dart';

/// Full-screen, swipe-up viewer for a run of posts.
Future<void> showPostReels(
  BuildContext context, {
  required List<NetworkPost> posts,
  required int initialIndex,
  required NetworkNames names,
  required Map<String, String?> mediaPaths,
}) {
  return Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => _PostReels(
      posts: posts,
      initialIndex: initialIndex,
      names: names,
      mediaPaths: mediaPaths,
    ),
  ));
}

class _PostReels extends StatefulWidget {
  const _PostReels({
    required this.posts,
    required this.initialIndex,
    required this.names,
    required this.mediaPaths,
  });

  final List<NetworkPost> posts;
  final int initialIndex;
  final NetworkNames names;
  final Map<String, String?> mediaPaths;

  @override
  State<_PostReels> createState() => _PostReelsState();
}

class _PostReelsState extends State<_PostReels> {
  late final PageController _pager =
      PageController(initialPage: widget.initialIndex);

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.white,
      ),
      body: PageView.builder(
        controller: _pager,
        scrollDirection: Axis.vertical,
        itemCount: widget.posts.length,
        itemBuilder: (context, i) => PostReel(
          post: widget.posts[i],
          names: widget.names,
          mediaPath: widget.posts[i].mediaId == null
              ? null
              : widget.mediaPaths[widget.posts[i].mediaId!],
        ),
      ),
    );
  }
}

/// One post filling the screen: its photo, or its text on a gradient.
class PostReel extends StatelessWidget {
  const PostReel({
    super.key,
    required this.post,
    required this.names,
    required this.mediaPath,
  });

  final NetworkPost post;
  final NetworkNames names;
  final String? mediaPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (colorA, colorB) = paletteFor(post.id);
    final name = names.of(post.author, carried: post.authorNick);
    final mine = post.author == names.myAddress;
    final textOnly = mediaPath == null;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (mediaPath != null)
          Image.file(File(mediaPath!), fit: BoxFit.cover)
        else
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [colorA, colorB],
              ),
            ),
          ),
        // Scrims for legibility over photos.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.25, 0.55, 1],
              colors: [
                Colors.black.withValues(alpha: 0.55),
                Colors.transparent,
                Colors.transparent,
                Colors.black.withValues(alpha: 0.65),
              ],
            ),
          ),
        ),
        if (textOnly && post.text.isNotEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 90, 28, 170),
              child: Text(
                post.text,
                textAlign: TextAlign.center,
                style: (post.text.length <= 90
                        ? theme.textTheme.headlineMedium
                        : theme.textTheme.titleLarge)
                    ?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 48,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  InitialAvatar(name: name, seed: post.author),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: Colors.white),
                    ),
                  ),
                  if (post.isPrivate) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.lock_outline,
                        size: 16, color: Colors.white70),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${timeAgo(post.tsMs)} · ${hopsLabel(post.hops, mine: mine)} · '
                '${timeLeft(post.expiresMs)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.white.withValues(alpha: 0.7)),
              ),
              if (!textOnly && post.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  post.text,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style:
                      theme.textTheme.bodyLarge?.copyWith(color: Colors.white),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
