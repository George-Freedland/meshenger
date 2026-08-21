import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/ui/avatars.dart';

class _AppEntry {
  final String label;
  final IconData icon;
  final Color color;
  final String route;

  const _AppEntry(this.label, this.icon, this.color, this.route);
}

const List<_AppEntry> _apps = [
  _AppEntry('Messages', Icons.chat_bubble, Color(0xFF26A69A), '/chats'),
  _AppEntry('Phone', Icons.phone, Color(0xFF66BB6A), '/app/phone'),
  _AppEntry('FaceTime', Icons.videocam, Color(0xFF29B6F6), '/app/facetime'),
  _AppEntry('Camera', Icons.photo_camera, Color(0xFF78909C), '/app/camera'),
  _AppEntry('Storage', Icons.folder, Color(0xFFFFA726), '/app/storage'),
  _AppEntry('Voice Memos', Icons.mic, Color(0xFFEF5350), '/app/memos'),
  _AppEntry('Mesh Map', Icons.hub, Color(0xFF7C4DFF), '/app/meshmap'),
  _AppEntry('Stories', Icons.auto_awesome, Color(0xFFEC407A), '/app/stories'),
  _AppEntry('App Store', Icons.apps, Color(0xFF5C6BC0), '/app/store'),
  _AppEntry('Settings', Icons.settings, Color(0xFF8D6E63), '/app/settings'),
];

/// iPhone-style launcher shown after unlock.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  Future<void> _logout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'The mesh transport stops and your identity locks. '
          'Your chats stay encrypted on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await MessengerService.instance.stop();
    IdentityService.instance.lock();
    if (context.mounted) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final identity = IdentityService.instance.active;
    final name = identity?.nickname ?? 'there';

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0B1220), Color(0xFF05070A), Color(0xFF0A1512)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    presetAvatar(identity?.avatarId ?? 0, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Hi, $name',
                        style: theme.textTheme.titleLarge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Log out',
                      icon: const Icon(Icons.logout),
                      onPressed: () => _logout(context),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final columns =
                          (constraints.maxWidth / 110).floor().clamp(3, 6);
                      return GridView.count(
                        crossAxisCount: columns,
                        mainAxisSpacing: 18,
                        crossAxisSpacing: 12,
                        children: [
                          for (final app in _apps)
                            InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () => context.push(app.route),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 58,
                                    height: 58,
                                    decoration: BoxDecoration(
                                      color: app.color,
                                      borderRadius: BorderRadius.circular(15),
                                      boxShadow: [
                                        BoxShadow(
                                          color: app.color
                                              .withValues(alpha: 0.35),
                                          blurRadius: 12,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: Icon(app.icon,
                                        color: Colors.white, size: 30),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    app.label,
                                    style: theme.textTheme.labelMedium,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
