import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/contact.dart';
import '../../core/services/chat_storage.dart';
import '../../core/services/contacts_service.dart';
import '../../core/services/messenger_service.dart';

/// Live map of the mesh as seen from this device: every Meshenger node in
/// direct radio range (contact or not), with approximate distance from
/// Bluetooth signal strength. Tap a node to message it or save it as a
/// contact — no public key exchange needed, discovery is automatic.
class MeshMapScreen extends StatefulWidget {
  const MeshMapScreen({super.key});

  @override
  State<MeshMapScreen> createState() => _MeshMapScreenState();
}

class _MeshMapScreenState extends State<MeshMapScreen> {
  Set<String> _peers = const <String>{};
  Map<String, int> _rssi = const <String, int>{};
  List<Contact> _contacts = const <Contact>[];
  StreamSubscription<Set<String>>? _peersSub;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _reload();
    _peersSub =
        MessengerService.instance.onPeersChanged.listen((_) => _reload());
    _refreshTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _reload());
  }

  @override
  void dispose() {
    _peersSub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    final contacts = await ContactsService.instance.listContacts();
    if (!mounted) return;
    setState(() {
      _peers = MessengerService.instance.onlinePeers;
      _rssi = MessengerService.instance.peerSignal;
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
    return _short(address);
  }

  bool _isContact(String address) =>
      _contacts.any((c) => c.address == address);

  Future<void> _showPeerActions(String address) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.circle,
                  size: 12, color: Colors.greenAccent),
              title: Text(_labelFor(address)),
              subtitle: Text(_short(address)),
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
                  await ContactsService.instance
                      .upsertContact(Contact(address: address));
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
    if (rssi == null) return 0.62;
    return ((-rssi - 30) / 60).clamp(0.25, 1.0).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final peers = _peers.toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Mesh Map')),
      body: Column(
        children: [
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
                for (var i = 0; i < peers.length; i++) {
                  final angle = -pi / 2 + (2 * pi * i) / peers.length;
                  final radius =
                      maxRadius * _distanceFactor(peers[i]);
                  positions[peers[i]] = center +
                      Offset(cos(angle) * radius, sin(angle) * radius);
                }

                return GestureDetector(
                  onTapUp: (details) {
                    for (final entry in positions.entries) {
                      if ((details.localPosition - entry.value).distance <=
                          28) {
                        _showPeerActions(entry.key);
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
                      labels: {
                        for (final p in peers) p: _labelFor(p),
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
            child: peers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No Meshenger devices in range right now.\n'
                        'Devices appear here automatically — no contact '
                        'exchange needed.',
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
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text('Nearby devices',
                            style: theme.textTheme.titleSmall),
                      ),
                      for (final peer in peers)
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
                              : const Icon(Icons.person_add_alt_1, size: 18),
                          onTap: () => _showPeerActions(peer),
                        ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Shows devices in direct radio range. Multi-hop relay '
              'visualization arrives with mesh routing.',
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
  final Map<String, String> labels;
  final ThemeData theme;

  _MeshPainter({
    required this.center,
    required this.maxRadius,
    required this.positions,
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

    final edgePaint = Paint()
      ..strokeWidth = 1.5
      ..color = Colors.greenAccent.withValues(alpha: 0.35);
    for (final position in positions.values) {
      canvas.drawLine(center, position, edgePaint);
    }

    // Me, in the middle.
    canvas.drawCircle(
      center,
      14,
      Paint()..color = theme.colorScheme.primary,
    );
    _label(canvas, 'You', center + const Offset(0, 22));

    final nodePaint = Paint()..color = Colors.greenAccent;
    final glowPaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.2);
    for (final entry in positions.entries) {
      canvas.drawCircle(entry.value, 16, glowPaint);
      canvas.drawCircle(entry.value, 10, nodePaint);
      _label(canvas, labels[entry.key] ?? '', entry.value + const Offset(0, 18));
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
