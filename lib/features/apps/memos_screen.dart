import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/media_widgets.dart';

/// Voice memos: record, play back, and send clips to contacts over the mesh.
class MemosScreen extends StatefulWidget {
  const MemosScreen({super.key});

  @override
  State<MemosScreen> createState() => _MemosScreenState();
}

class _MemosScreenState extends State<MemosScreen> {
  List<MediaItem> _memos = const <MediaItem>[];
  final Map<String, String?> _paths = <String, String?>{};
  StreamSubscription<void>? _changesSub;

  @override
  void initState() {
    super.initState();
    _reload();
    _changesSub = MediaStore.instance.onChanged.listen((_) => _reload());
  }

  @override
  void dispose() {
    _changesSub?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final memos = await MediaStore.instance.list(source: MediaSource.memo);
    for (final memo in memos) {
      if (!_paths.containsKey(memo.id)) {
        _paths[memo.id] = await MediaStore.instance.pathFor(memo.id);
      }
    }
    if (mounted) setState(() => _memos = memos);
  }

  Future<void> _record() async {
    final clip = await showRecordSheet(
      context,
      title: 'Record voice memo',
      sendLabel: 'Save memo',
    );
    if (clip == null) return;
    final stamp = DateTime.now();
    await MediaStore.instance.saveBytes(
      clip.bytes,
      name: 'Memo ${stamp.month}-${stamp.day} '
          '${stamp.hour}:${stamp.minute.toString().padLeft(2, '0')}.m4a',
      mime: 'audio/mp4',
      source: MediaSource.memo,
      durationMs: clip.durationMs,
    );
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  Future<void> _send(MediaItem memo) async {
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
              child: Text('Send memo to…',
                  style: Theme.of(ctx).textTheme.titleSmall),
            ),
            for (final contact in contacts)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(contact.nickname ?? _short(contact.address)),
                onTap: () => Navigator.pop(ctx, contact),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;

    final bytes = await MediaStore.instance.readBytes(memo.id);
    if (bytes == null) return;
    await MessengerService.instance.sendMedia(
      target.address,
      bytes: bytes,
      name: memo.name,
      mime: memo.mime,
      kind: 'audio',
      durationMs: memo.durationMs,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Memo sent — delivering over the mesh.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('Voice Memos'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _record,
        icon: const Icon(Icons.mic),
        label: const Text('Record'),
      ),
      body: _memos.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.mic_none,
                        size: 56,
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                    const SizedBox(height: 12),
                    Text(
                      'No memos yet. Tap Record to capture one — you can '
                      'play it back here or send it to a contact.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: _memos.length,
              itemBuilder: (context, i) {
                final memo = _memos[i];
                final path = _paths[memo.id];
                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(memo.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium),
                              if (path != null)
                                AudioClipPlayer(
                                  path: path,
                                  durationMs: memo.durationMs,
                                ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Send to contact',
                          icon: const Icon(Icons.send_outlined),
                          onPressed: () => _send(memo),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => MediaStore.instance.delete(memo.id),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
