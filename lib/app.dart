import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'features/calls/call_overlay.dart';
import 'routing/app_router.dart';

class MeshengerApp extends StatelessWidget {
  const MeshengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Meshenger',
      routerConfig: appRouter,
      builder: (context, child) =>
          CallOverlay(child: child ?? const SizedBox.shrink()),
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.tealAccent,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF05070A),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        // iOS-style horizontal slide: forward pushes slide in from the
        // right, back pops slide out to the right on every platform.
        pageTransitionsTheme: PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
            TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
            TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
    );
  }
}
