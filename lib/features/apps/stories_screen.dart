import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/stories_service.dart';
import '../../core/ui/media_widgets.dart';

const _durationOptions = <(int, String)>[
  (86400, '24 hours'),
  (259200, '3 days'),
  (604800, '1 week'),
];

/// Status updates shared with all contacts — text or photo — active for a
/// chosen duration and spread through the mesh as contacts come in range.
class StoriesScreen extends StatefulWidget {
  const StoriesScreen({super.key});

  @override
  State<StoriesScreen> createState() => _StoriesScreenState();
}

class _StoriesScreenState extends State<StoriesScreen> {
  final TextEditingController _composer = TextEditingController();

  List<Story> _stories = const <Story>[];
  List<Contact> _contacts = const <Contact>[];
  final Map<String, String?> _mediaPaths = <String, String?>{};
  String? _myAddress;
  int _ttlSeconds = 86400;
  bool _posting = false;

  Uint8List? _attachedImage;
  String? _attachedMime;

  StreamSubscription<void>? _storiesSub;

  @override
  void initState() {
    super.initState();
    _reload();
    _storiesSub =
        StoriesService.instance.onChanged.listen((_) => _reload());
  }

  @override
  void dispose() {
    _storiesSub?.cancel();
    _composer.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final stories = await StoriesService.instance.listActive();
    final contacts = await ContactsService.instance.listContacts();
    final me = await IdentityService.instance.getPublicAddressBase64();
    for (final story in stories) {
      final mediaId = story.mediaId;
      if (mediaId != null && !_mediaPaths.containsKey(mediaId)) {
        _mediaPaths[mediaId] = await MediaStore.instance.pathFor(mediaId);
      }
    }
    if (!mounted) return;
    setState(() {
      _stories = stories;
      _contacts = contacts;
      _myAddress = me;
    });
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  String _authorLabel(String address) {
    if (address == _myAddress) return 'Me';
    for (final c in _contacts) {
      if (c.address == address &&
          c.nickname != null &&
          c.nickname!.trim().isNotEmpty) {
        return c.nickname!;
      }
    }
    return _short(address);
  }

  String _expiresIn(Story story) {
    final left = Duration(
      milliseconds:
          story.expiresMs - DateTime.now().millisecondsSinceEpoch,
    );
    if (left.inDays >= 1) return '${left.inDays}d left';
    if (left.inHours >= 1) return '${left.inHours}h left';
    if (left.inMinutes >= 1) return '${left.inMinutes}m left';
    return 'expiring';
  }

  Future<void> _attachImage({required bool fromCamera}) async {
    final picked = await pickImage(fromCamera: fromCamera);
    if (picked == null || !mounted) return;
    setState(() {
      _attachedImage = picked.bytes;
      _attachedMime = picked.mime;
    });
  }

  Future<void> _post() async {
    final text = _composer.text.trim();
    if ((text.isEmpty && _attachedImage == null) || _posting) return;
    setState(() => _posting = true);
    try {
      await MessengerService.instance.postStory(
        text,
        ttlSeconds: _ttlSeconds,
        imageBytes: _attachedImage,
        imageMime: _attachedMime,
      );
      _composer.clear();
      setState(() {
        _attachedImage = null;
        _attachedMime = null;
      });
      await _reload();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Posted — delivered to contacts as they come in range',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _posting = false);
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
        title: const Text('Stories'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Post an update', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _composer,
                    minLines: 1,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: "What's happening? (favorite song, status…)",
                    ),
                  ),
                  if (_attachedImage != null) ...[
                    const SizedBox(height: 10),
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(
                            _attachedImage!,
                            height: 160,
                            width: double.infinity,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: IconButton.filledTonal(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () =>
                                setState(() => _attachedImage = null),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final (seconds, label) in _durationOptions)
                        ChoiceChip(
                          label: Text(label),
                          selected: _ttlSeconds == seconds,
                          onSelected: (_) =>
                              setState(() => _ttlSeconds = seconds),
                        ),
                      IconButton(
                        tooltip: 'Attach photo',
                        onPressed: () => _attachImage(fromCamera: false),
                        icon: const Icon(Icons.photo_outlined),
                      ),
                      if (supportsCameraCapture)
                        IconButton(
                          tooltip: 'Take photo',
                          onPressed: () => _attachImage(fromCamera: true),
                          icon: const Icon(Icons.photo_camera_outlined),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _posting ? null : _post,
                    icon: const Icon(Icons.send, size: 18),
                    label: const Text('Post'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Active stories', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          if (_stories.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No active stories. Yours and your contacts\' updates '
                'show up here.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            )
          else
            for (final story in _stories)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (story.mediaId != null &&
                        _mediaPaths[story.mediaId!] != null)
                      InkWell(
                        onTap: () => showImageViewer(
                          context,
                          _mediaPaths[story.mediaId!]!,
                          caption:
                              '${_authorLabel(story.author)} · ${story.text}',
                        ),
                        child: Image.file(
                          File(_mediaPaths[story.mediaId!]!),
                          height: 200,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ListTile(
                      leading: CircleAvatar(
                        child: Text(
                          _authorLabel(story.author)
                              .substring(0, 1)
                              .toUpperCase(),
                        ),
                      ),
                      title: story.text.isEmpty
                          ? null
                          : Text(story.text),
                      subtitle: Text(
                        '${_authorLabel(story.author)} · ${_expiresIn(story)}',
                      ),
                      trailing: story.author == _myAddress
                          ? IconButton(
                              tooltip: 'Delete story',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await MessengerService.instance
                                    .deleteStory(story.id);
                              },
                            )
                          : null,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
