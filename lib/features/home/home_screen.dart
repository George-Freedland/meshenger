import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/chat_storage.dart';
import '../../core/services/home_layout.dart';
import '../../core/services/identity_service.dart';
import '../../core/services/messenger_service.dart';
import '../../core/services/network_service.dart';
import '../../core/ui/avatars.dart';
import 'app_registry.dart';
import 'springboard.dart';

/// iPhone-style launcher shown after unlock: hold an icon to enter jiggle
/// mode, drag to rearrange, drop one icon onto another to group them.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final HomeLayoutController _layout = HomeLayoutController();
  final ValueNotifier<bool> _editing = ValueNotifier<bool>(false);
  final ValueNotifier<Map<String, int>> _badges =
      ValueNotifier<Map<String, int>>(const {});

  final List<StreamSubscription<dynamic>> _subs = [];

  @override
  void initState() {
    super.initState();
    _layout.load(defaultAppOrder);
    _refreshBadges();
    _subs.add(
        MessengerService.instance.onChanged.listen((_) => _refreshBadges()));
    _subs.add(
        NetworkService.instance.onChanged.listen((_) => _refreshBadges()));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _editing.dispose();
    _badges.dispose();
    _layout.dispose();
    super.dispose();
  }

  Future<void> _refreshBadges() async {
    final unread = await ChatStorage.instance.totalUnread();
    final me = await IdentityService.instance.getPublicAddressBase64();
    final unseenPosts = await NetworkService.instance.unseenCount(me);
    if (mounted) {
      _badges.value = {'messages': unread, 'network': unseenPosts};
    }
  }

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

  void _openApp(AppDefinition app) => context.push(app.route);

  void _openFolder(HomeFolderItem folder) {
    showFolderOverlay(
      context,
      controller: _layout,
      folderId: folder.id,
      editing: _editing,
      onEnterEdit: () => _editing.value = true,
      badges: _badges,
      onOpenApp: _openApp,
      onFolderCreated: (created) =>
          promptNameForNewFolder(context, _layout, created),
    );
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
                    ValueListenableBuilder<bool>(
                      valueListenable: _editing,
                      builder: (context, editing, _) => editing
                          ? FilledButton.tonal(
                              onPressed: () => _editing.value = false,
                              child: const Text('Done'),
                            )
                          : IconButton(
                              tooltip: 'Log out',
                              icon: const Icon(Icons.logout),
                              onPressed: () => _logout(context),
                            ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    // Tapping empty wallpaper leaves jiggle mode, like iOS.
                    onTap: () {
                      if (_editing.value) _editing.value = false;
                    },
                    child: ListenableBuilder(
                      listenable: _layout,
                      builder: (context, _) {
                        if (!_layout.isLoaded) {
                          return const Center(
                              child: CircularProgressIndicator());
                        }
                        return SingleChildScrollView(
                          child: Springboard(
                            controller: _layout,
                            editing: _editing,
                            onEnterEdit: () => _editing.value = true,
                            badges: _badges,
                            onOpenApp: _openApp,
                            onOpenFolder: _openFolder,
                            onFolderCreated: (created) =>
                                promptNameForNewFolder(
                                    context, _layout, created),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _editing,
                  builder: (context, editing, _) => AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: editing
                        ? Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Center(
                              child: Text(
                                'Drag icons to rearrange · drop one onto '
                                'another to make a group',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
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
