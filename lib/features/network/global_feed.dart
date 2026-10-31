import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/media/post_file.dart';
import '../../core/services/mesh_activity.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/network_service.dart';
import '../../core/services/settings_service.dart';
import '../../core/transport/envelope_codec.dart';
import '../../core/ui/media_widgets.dart';
import '../shared/safety_actions.dart';
import 'network_common.dart';
import 'post_attachment_view.dart';
import 'post_composer.dart';

/// The `global` page: one public square for everyone the mesh reaches,
/// laid out like a group chat (newest at the bottom).
class GlobalFeed extends StatefulWidget {
  const GlobalFeed({
    super.key,
    required this.posts,
    required this.names,
    required this.mediaPaths,
    required this.events,
    required this.meshCount,
    required this.onOpenSite,
    required this.onDelete,
  });

  /// Global posts, newest first.
  final List<NetworkPost> posts;
  final NetworkNames names;
  final Map<String, String?> mediaPaths;
  final List<MeshActivityEvent> events;
  final int meshCount;
  final void Function(String address) onOpenSite;
  final void Function(NetworkPost post) onDelete;

  @override
  State<GlobalFeed> createState() => _GlobalFeedState();
}

class _GlobalFeedState extends State<GlobalFeed> {
  final TextEditingController _text = TextEditingController();
  int _ttlSeconds = 86400;
  Uint8List? _image;
  String? _imageMime;
  PreparedPostFile? _file;
  bool _preparing = false;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _showAttachMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file_rounded),
              title: const Text('File'),
              subtitle: const Text('Songs, videos, documents — any size'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'photo') await _attach();
    if (choice == 'file') await _attachFile();
  }

  Future<void> _attach() async {
    final picked =
        await pickImage(fromCamera: false, maxWidth: 1080, imageQuality: 70);
    if (picked == null || !mounted) return;
    if (picked.bytes.length > EnvelopeCodec.maxPostMediaBytes) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Photo is too large for a broadcast (max 512 KB)'),
      ));
      return;
    }
    setState(() {
      _image = picked.bytes;
      _imageMime = picked.mime;
      _file = null;
    });
  }

  Future<void> _attachFile() async {
    final picked = await pickFileForTransfer();
    if (picked == null || !mounted) return;
    setState(() {
      _preparing = true;
      _image = null;
      _file = null;
    });
    try {
      final prepared = await preparePostFile(
          path: picked.path, name: picked.name, mime: picked.mime);
      if (mounted) setState(() => _file = prepared);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if ((text.isEmpty && _image == null && _file == null) ||
        _sending ||
        _preparing) {
      return;
    }
    setState(() => _sending = true);
    try {
      await MessengerService.instance.postToNetwork(
        text,
        ttlSeconds: _ttlSeconds,
        imageBytes: _image,
        imageMime: _imageMime,
        file: _file,
      );
      _text.clear();
      setState(() {
        _image = null;
        _file = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final posts = widget.posts;
    return Column(
      children: [
        if (widget.events.isNotEmpty) _ActivityPanel(widget: widget),
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: posts.length + 1,
            itemBuilder: (context, i) => i == posts.length
                ? _Welcome(meshCount: widget.meshCount, empty: posts.isEmpty)
                : _Bubble(post: posts[i], widget: widget),
          ),
        ),
        const Divider(height: 1),
        if (_image != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(_image!,
                      width: 56, height: 56, fit: BoxFit.cover),
                ),
                const SizedBox(width: 8),
                const Expanded(child: Text('Photo attached')),
                IconButton(
                  tooltip: 'Remove photo',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => _image = null),
                ),
              ],
            ),
          ),
        if (_preparing || _file != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: AttachedFilePreview(
              file: _file,
              onRemove: () => setState(() => _file = null),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Attach',
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: _showAttachMenu,
                ),
                PopupMenuButton<int>(
                  tooltip: 'How long it stays up',
                  icon: const Icon(Icons.timer_outlined),
                  initialValue: _ttlSeconds,
                  onSelected: (v) => setState(() => _ttlSeconds = v),
                  itemBuilder: (_) => [
                    for (final (seconds, label) in networkPostDurations)
                      PopupMenuItem(
                          value: seconds, child: Text('Stays up $label')),
                  ],
                ),
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Message everyone on the mesh…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  tooltip: 'Post to global',
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.meshCount, required this.empty});

  final int meshCount;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Column(
        children: [
          Icon(Icons.public, size: 40, color: muted),
          const SizedBox(height: 8),
          Text('Global', style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            empty
                ? 'Nothing here yet. Whatever you post is visible to everyone '
                    'your mesh reaches — contacts or strangers — and travels '
                    'with people as they move between meshes.'
                : 'The square everyone on your mesh shares. Tap a name to '
                    'visit their site.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 4),
          Text(
            '$meshCount ${meshCount == 1 ? 'device' : 'devices'} in your mesh',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.post, required this.widget});

  final NetworkPost post;
  final GlobalFeed widget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = post.author == widget.names.myAddress;
    final name = widget.names.of(post.author, carried: post.authorNick);
    final mediaPath =
        post.mediaId == null ? null : widget.mediaPaths[post.mediaId!];
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: mine
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!mine)
            InkWell(
              onTap: () => widget.onOpenSite(post.author),
              child: Text(
                name,
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: paletteFor(post.author).$2),
              ),
            ),
          if (mediaPath != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(File(mediaPath), fit: BoxFit.cover),
            ),
          ],
          if (post.attachment != null) ...[
            const SizedBox(height: 6),
            PostAttachmentView(
              attachment: post.attachment!,
              artPath: post.artMediaId == null
                  ? null
                  : widget.mediaPaths[post.artMediaId!],
            ),
          ],
          if (post.text.isNotEmpty) ...[
            const SizedBox(height: 4),
            SelectableText(post.text, style: theme.textTheme.bodyLarge),
          ],
          const SizedBox(height: 4),
          Text(
            '${timeAgo(post.tsMs)} · ${hopsLabel(post.hops, mine: mine)} · '
            '${timeLeft(post.expiresMs)}',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            GestureDetector(
              onTap: () => widget.onOpenSite(post.author),
              child: InitialAvatar(name: name, seed: post.author),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: mine
                ? GestureDetector(
                    onLongPress: () => widget.onDelete(post),
                    child: bubble,
                  )
                : bubble,
          ),
          if (mine)
            IconButton(
              tooltip: 'Remove from the mesh',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.delete_outline, size: 18, color: muted),
              onPressed: () => widget.onDelete(post),
            )
          else
            SafetyMenu(
              address: post.author,
              name: name,
              post: post,
              iconSize: 18,
              color: muted,
            ),
        ],
      ),
    );
  }
}

