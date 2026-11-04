import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/audio_track_card.dart';
import '../../core/ui/media_widgets.dart';
import '../../core/ui/video_player_card.dart';

/// Local file library: import anything, preview images and audio, send
/// items to any contact over the mesh, and track space used. Media received
/// in chats lands here automatically.
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  List<MediaItem> _items = const <MediaItem>[];
  final Map<String, String?> _paths = <String, String?>{};
  int _totalBytes = 0;
  StreamSubscription<void>? _changesSub;

  @override
  void initState() {
    super.initState();
    _reload();
    _changesSub = MediaStore.instance.onChanged.listen((_) => _reload());
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final items = await MediaStore.instance.list();
    for (final item in items) {
      if (!_paths.containsKey(item.id)) {
        _paths[item.id] = await MediaStore.instance.pathFor(item.id);
      }
    }
    final total = await MediaStore.instance.totalBytes();
    if (!mounted) return;
    setState(() {
      _items = items;
      _totalBytes = total;
    });
  }

  List<MediaItem> get _visible => switch (_tabs.index) {
        1 => _items.where((i) => i.isImage).toList(),
        2 => _items.where((i) => i.isAudio).toList(),
        _ => _items,
      };

  /// Copies the file in without loading it, so any size works.
  Future<void> _import() async {
    final picked = await pickFileForTransfer();
    if (picked == null) return;
    await MediaStore.instance.copyFile(
      picked.path,
      name: picked.name,
      mime: picked.mime,
      source: MediaSource.import_,
    );
  }

  Future<void> _sendToContact(MediaItem item) async {
    final contacts = await ContactsService.instance.listContacts();
    if (!mounted) return;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a contact first.')),
      );
      return;
    }

    final target = await showModalBottomSheet<Contact>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Send "${item.name}" to…',
                  style: Theme.of(ctx).textTheme.titleSmall),
            ),
            for (final contact in contacts)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(contact.nickname ?? _short(contact.address)),
                subtitle: Text(_short(contact.address)),
                onTap: () => Navigator.pop(ctx, contact),
              ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;

    final name = target.nickname ?? 'contact';
    if (item.sizeBytes > MessengerService.inlineChatFileBytes) {
      // Streams peer-to-peer: much faster than the mesh path, resumable.
      final path = await MediaStore.instance.pathFor(item.id);
      if (path == null) return;
      try {
        await MessengerService.instance.sendFileTransfer(target.address,
            path: path, name: item.name, mime: item.mime);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Sending to $name — it streams straight to '
                  'them when you are near each other.')));
        }
      } on StateError catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(e.message)));
        }
      }
      return;
    }

    final bytes = await MediaStore.instance.readBytes(item.id);
    if (bytes == null) return;
    try {
      await MessengerService.instance.sendMedia(
        target.address,
        bytes: bytes,
        name: item.name,
        mime: item.mime,
        kind: item.isImage
            ? 'image'
            : item.isAudio
                ? 'audio'
                : 'file',
        durationMs: item.durationMs,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Sent to ${target.nickname ?? 'contact'}. '
                  'Delivering over the mesh.')),
        );
      }
    } on StateError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  String _sourceLabel(MediaSource source) => switch (source) {
        MediaSource.import_ => 'Imported',
        MediaSource.camera => 'Camera',
        MediaSource.memo => 'Voice memo',
        MediaSource.received => 'Received',
        MediaSource.sent => 'Sent',
      };

  Future<void> _showItemActions(MediaItem item) async {
    final path = _paths[item.id];
    await showModalBottomSheet<void>(
      context: context,
      // A video player plus the actions is taller than the default sheet.
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.isAudio && path != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: AudioFileCard(path: path, fileName: item.name),
                ),
              if (item.mime.startsWith('video/') && path != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: VideoPlayerCard(
                    title: item.name,
                    path: path,
                    duration: item.durationMs == null
                        ? null
                        : Duration(milliseconds: item.durationMs!),
                  ),
                ),
              ListTile(
                title: Text(item.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${_sourceLabel(item.source)} · ${formatBytes(item.sizeBytes)}',
                ),
              ),
              if (item.isImage && path != null)
                ListTile(
                  leading: const Icon(Icons.visibility_outlined),
                  title: const Text('View'),
                  onTap: () {
                    Navigator.pop(ctx);
                    showImageViewer(context, path);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.send_outlined),
                title: const Text('Send to contact'),
                onTap: () {
                  Navigator.pop(ctx);
                  _sendToContact(item);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await MediaStore.instance.delete(item.id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _visible;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('Storage'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'Images'),
            Tab(text: 'Audio'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _import,
        icon: const Icon(Icons.upload_file),
        label: const Text('Import'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(Icons.folder_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
                const SizedBox(width: 8),
                Text(
                  '${_items.length} items · ${formatBytes(_totalBytes)} used',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Nothing here yet.\nImport files, take photos in the '
                        'Camera app, or receive media in chats. Everything '
                        'lands in this library.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final item = items[i];
                      final path = _paths[item.id];
                      return ListTile(
                        leading: item.isImage && path != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.file(
                                  File(path),
                                  key: ValueKey(item.id),
                                  width: 44,
                                  height: 44,
                                  fit: BoxFit.cover,
                                ),
                              )
                            : Icon(
                                item.isAudio
                                    ? Icons.audiotrack
                                    : item.isImage
                                        ? Icons.image_outlined
                                        : item.mime.startsWith('video/')
                                            ? Icons.movie_outlined
                                            : Icons.insert_drive_file_outlined,
                                size: 32,
                              ),
                        title: Text(item.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${_sourceLabel(item.source)} · '
                          '${formatBytes(item.sizeBytes)}',
                        ),
                        trailing: item.isAudio && path != null
                            ? SizedBox(
                                width: 180,
                                child: AudioClipPlayer(
                                  path: path,
                                  durationMs: item.durationMs,
                                ),
                              )
                            : null,
                        onTap: () => _showItemActions(item),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
