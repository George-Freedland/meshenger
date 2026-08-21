import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/apps/appstore_screen.dart';
import '../features/apps/camera_screen.dart';
import '../features/apps/facetime_screen.dart';
import '../features/apps/meshmap_screen.dart';
import '../features/apps/memos_screen.dart';
import '../features/apps/phone_screen.dart';
import '../features/apps/settings_screen.dart';
import '../features/apps/storage_screen.dart';
import '../features/apps/stories_screen.dart';
import '../features/chat/chat_list_screen.dart';
import '../features/chat/chat_screen.dart';
import '../features/home/home_screen.dart';
import '../features/onboarding/onboarding_screen.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'rootNavigator');

final GoRouter appRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/',
  routes: <RouteBase>[
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
      path: '/app/phone',
      builder: (context, state) => const PhoneScreen(),
    ),
    GoRoute(
      path: '/app/facetime',
      builder: (context, state) => const FaceTimeScreen(),
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
      path: '/app/stories',
      builder: (context, state) => const StoriesScreen(),
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