/// Who joined or left the mesh: one summary line when minimized, a short
/// scrollable list when expanded. The choice is remembered.
class _ActivityPanel extends StatefulWidget {
  const _ActivityPanel({required this.widget});

  final GlobalFeed widget;

  @override
  State<_ActivityPanel> createState() => _ActivityPanelState();
}

class _ActivityPanelState extends State<_ActivityPanel> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    SettingsService.instance.getActivityExpanded().then((expanded) {
      if (mounted && expanded != _expanded) {
        setState(() => _expanded = expanded);
      }
    });
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    SettingsService.instance.setActivityExpanded(_expanded);
  }

  String _describe(MeshActivityEvent event) {
    final name =
        widget.widget.names.of(event.address, carried: event.nickname);
    return '$name ${event.joined ? 'joined your mesh' : 'left'}';
  }

  Widget _icon(MeshActivityEvent event, double size) => Icon(
        event.joined ? Icons.sensors : Icons.sensors_off,
        size: size,
        color: event.joined ? Colors.greenAccent : null,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final events = widget.widget.events;
    final latest = events.first;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
                child: Row(
                  children: [
                    _icon(latest, 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _expanded
                            ? 'Mesh activity'
                            : '${_describe(latest)} · ${timeAgo(latest.tsMs)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _expanded
                            ? theme.textTheme.labelLarge
                            : theme.textTheme.bodySmall,
                      ),
                    ),
                    if (events.length > 1)
                      Text('${events.length}',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: muted)),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      semanticLabel: _expanded
                          ? 'Minimize mesh activity'
                          : 'Show all mesh activity',
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 4),
                  itemCount: events.length,
                  itemBuilder: (context, i) {
                    final event = events[i];
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: _icon(event, 18),
                      title: Text(_describe(event),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text(timeAgo(event.tsMs),
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: muted)),
                      onTap: () => widget.widget.onOpenSite(event.address),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
