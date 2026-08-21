import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/peer_directory.dart';
import '../../core/services/transport_settings.dart';
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
      _direct = MessengerService.instance.onlinePeers;
      _rssi = MessengerService.instance.peerSignal;
      _known = known;
      _contacts = contacts;
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

  bool _isContact(String address) =>
      _contacts.any((c) => c.address == address);

  /// Mesh-known peers that are not directly in range right now.
  List<KnownPeer> get _relayed =>
      _known.where((p) => !_direct.contains(p.address)).toList();

  Future<void> _showPeerActions(String address, {int? hops}) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.circle,
                size: 12,
                color: _direct.contains(address)
                    ? Colors.greenAccent
                    : Colors.lightBlueAccent,
              ),
              title: Text(_labelFor(address)),
              subtitle: Text(
                _direct.contains(address)
                    ? '${_short(address)} · direct radio link'
                    : '${_short(address)} · via mesh relay'
                        '${hops != null ? ' ($hops hop${hops == 1 ? '' : 's'})' : ''}',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Message'),
              onTap: () async {
                Navigator.pop(ctx);
                await ChatStorage.instance.ensureChatExists(address);
                if (mounted) {
                  context.push('/chat?peer=${Uri.encodeComponent(address)}');
                }
              },
            ),
            if (!_isContact(address))
              ListTile(
                leading: const Icon(Icons.person_add_alt_1),
                title: const Text('Add as contact'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final known = _known
                      .where((p) => p.address == address)
                      .toList();
                  await ContactsService.instance.upsertContact(Contact(
                    address: address,
                    nickname:
                        known.isEmpty ? null : known.first.nickname,
                  ));
                  await _reload();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Contact added')),
                    );
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 0 (touching) → 1 (edge of range), derived from RSSI when available.
  double _distanceFactor(String address) {
    final rssi = _rssi[address];
    if (rssi == null) return 0.5;
    return ((-rssi - 30) / 60).clamp(0.2, 0.8).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final direct = _direct.toList()..sort();
    final relayed = _relayed;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('Mesh Map'),
      ),
      body: Column(
        children: [
          const TransportStatusBanner(),
          Expanded(
            flex: 3,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth,
                    constraints.maxHeight.clamp(200.0, 600.0));
                final center = Offset(size.width / 2, size.height / 2);
                final maxRadius =
                    min(size.width, size.height) / 2 - 48;

                final positions = <String, Offset>{};
                final relayedSet = <String>{};

                for (var i = 0; i < direct.length; i++) {
                  final angle = -pi / 2 + (2 * pi * i) / max(direct.length, 1);
                  final radius = maxRadius * _distanceFactor(direct[i]);
                  positions[direct[i]] = center +
                      Offset(cos(angle) * radius, sin(angle) * radius);
                }
                for (var i = 0; i < relayed.length; i++) {
                  final peer = relayed[i];
                  final angle =
                      -pi / 2 + pi / 7 + (2 * pi * i) / max(relayed.length, 1);
                  // Mesh-relayed nodes sit on the outer ring.
                  positions[peer.address] = center +
                      Offset(cos(angle) * maxRadius, sin(angle) * maxRadius);
                  relayedSet.add(peer.address);
                }

                return GestureDetector(
                  onTapUp: (details) {
                    for (final entry in positions.entries) {
                      if ((details.localPosition - entry.value).distance <=
                          28) {
                        final known = relayed
                            .where((p) => p.address == entry.key)
                            .toList();
                        _showPeerActions(
                          entry.key,
                          hops: known.isEmpty ? null : known.first.hops,
                        );
                        return;
                      }
                    }
                  },
                  child: CustomPaint(
                    size: size,
                    painter: _MeshPainter(
                      center: center,
                      maxRadius: maxRadius,
                      positions: positions,
                      relayed: relayedSet,
                      labels: {
                        for (final address in positions.keys)
                          address: _labelFor(address),
                      },
                      theme: theme,
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            flex: 2,
            child: (direct.isEmpty && relayed.isEmpty)
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No Meshenger devices in range right now.\n'
                        'Devices appear here automatically, no contact '
                        'exchange needed. Nodes heard through relays show '
                        'up too.\n\n'
                        '${MessengerService.instance.isTransportRunning ? '${MessengerService.instance.mode == TransportMode.bluetooth ? 'Bluetooth' : 'LAN'} transport is running and scanning. For discovery details, open the connection log (Chats → receipt icon).' : 'The transport is not running — see the banner above.'}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      if (direct.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text('In direct radio range',
                              style: theme.textTheme.titleSmall),
                        ),
                        for (final peer in direct)
                          ListTile(
                            leading: const Icon(Icons.circle,
                                size: 12, color: Colors.greenAccent),
                            title: Text(_labelFor(peer)),
                            subtitle: Text(
                              _rssi[peer] != null
                                  ? '${_short(peer)} · signal ${_rssi[peer]} dBm'
                                  : _short(peer),
                            ),
                            trailing: _isContact(peer)
                                ? null
                                : const Icon(Icons.person_add_alt_1,
                                    size: 18),
                            onTap: () => _showPeerActions(peer),
                          ),
                      ],
                      if (relayed.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text('Known through the mesh',
                              style: theme.textTheme.titleSmall),
                        ),
                        for (final peer in relayed)
                          ListTile(
                            leading: const Icon(Icons.circle,
                                size: 12, color: Colors.lightBlueAccent),
                            title: Text(_labelFor(peer.address)),
                            subtitle: Text(
                              '${_short(peer.address)} · '
                              '${peer.hops} hop${peer.hops == 1 ? '' : 's'} away',
                            ),
                            trailing: _isContact(peer.address)
                                ? null
                                : const Icon(Icons.person_add_alt_1,
                                    size: 18),
                            onTap: () => _showPeerActions(
                              peer.address,
                              hops: peer.hops,
                            ),
                          ),
                      ],
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
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
}

class _MeshPainter extends CustomPainter {
  final Offset center;
  final double maxRadius;
  final Map<String, Offset> positions;
  final Set<String> relayed;
  final Map<String, String> labels;
  final ThemeData theme;

  _MeshPainter({
    required this.center,
    required this.maxRadius,
    required this.positions,
    required this.relayed,
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

    // Me, in the middle.
    canvas.drawCircle(
      center,
      14,
      Paint()..color = theme.colorScheme.primary,
    );
    _label(canvas, 'You', center + const Offset(0, 22));

    final directPaint = Paint()..color = Colors.greenAccent;
    final directGlow = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.2);
    final relayPaint = Paint()..color = Colors.lightBlueAccent;
    final relayGlow = Paint()
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.2);

    for (final entry in positions.entries) {
      final isRelayed = relayed.contains(entry.key);
      canvas.drawCircle(entry.value, 16, isRelayed ? relayGlow : directGlow);
      canvas.drawCircle(
          entry.value, 10, isRelayed ? relayPaint : directPaint);
      _label(canvas, labels[entry.key] ?? '', entry.value + const Offset(0, 18));
    }
  }

  void _dashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 6.0;
    const gap = 5.0;
    final total = (to - from).distance;
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

  void _label(Canvas canvas, String text, Offset at) {
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
    )..layout(maxWidth: 120);
    painter.paint(canvas, at - Offset(painter.width / 2, 0));
  }

  @override
  bool shouldRepaint(_MeshPainter oldDelegate) =>
      oldDelegate.positions.length != positions.length ||
      oldDelegate.positions.keys.join() != positions.keys.join() ||
      oldDelegate.positions.values.join() != positions.values.join();
}
