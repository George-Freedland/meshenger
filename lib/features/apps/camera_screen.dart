import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/media_widgets.dart';

/// Camera roll: capture photos (live camera on phones, file import on
/// desktops), keep them in the library, and share them into chats.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  List<MediaItem> _photos = const <MediaItem>[];
  final Map<String, String?> _paths = <String, String?>{};
  StreamSubscription<void>? _changesSub;
  bool _busy = false;

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
    final photos = await MediaStore.instance.list(source: MediaSource.camera);
    for (final photo in photos) {
      if (!_paths.containsKey(photo.id)) {
        _paths[photo.id] = await MediaStore.instance.pathFor(photo.id);
      }
    }
    if (mounted) setState(() => _photos = photos);
  }

  Future<void> _capture({required bool fromCamera}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await pickImage(fromCamera: fromCamera);
      if (picked == null) return;
      await MediaStore.instance.saveBytes(
        picked.bytes,
        name: picked.name,
        mime: picked.mime,
        source: MediaSource.camera,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  Future<void> _photoActions(MediaItem photo) async {
    final path = _paths[photo.id];
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (path != null)
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
                _sendPhoto(photo);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.pop(ctx);
                await MediaStore.instance.delete(photo.id);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendPhoto(MediaItem photo) async {
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
              child: Text('Send photo to…',
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

    final bytes = await MediaStore.instance.readBytes(photo.id);
    if (bytes == null) return;
    await MessengerService.instance.sendMedia(
      target.address,
      bytes: bytes,
      name: photo.name,
      mime: photo.mime,
      kind: 'image',
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo sent — delivering over the mesh.')),
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
        title: const Text('Camera'),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (supportsCameraCapture) ...[
            FloatingActionButton.extended(
              heroTag: 'capture',
              onPressed: _busy ? null : () => _capture(fromCamera: true),
              icon: const Icon(Icons.photo_camera),
              label: const Text('Take photo'),
            ),
            const SizedBox(height: 12),
          ],
          FloatingActionButton.extended(
            heroTag: 'import',
            onPressed: _busy ? null : () => _capture(fromCamera: false),
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(
                supportsCameraCapture ? 'From gallery' : 'Import photo'),
          ),
        ],
      ),
      body: _photos.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.photo_camera_outlined,
                        size: 56,
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.3)),
                    const SizedBox(height: 12),
                    Text(
                      supportsCameraCapture
                          ? 'No photos yet. Take one with the camera or pull '
                              'one in from your gallery.'
                          : 'No photos yet. Import photos here — live camera '
                              'capture activates on the iPhone/Android build.',
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
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 160),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: _photos.length,
              itemBuilder: (context, i) {
                final photo = _photos[i];
                final path = _paths[photo.id];
                return InkWell(
                  onTap: () => _photoActions(photo),
                  borderRadius: BorderRadius.circular(10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: path == null
                        ? Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.broken_image_outlined),
                          )
                        : Image.file(File(path), fit: BoxFit.cover),
                  ),
                );
              },
            ),
    );
  }
}
