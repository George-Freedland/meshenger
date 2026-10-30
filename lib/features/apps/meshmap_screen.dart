import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/peer_directory.dart';
import '../shared/rescan_button.dart';
import '../shared/transport_status_banner.dart';

/// Live map of the mesh as seen from this device: nodes in direct radio
/// range (positioned by signal strength) plus nodes known through gossip
/// relayed across the mesh — neighbors of neighbors, Raspberry Pi
/// gateways, and anyone the mesh has heard from recently. Tap any node to
/// message it or save it as a contact; no key exchange needed.
class MeshMapScreen extends StatefulWidget {
  const MeshMapScreen({super.key});

  @override
  State<MeshMapScreen> createState() => _MeshMapScreenState();
}

class _MeshMapScreenState extends State<MeshMapScreen> {
  Set<String> _direct = const <String>{};
  Map<String, int> _rssi = const <String, int>{};
  List<KnownPeer> _known = const <KnownPeer>[];
  List<Contact> _contacts = const <Contact>[];
  StreamSubscription<Set<String>>? _peersSub;
  StreamSubscription<void>? _directorySub;
  Timer? _refreshTimer;

  String? _selected;
  bool _listExpanded = true;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _reload();
    _peersSub =
        MessengerService.instance.onPeersChanged.listen((_) => _reload());
    _directorySub =
        PeerDirectory.instance.onChanged.listen((_) => _reload());
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _reload());
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    _directorySub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final contacts = await ContactsService.instance.listContacts();
    final known = await PeerDirectory.instance.listRecent();
    if (!mounted) return;
    setState(() {
      _direct = MessengerService.instance.visiblePeers;
      _rssi = MessengerService.instance.peerSignal;
      _known = known;
      _contacts = contacts;
      if (_selected != null &&
          !_direct.contains(_selected) &&
          !_known.any((p) => p.address == _selected)) {
        _selected = null;
      }
    });
  }

  String _short(String address) {
    if (address.length <= 14) return address;
    return '${address.substring(0, 6)}…${address.substring(address.length - 4)}';
  }

  String _labelFor(String address) {
    for (final c in _contacts) {
      if (c.address == address &&
          c.nickname != null &&
          c.nickname!.trim().isNotEmpty) {
        return c.nickname!;
      }
    }
    for (final peer in _known) {
      if (peer.address == address &&
          peer.nickname != null &&
          peer.nickname!.trim().isNotEmpty) {
        return peer.nickname!;
      }
    }
    return _short(address);
  }

  String get _youLabel {
    final nick = IdentityService.instance.active?.nickname?.trim();
    if (nick == null || nick.isEmpty) return 'You';
    return 'You ($nick)';
  }

  bool _isContact(String address) =>
      _contacts.any((c) => c.address == address);

  KnownPeer? _knownFor(String address) {
    for (final peer in _known) {
      if (peer.address == address) return peer;
    }
    return null;
  }

  /// Mesh-known peers that are not directly in range right now.
  List<KnownPeer> get _relayed =>
      _known.where((p) => !_direct.contains(p.address)).toList();

  bool get _isDirectSelected =>
      _selected != null && _direct.contains(_selected);

  String _lastSeenLabel(String address) {
    if (_direct.contains(address)) return 'in range now';
    final seenMs = _knownFor(address)?.lastSeenMs ?? 0;
    if (seenMs <= 0) return 'last seen unknown';
    final elapsed =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(seenMs));
    if (elapsed.inSeconds < 15) return 'last seen just now';
    if (elapsed.inSeconds < 60) {
      return 'last seen ${elapsed.inSeconds} seconds ago';
    }
    if (elapsed.inMinutes == 1) return 'last seen 1 minute ago';
    if (elapsed.inMinutes < 60) {
      return 'last seen ${elapsed.inMinutes} minutes ago';
    }
    if (elapsed.inHours == 1) return 'last seen 1 hour ago';
    if (elapsed.inHours < 24) {
      return 'last seen ${elapsed.inHours} hours ago';
    }
    if (elapsed.inDays == 1) return 'last seen 1 day ago';
    return 'last seen ${elapsed.inDays} days ago';
  }

  String _routeLabel(String address) {
    if (_direct.contains(address)) return 'direct radio link';
    final hops = _knownFor(address)?.hops;
    if (hops == null || hops == 0) return 'last seen nearby';
    return 'via mesh relay ($hops hop${hops == 1 ? '' : 's'})';
  }

  void _select(String address) {
    setState(() {
      _selected = _selected == address ? null : address;
    });
  }

  Future<void> _message(String address) async {
    await ChatStorage.instance.ensureChatExists(address);
    if (mounted) {
      context.push('/chat?peer=${Uri.encodeComponent(address)}');
    }
  }

  Future<void> _addContact(String address) async {
    await ContactsService.instance.upsertContact(Contact(
      address: address,
      nickname: _knownFor(address)?.nickname,
    ));
    await _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Contact added')),
      );
    }
  }

  Future<void> _confirmClearMesh() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear mesh data?'),
        content: const Text(
          'This forgets every device this identity has seen on the map, '
          'including encryption keys learned through gossip. Contacts and '
          'chats stay. Devices still in range will reappear on the next scan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _clearing = true);
    await MessengerService.instance.clearMeshSightings();
    if (!mounted) return;
    setState(() {
      _selected = null;
      _clearing = false;
    });
    await _reload();
  }

  /// 0 (touching) → 1 (edge of range), derived from RSSI when available.
  double _distanceFactor(String address) {
    final rssi = _rssi[address];
    if (rssi == null) return 0.5;
    return ((-rssi - 30) / 60).clamp(0.2, 0.8).toDouble();
  }

  Offset _detailsOrigin(Offset node, Size size, {required double width}) {
    final preferRight = node.dx < size.width * 0.55;
    final dx = preferRight
        ? (node.dx + 22).clamp(8.0, max(8.0, size.width - width - 8))
        : (node.dx - width - 22).clamp(8.0, max(8.0, size.width - width - 8));
    final dy = (node.dy - 48).clamp(8.0, max(8.0, size.height - 200));
    return Offset(dx.toDouble(), dy.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final direct = _direct.toList()..sort();
    final relayed = _relayed;
    final deviceCount = direct.length + relayed.length;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('Mesh Map'),
        actions: [
          const RescanButton(),
          IconButton(
            tooltip: 'Clear mesh data',
            onPressed: _clearing ? null : _confirmClearMesh,
            icon: _clearing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.filter_center_focus),
          ),
        ],
      ),
      body: Column(
        children: [
          const TransportStatusBanner(),
          Expanded(child: _buildMap(theme, direct, relayed)),
          const Divider(height: 1),
          _buildListHeader(theme, deviceCount),
          if (_listExpanded) _buildDeviceList(theme, direct, relayed),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Text(
              'Green: direct radio link. Blue: heard through relays. '
              'messages to them ride the mesh from device to device.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap(
    ThemeData theme,
    List<String> direct,
    List<KnownPeer> relayed,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final center = Offset(size.width / 2, size.height / 2);
        final maxRadius = min(size.width, size.height) / 2 - 48;

        final positions = <String, Offset>{};
        final relayedSet = <String>{};

        for (var i = 0; i < direct.length; i++) {
          final angle = -pi / 2 + (2 * pi * i) / max(direct.length, 1);
          final radius = maxRadius * _distanceFactor(direct[i]);
          positions[direct[i]] =
              center + Offset(cos(angle) * radius, sin(angle) * radius);
        }
        for (var i = 0; i < relayed.length; i++) {
          final peer = relayed[i];
          final angle =
              -pi / 2 + pi / 7 + (2 * pi * i) / max(relayed.length, 1);
          positions[peer.address] =
              center + Offset(cos(angle) * maxRadius, sin(angle) * maxRadius);
          relayedSet.add(peer.address);
        }

        final selected = _selected;
        final selectedPos = selected == null ? null : positions[selected];

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  for (final entry in positions.entries) {
                    if ((details.localPosition - entry.value).distance <= 28) {
                      _select(entry.key);
                      return;
                    }
                  }
                  if (_selected != null) {
                    setState(() => _selected = null);
                  }
                },
                child: CustomPaint(
                  size: size,
                  painter: _MeshPainter(
                    center: center,
                    maxRadius: maxRadius,
                    positions: positions,
                    relayed: relayedSet,
                    selected: selected,
                    youLabel: _youLabel,
                    labels: {
                      for (final address in positions.keys)
                        address: _labelFor(address),
                    },
                    theme: theme,
                  ),
                ),
              ),
            ),
            if (selected != null && selectedPos != null)
              Positioned(
                left: _detailsOrigin(selectedPos, size, width: 268).dx,
                top: _detailsOrigin(selectedPos, size, width: 268).dy,
                child: _PeerDetailsCard(
                  title: _labelFor(selected),
                  address: _short(selected),
                  route: _routeLabel(selected),
                  lastSeen: _lastSeenLabel(selected),
                  signal: _rssi[selected],
                  isDirect: _isDirectSelected,
                  isContact: _isContact(selected),
                  onClose: () => setState(() => _selected = null),
                  onMessage: () => _message(selected),
                  onAddContact: () => _addContact(selected),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildListHeader(ThemeData theme, int deviceCount) {
    return Material(
      color: theme.colorScheme.surface,
      child: InkWell(
        onTap: () => setState(() => _listExpanded = !_listExpanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  deviceCount == 0
                      ? 'No devices nearby'
                      : '$deviceCount device${deviceCount == 1 ? '' : 's'}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Text(
                _listExpanded ? 'Hide list' : 'Show list',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              ),
              Icon(
                _listExpanded ? Icons.expand_more : Icons.expand_less,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceList(
    ThemeData theme,
    List<String> direct,
    List<KnownPeer> relayed,
  ) {
    if (direct.isEmpty && relayed.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Text(
          'No Meshenger devices in range right now.\n'
          'Devices appear here automatically, no contact '
          'exchange needed. Nodes heard through relays show '
          'up too.\n\n'
          '${MessengerService.instance.isTransportRunning ? 'Bluetooth transport is running and scanning. For discovery details, open the connection log (Chats → receipt icon).' : 'The transport is not running — see the banner above.'}',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: ListView(
        shrinkWrap: true,
        children: [
          if (direct.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text('In direct radio range',
                  style: theme.textTheme.titleSmall),
            ),
            for (final peer in direct)
              _deviceTile(
                address: peer,
                color: Colors.greenAccent,
                subtitle:
                    '${_short(peer)} · ${_lastSeenLabel(peer)}'
                    '${_rssi[peer] != null ? ' · ${_rssi[peer]} dBm' : ''}',
              ),
          ],
          if (relayed.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Known through the mesh',
                  style: theme.textTheme.titleSmall),
            ),
            for (final peer in relayed)
              _deviceTile(
                address: peer.address,
                color: Colors.lightBlueAccent,
                subtitle:
                    '${_short(peer.address)} · ${_routeLabel(peer.address)} · '
                    '${_lastSeenLabel(peer.address)}',
              ),
          ],
        ],
      ),
    );
  }

  Widget _deviceTile({
    required String address,
    required Color color,
    required String subtitle,
  }) {
    final selected = _selected == address;
    return ListTile(
      selected: selected,
      leading: Icon(Icons.circle, size: 12, color: color),
      title: Text(_labelFor(address)),
      subtitle: Text(subtitle),
      trailing: _isContact(address)
          ? null
          : const Icon(Icons.person_add_alt_1, size: 18),
      onTap: () => _select(address),
    );
  }
}

class _PeerDetailsCard extends StatelessWidget {
  final String title;
  final String address;
  final String route;
  final String lastSeen;
  final int? signal;
  final bool isDirect;
  final bool isContact;
  final VoidCallback onClose;
  final VoidCallback onMessage;
  final VoidCallback onAddContact;

  const _PeerDetailsCard({
    required this.title,
    required this.address,
    required this.route,
    required this.lastSeen,
    required this.signal,
    required this.isDirect,
    required this.isContact,
    required this.onClose,
    required this.onMessage,
    required this.onAddContact,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = isDirect ? Colors.greenAccent : Colors.lightBlueAccent;
    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: 268,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.circle, size: 10, color: accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title, style: theme.textTheme.titleSmall),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose,
                  ),
                ],
              ),
              Text(
                address,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 6),
              Text(route, style: theme.textTheme.bodySmall),
              Text(
                lastSeen,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              if (signal != null)
                Text(
                  'signal $signal dBm',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: onMessage,
                    icon: const Icon(Icons.chat_bubble_outline, size: 16),
                    label: const Text('Message'),
                  ),
                  if (!isContact)
                    TextButton.icon(
                      onPressed: onAddContact,
                      icon: const Icon(Icons.person_add_alt_1, size: 16),
                      label: const Text('Add contact'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MeshPainter extends CustomPainter {
  final Offset center;
  final double maxRadius;
  final Map<String, Offset> positions;
  final Set<String> relayed;
  final String? selected;
  final String youLabel;
  final Map<String, String> labels;
  final ThemeData theme;

  _MeshPainter({
    required this.center,
    required this.maxRadius,
    required this.positions,
    required this.relayed,
    required this.selected,
    required this.youLabel,
    required this.labels,
    required this.theme,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = theme.colorScheme.onSurface.withValues(alpha: 0.08);
    for (final factor in [0.33, 0.66, 1.0]) {
      canvas.drawCircle(center, maxRadius * factor, ringPaint);
    }

    final directEdge = Paint()
      ..strokeWidth = 1.5
      ..color = Colors.greenAccent.withValues(alpha: 0.35);
    final relayEdge = Paint()
      ..strokeWidth = 1.2
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.3);

    for (final entry in positions.entries) {
      if (relayed.contains(entry.key)) {
        _dashedLine(canvas, center, entry.value, relayEdge);
      } else {
        canvas.drawLine(center, entry.value, directEdge);
      }
    }

    canvas.drawCircle(
      center,
      14,
      Paint()..color = theme.colorScheme.primary,
    );
    _label(canvas, youLabel, center + const Offset(0, 22), maxWidth: 160);

    final directPaint = Paint()..color = Colors.greenAccent;
    final directGlow = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.2);
    final relayPaint = Paint()..color = Colors.lightBlueAccent;
    final relayGlow = Paint()
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.2);
    final selectedGlow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = theme.colorScheme.onSurface.withValues(alpha: 0.85);

    for (final entry in positions.entries) {
      final isRelayed = relayed.contains(entry.key);
      canvas.drawCircle(entry.value, 16, isRelayed ? relayGlow : directGlow);
      canvas.drawCircle(
          entry.value, 10, isRelayed ? relayPaint : directPaint);
      if (entry.key == selected) {
        canvas.drawCircle(entry.value, 18, selectedGlow);
      }
      _label(canvas, labels[entry.key] ?? '', entry.value + const Offset(0, 18));
    }
  }

  void _dashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 6.0;
    const gap = 5.0;
    final total = (to - from).distance;
    if (total == 0) return;
    final direction = (to - from) / total;
    var traveled = 0.0;
    while (traveled < total) {
      final end = min(traveled + dash, total);
      canvas.drawLine(
        from + direction * traveled,
        from + direction * end,
        paint,
      );
      traveled = end + gap;
    }
  }

  void _label(Canvas canvas, String text, Offset at, {double maxWidth = 120}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 11,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, at - Offset(painter.width / 2, 0));
  }

  @override
  bool shouldRepaint(_MeshPainter oldDelegate) =>
      oldDelegate.positions.length != positions.length ||
      oldDelegate.positions.keys.join() != positions.keys.join() ||
      oldDelegate.positions.values.join() != positions.values.join() ||
      oldDelegate.selected != selected ||
      oldDelegate.youLabel != youLabel;
}
