import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/network_service.dart';
import 'mesh_html_view.dart';
import 'mesh_url.dart';
import 'network_common.dart';
import 'post_reels.dart';

/// A person's site: their home page, their other pages, and their personal
/// posts — or, for a page address, that page alone.
class SiteView extends StatelessWidget {
  const SiteView({
    super.key,
    required this.url,
    required this.posts,
    required this.names,
    required this.mediaPaths,
    required this.onGo,
    required this.onLink,
    required this.onEditPage,
    required this.onNewPost,
    required this.onDelete,
    required this.onSetPrivate,
    required this.onMessage,
    required this.onCopyLink,
  });

  final MeshUrl url;

  /// Every active post and page, newest first.
  final List<NetworkPost> posts;
  final NetworkNames names;
  final Map<String, String?> mediaPaths;
  final void Function(MeshUrl url) onGo;
  final void Function(String href) onLink;
  final void Function({NetworkPost? existing, String? path}) onEditPage;
  final VoidCallback onNewPost;
  final void Function(NetworkPost post) onDelete;
  final void Function(NetworkPost post, bool makePrivate) onSetPrivate;
  final void Function(String address) onMessage;
  final void Function(MeshUrl url) onCopyLink;

  String get _owner => url.site!;
  bool get _mine => _owner == names.myAddress;

  @override
  Widget build(BuildContext context) {
    final ownerPosts = posts.where((p) => p.author == _owner).toList();
    if (url.path.isNotEmpty) {
      return _buildPage(context, ownerPosts);
    }
    return _buildHome(context, ownerPosts);
  }

  NetworkPost? _pageAt(List<NetworkPost> ownerPosts, String path) {
    for (final p in ownerPosts) {
      if (p.isPage && p.path == path) return p;
    }
    return null;
  }

