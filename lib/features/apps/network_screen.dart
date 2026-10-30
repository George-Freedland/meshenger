import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/media_store.dart';
import '../../core/services/mesh_activity.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/network_service.dart';
import '../../core/services/peer_directory.dart';
import '../../core/services/transport_log.dart';
import '../../core/transport/envelope_codec.dart';
import '../../core/ui/media_widgets.dart';
import '../shared/transport_status_banner.dart';

const _durationOptions = <(int, String)>[
  (3600, '1 hour'),
  (86400, '24 hours'),
  (259200, '3 days'),
  (604800, '1 week'),
];

/// The Network: a mesh-local public feed. Whatever you post — a song,
/// a photo of something happening, a thought — is visible to everyone
/// your mesh can reach, contacts or strangers, and travels with people
/// as they move between meshes. Swipe vertically, reels-style.
class NetworkScreen extends StatefulWidget {
  const NetworkScreen({super.key});

  @override
  State<NetworkScreen> createState() => _NetworkScreenState();
}

class _NetworkScreenState extends State<NetworkScreen> {
  final PageController _pager = PageController();

  List<NetworkPost> _posts = const <NetworkPost>[];
  List<MeshActivityEvent> _events = const <MeshActivityEvent>[];
  List<Contact> _contacts = const <Contact>[];
  final Map<String, String?> _mediaPaths = <String, String?>{};
  final Map<String, String> _peerNames = <String, String>{};
  String? _myAddress;
  int _meshCount = 0;
  int _page = 0;

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _reload();
    _subs.add(
        NetworkService.instance.onPostsChanged.listen((_) => _reload()));
    _subs.add(MeshActivityLog.instance.onChanged.listen((_) => _reload()));
    _subs.add(
        MessengerService.instance.onPeersChanged.listen((_) => _reload()));
    _pager.addListener(() {
      final page = _pager.page?.round() ?? 0;
      if (page != _page && mounted) setState(() => _page = page);
    });
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _pager.dispose();
    super.dispose();
  }

  bool _reloading = false;
  bool _reloadQueued = false;

  /// Coalesces bursts of change events into at most one pending reload.
  Future<void> _reload() async {
    if (_reloading) {
      _reloadQueued = true;
      return;
    }
    _reloading = true;
    try {
      do {
        _reloadQueued = false;
        final watch = Stopwatch()..start();
        try {
          await _reloadOnce();
        } catch (e, st) {
          TransportLog.instance.log('Network feed: reload failed: $e');
          debugPrintStack(stackTrace: st, label: 'Network feed reload');
        }
        TransportLog.instance.log(
            'Network feed: reloaded ${_posts.length} post(s) in '
            '${watch.elapsedMilliseconds} ms');
      } while (_reloadQueued && mounted);
    } finally {
      _reloading = false;
    }
  }

  Future<void> _reloadOnce() async {
    final posts = await NetworkService.instance.listActive();
    final allEvents = await MeshActivityLog.instance.list();
    final contacts = await ContactsService.instance.listContacts();
    final me = await IdentityService.instance.getPublicAddressBase64();
    final recent = await PeerDirectory.instance.listRecent();

    final dayAgo =
        DateTime.now().millisecondsSinceEpoch - const Duration(hours: 24).inMilliseconds;
    final events =
        allEvents.where((e) => e.tsMs > dayAgo).take(20).toList();

    for (final post in posts) {
      final mediaId = post.mediaId;
      if (mediaId != null && !_mediaPaths.containsKey(mediaId)) {
        _mediaPaths[mediaId] = await MediaStore.instance.pathFor(mediaId);
      }
    }
    // Freshest known nicknames for everyone we might render.
    for (final address in <String>{
      ...posts.map((p) => p.author),
      ...events.map((e) => e.address),
    }) {
      final peer = await PeerDirectory.instance.get(address);
      final nick = peer?.nickname;
      if (nick != null && nick.trim().isNotEmpty) {
        _peerNames[address] = nick.trim();
      }
    }

    await NetworkService.instance.markSeen();
    if (!mounted) return;
    setState(() {
      _posts = posts;
      _events = events;
      _contacts = contacts;
      _myAddress = me;
      _meshCount = recent.length;
    });
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  String _nameFor(String address, {String? carried}) {
    if (address == _myAddress) return 'You';
    for (final c in _contacts) {
      if (c.address == address &&
          c.nickname != null &&
          c.nickname!.trim().isNotEmpty) {
        return c.nickname!.trim();
      }
    }
    final live = _peerNames[address];
    if (live != null) return live;
    if (carried != null && carried.trim().isNotEmpty) return carried.trim();
    return _short(address);
  }

  String _ago(int tsMs) {
    final delta = Duration(
        milliseconds: DateTime.now().millisecondsSinceEpoch - tsMs);
    if (delta.inDays >= 1) return '${delta.inDays}d ago';
    if (delta.inHours >= 1) return '${delta.inHours}h ago';
    if (delta.inMinutes >= 1) return '${delta.inMinutes}m ago';
    return 'just now';
  }

  String _expiresIn(NetworkPost post) {
    final left = Duration(
      milliseconds: post.expiresMs - DateTime.now().millisecondsSinceEpoch,
    );
    if (left.inDays >= 1) return '${left.inDays}d left';
    if (left.inHours >= 1) return '${left.inHours}h left';
    if (left.inMinutes >= 1) return '${left.inMinutes}m left';
    return 'expiring';
  }

  // Deterministic vivid gradient per post (text posts get a "card" look).
  static const _palettes = <(Color, Color)>[
    (Color(0xFF3A1C71), Color(0xFFD76D77)),
    (Color(0xFF134E5E), Color(0xFF71B280)),
    (Color(0xFF232526), Color(0xFF414345)),
    (Color(0xFF0F2027), Color(0xFF2C5364)),
    (Color(0xFF5A3F37), Color(0xFF2C7744)),
    (Color(0xFF41295A), Color(0xFF2F0743)),
    (Color(0xFF1E3C72), Color(0xFF2A5298)),
    (Color(0xFF8E2DE2), Color(0xFF4A00E0)),
  ];

  (Color, Color) _paletteFor(String id) =>
      _palettes[id.hashCode.abs() % _palettes.length];

  Future<void> _deletePost(NetworkPost post) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this post from the mesh?'),
        content: const Text(
          'It disappears here immediately, and a signed removal spreads '
          'through the mesh so every device carrying it drops it too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await MessengerService.instance.deleteNetworkPost(post.id);
  }

  Future<void> _openComposer() async {
    final composer = TextEditingController();
    Uint8List? attachedImage;
    String? attachedMime;
    int ttlSeconds = 86400;
    var posting = false;
    String? error;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Future<void> attach({required bool fromCamera}) async {
              final picked = await pickImage(
                fromCamera: fromCamera,
                maxWidth: 1080,
                imageQuality: 70,
              );
              if (picked == null) return;
              if (picked.bytes.length > EnvelopeCodec.maxPostMediaBytes) {
                setSheetState(() => error =
                    'Photo is too large for a broadcast (max 512 KB). '
                    'Try a smaller one.');
                return;
              }
              setSheetState(() {
                attachedImage = picked.bytes;
                attachedMime = picked.mime;
                error = null;
              });
            }

            Future<void> post() async {
              final text = composer.text.trim();
              if ((text.isEmpty && attachedImage == null) || posting) return;
              setSheetState(() {
                posting = true;
                error = null;
              });
              try {
                await MessengerService.instance.postToNetwork(
                  text,
                  ttlSeconds: ttlSeconds,
                  imageBytes: attachedImage,
                  imageMime: attachedMime,
                );
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Posted to your mesh. It spreads device-to-device '
                        'as people move.',
                      ),
                    ),
                  );
                }
              } catch (e) {
                setSheetState(() {
                  posting = false;
                  error = '$e';
                });
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Share to your mesh',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Everyone your mesh reaches sees this — contacts or '
                    'not. No account, no server, no algorithm.',
                    style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                          color: Theme.of(sheetContext)
                              .colorScheme
                              .onSurface
                              .withValues(alpha: 0.6),
                        ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: composer,
                    minLines: 2,
                    maxLines: 5,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText:
                          "What's happening? A song, an accident, a thought…",
                    ),
                  ),
                  if (attachedImage != null) ...[
                    const SizedBox(height: 10),
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.memory(
                            attachedImage!,
                            height: 140,
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
                                setSheetState(() => attachedImage = null),
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
                          selected: ttlSeconds == seconds,
                          onSelected: (_) =>
                              setSheetState(() => ttlSeconds = seconds),
                        ),
                      IconButton(
                        tooltip: 'Attach photo',
                        onPressed: () => attach(fromCamera: false),
                        icon: const Icon(Icons.photo_outlined),
                      ),
                      if (supportsCameraCapture)
                        IconButton(
                          tooltip: 'Take photo',
                          onPressed: () => attach(fromCamera: true),
                          icon: const Icon(Icons.photo_camera_outlined),
                        ),
                    ],
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(sheetContext).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: posting ? null : post,
                    icon: const Icon(Icons.podcasts, size: 18),
                    label: Text(posting ? 'Posting…' : 'Post to the mesh'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _activityTicker(ThemeData theme) {
    if (_events.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _events.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final event = _events[i];
          final name = _nameFor(event.address, carried: event.nickname);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  event.joined ? Icons.sensors : Icons.sensors_off,
                  size: 13,
                  color: event.joined
                      ? Colors.greenAccent
                      : Colors.white.withValues(alpha: 0.45),
                ),
                const SizedBox(width: 5),
                Text(
                  '$name ${event.joined ? 'joined your mesh' : 'left'} · '
                  '${_ago(event.tsMs)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _postPage(NetworkPost post, ThemeData theme) {
    final mediaPath =
        post.mediaId != null ? _mediaPaths[post.mediaId!] : null;
    final (colorA, colorB) = _paletteFor(post.id);
    final name = _nameFor(post.author, carried: post.authorNick);
    final mine = post.author == _myAddress;
    final textOnly = mediaPath == null;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (mediaPath != null)
          Image.file(File(mediaPath), fit: BoxFit.cover)
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
          bottom: 92,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: colorB,
                    child: Text(
                      name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
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
                  const SizedBox(width: 8),
                  if (mine)
                    IconButton(
                      tooltip: 'Remove from mesh',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.delete_outline,
                          size: 20, color: Colors.white70),
                      onPressed: () => _deletePost(post),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${_ago(post.tsMs)} · '
                '${post.hops == 0 ? (mine ? 'posted here' : 'right next to you') : '${post.hops} hop${post.hops == 1 ? '' : 's'} away'} · '
                '${_expiresIn(post)}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.white.withValues(alpha: 0.7)),
              ),
              if (!textOnly && post.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  post.text,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge
                      ?.copyWith(color: Colors.white),
                ),
              ],
            ],
          ),
        ),
        if (_page == 0 && _posts.length > 1)
          Positioned(
            bottom: 26,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.keyboard_arrow_up,
                    color: Colors.white54, size: 22),
                Text(
                  'swipe up',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.white38),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.public,
                size: 64, color: Colors.white.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text('Nothing on this mesh yet',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              _meshCount > 0
                  ? '$_meshCount ${_meshCount == 1 ? 'person is' : 'people are'} '
                      'reachable right now. Post a song, a photo, something '
                      'happening nearby — it spreads device-to-device and '
                      'travels with people as they move.'
                  : 'No one is in range right now. Anything you post rides '
                      'along with you and lands on the next mesh you walk '
                      'into.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _openComposer,
              icon: const Icon(Icons.podcasts, size: 18),
              label: const Text('Post the first thing'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF05070A),
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('Network'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.hub, size: 13, color: Colors.white70),
                    const SizedBox(width: 5),
                    Text(
                      '$_meshCount in mesh',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _posts.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _openComposer,
              icon: const Icon(Icons.podcasts),
              label: const Text('Post'),
            ),
      body: Stack(
        children: [
          Positioned.fill(
            child: _posts.isEmpty
                ? _emptyState(theme)
                : PageView.builder(
                    controller: _pager,
                    scrollDirection: Axis.vertical,
                    itemCount: _posts.length,
                    itemBuilder: (context, i) => _postPage(_posts[i], theme),
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: kToolbarHeight),
                child: Column(
                  children: [
                    const TransportStatusBanner(),
                    const SizedBox(height: 4),
                    _activityTicker(theme),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
