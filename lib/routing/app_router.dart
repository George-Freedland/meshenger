import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/services/safety_service.dart';
import '../features/apps/appstore_screen.dart';
import '../features/apps/camera_screen.dart';
import '../features/apps/contacts_screen.dart';
import '../features/apps/meshmap_screen.dart';
import '../features/apps/memos_screen.dart';
import '../features/apps/network_screen.dart';
import '../features/apps/settings_screen.dart';
import '../features/apps/storage_screen.dart';
import '../features/chat/call_history_screen.dart';
import '../features/chat/chat_list_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/home/home_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/onboarding/terms_screen.dart';

/// Root navigator key, shared so global overlays (incoming calls,
/// voicemail prompts) can open dialogs from outside the router tree.
final GlobalKey<NavigatorState> rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'rootNavigator');

final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/',
  redirect: (context, state) async {
    if (state.matchedLocation == '/terms') return null;
    return await SafetyService.instance.termsAccepted() ? null : '/terms';
  },
  routes: <RouteBase>[
    GoRoute(
      path: '/terms',
      builder: (context, state) => const TermsScreen(),
    ),
    GoRoute(
      path: '/',
      name: 'onboarding',
      builder: (context, state) => const OnboardingScreen(),
    ),
    GoRoute(
      path: '/home',
      name: 'home',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/chats',
      name: 'chats',
      builder: (context, state) => const ChatListScreen(),
    ),
    GoRoute(
      path: '/chat',
      name: 'chat',
      builder: (context, state) {
        final peer = state.uri.queryParameters['peer'];
        return ChatScreen(peerAddress: peer);
      },
    ),
    GoRoute(
      path: '/calls',
      builder: (context, state) =>
          CallHistoryScreen(peer: state.uri.queryParameters['peer']),
    ),
    GoRoute(
      path: '/app/contacts',
      builder: (context, state) => const ContactsScreen(),
    ),
    GoRoute(
      path: '/app/camera',
      builder: (context, state) => const CameraScreen(),
    ),
    GoRoute(
      path: '/app/storage',
      builder: (context, state) => const StorageScreen(),
    ),
    GoRoute(
      path: '/app/memos',
      builder: (context, state) => const MemosScreen(),
    ),
    GoRoute(
      path: '/app/meshmap',
      builder: (context, state) => const MeshMapScreen(),
    ),
    GoRoute(
      path: '/app/network',
      builder: (context, state) =>
          NetworkScreen(initialUrl: state.uri.queryParameters['url']),
    ),
    GoRoute(
      path: '/app/store',
      builder: (context, state) => const AppStoreScreen(),
    ),
    GoRoute(
      path: '/app/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
  ],
);