  Widget _buildHome(BuildContext context, List<NetworkPost> ownerPosts) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final home = _pageAt(ownerPosts, '');
    final pages = ownerPosts.where((p) => p.isPage && p.path != '').toList()
      ..sort((a, b) => a.path!.compareTo(b.path!));
    final sitePosts =
        ownerPosts.where((p) => !p.isPage && !p.isGlobal).toList();
    final nothing = home == null && pages.isEmpty && sitePosts.isEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _header(context, ownerPosts),
        const SizedBox(height: 16),
        if (home != null) ...[
          if (_mine) _pageToolbar(context, home),
          MeshHtmlView(html: home.text, onLink: onLink),
          const SizedBox(height: 20),
        ] else if (_mine) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Make this your website',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Your public key is your address on the mesh. Write a '
                    'home page in HTML — headings, links, images, your own '
                    'colors — and anyone nearby who visits sees it here.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () => onEditPage(path: ''),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Create home page'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
        if (pages.isNotEmpty || _mine) ...[
          _sectionTitle(
            context,
            'Pages',
            action: _mine
                ? TextButton.icon(
                    onPressed: () => onEditPage(),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New page'),
                  )
                : null,
          ),
          if (pages.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'Pages live at your key plus a path, like …/blog.',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          for (final page in pages)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                page.isPrivate ? Icons.lock_outline : Icons.article_outlined,
              ),
              title: Text(page.title ?? '/${page.path}'),
              subtitle: Text('/${page.path} · updated ${timeAgo(page.tsMs)}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onGo(MeshUrl.site(_owner, page.path!)),
            ),
          const SizedBox(height: 12),
        ],
        if (sitePosts.isNotEmpty || _mine) ...[
          _sectionTitle(
            context,
            'Posts',
            action: _mine
                ? TextButton.icon(
                    onPressed: onNewPost,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New post'),
                  )
                : null,
          ),
          if (sitePosts.isEmpty)
            Text(
              'Posts you put on your site show up here (and can be private).',
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          for (var i = 0; i < sitePosts.length; i++)
            _postCard(context, sitePosts, i),
        ],
        if (nothing && !_mine)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Column(
              children: [
                Icon(Icons.travel_explore, size: 48, color: muted),
                const SizedBox(height: 10),
                Text(
                  'Nothing from ${names.of(_owner)} has reached your mesh yet.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                Text(
                  'Sites travel device-to-device. When they — or anyone '
                  'carrying their pages — come into range, it fills in.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPage(BuildContext context, List<NetworkPost> ownerPosts) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final page = _pageAt(ownerPosts, url.path);
    final owner = names.of(_owner);
    if (page == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.find_in_page_outlined, size: 48, color: muted),
              const SizedBox(height: 10),
              Text('/${url.path} isn\'t on your mesh',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                _mine
                    ? 'You haven\'t made this page yet.'
                    : 'Either $owner hasn\'t made it, or it hasn\'t reached '
                        'you yet — pages travel device-to-device.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
              const SizedBox(height: 16),
              if (_mine)
                FilledButton.icon(
                  onPressed: () => onEditPage(path: url.path),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Create it'),
                )
              else
                OutlinedButton(
                  onPressed: () => onGo(MeshUrl.site(_owner)),
                  child: Text('Go to $owner\'s site'),
                ),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        Row(
          children: [
            InkWell(
              onTap: () => onGo(MeshUrl.site(_owner)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InitialAvatar(name: owner, seed: _owner, radius: 12),
                  const SizedBox(width: 8),
                  Text(owner, style: theme.textTheme.labelLarge),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'updated ${timeAgo(page.tsMs)} · ${timeLeft(page.expiresMs)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_mine) _pageToolbar(context, page),
        MeshHtmlView(html: page.text, onLink: onLink),
      ],
    );
  }

  Widget _header(BuildContext context, List<NetworkPost> ownerPosts) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final name =
        names.of(_owner, carried: _carriedNick(ownerPosts), you: false);
    return Row(
      children: [
        InitialAvatar(name: name, seed: _owner, radius: 28),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _mine ? '$name (you)' : name,
                style: theme.textTheme.titleLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                shortAddress(_owner),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: muted, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        if (!_mine)
          IconButton(
            tooltip: 'Message',
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () => onMessage(_owner),
          ),
        IconButton(
          tooltip: 'Copy link',
          icon: const Icon(Icons.link),
          onPressed: () => onCopyLink(MeshUrl.site(_owner)),
        ),
      ],
    );
  }

  String? _carriedNick(List<NetworkPost> ownerPosts) {
    for (final p in ownerPosts) {
      final nick = p.authorNick?.trim();
      if (nick != null && nick.isNotEmpty) return nick;
    }
    return null;
  }

  Widget _sectionTitle(BuildContext context, String title, {Widget? action}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (action != null) action,
        ],
      ),
    );
  }

  /// Edit / visibility / delete controls over one of my pages.
  Widget _pageToolbar(BuildContext context, NetworkPost page) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            page.isPrivate ? Icons.lock_outline : Icons.public,
            size: 16,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              page.isPrivate
                  ? 'Private — only you can see this page'
                  : 'Public — anyone your mesh reaches can open it',
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton.icon(
            onPressed: () => onEditPage(existing: page),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Edit'),
          ),
          _MineMenu(
            post: page,
            onDelete: onDelete,
            onSetPrivate: onSetPrivate,
          ),
        ],
      ),
    );
  }

  Widget _postCard(BuildContext context, List<NetworkPost> sitePosts, int i) {
    final theme = Theme.of(context);
    final post = sitePosts[i];
    final mediaPath = post.mediaId == null ? null : mediaPaths[post.mediaId!];
    final (colorA, colorB) = paletteFor(post.id);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => showPostReels(
          context,
          posts: sitePosts,
          initialIndex: i,
          names: names,
          mediaPaths: mediaPaths,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (mediaPath != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: Image.file(File(mediaPath), fit: BoxFit.cover),
              )
            else if (post.text.isNotEmpty)
              Container(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [colorA, colorB]),
                ),
                child: Text(
                  post.text,
                  textAlign: TextAlign.center,
                  maxLines: 8,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  if (post.isPrivate) ...[
                    const Icon(Icons.lock_outline, size: 14),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      [
                        if (mediaPath != null && post.text.isNotEmpty)
                          post.text,
                        timeAgo(post.tsMs),
                        if (post.isPrivate)
                          'private'
                        else
                          timeLeft(post.expiresMs),
                      ].join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                  if (_mine)
                    _MineMenu(
                      post: post,
                      onDelete: onDelete,
                      onSetPrivate: onSetPrivate,
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

class _MineMenu extends StatelessWidget {
  const _MineMenu({
    required this.post,
    required this.onDelete,
    required this.onSetPrivate,
  });

  final NetworkPost post;
  final void Function(NetworkPost post) onDelete;
  final void Function(NetworkPost post, bool makePrivate) onSetPrivate;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      onSelected: (action) {
        switch (action) {
          case 'private':
            onSetPrivate(post, true);
          case 'public':
            onSetPrivate(post, false);
          case 'delete':
            onDelete(post);
        }
      },
      itemBuilder: (_) => [
        if (post.isPrivate)
          const PopupMenuItem(
            value: 'public',
            child: ListTile(
              leading: Icon(Icons.public),
              title: Text('Make public'),
            ),
          )
        else
          const PopupMenuItem(
            value: 'private',
            child: ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('Make private'),
            ),
          ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Delete'),
          ),
        ),
      ],
    );
  }
}
