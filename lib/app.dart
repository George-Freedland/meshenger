import 'package:flutter/material.dart';

import 'features/calls/call_overlay.dart';
import 'features/shared/in_app_banner_overlay.dart';
import 'routing/app_router.dart';

/// Horizontal slide used on every platform. Defined locally so we do not
/// depend on [CupertinoPageTransitionsBuilder], which Flutter 3.44 moved
/// out of material.dart and is easy to miss on Windows compiles.
class _SlidePageTransitionsBuilder extends PageTransitionsBuilder {
  const _SlidePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return SlideTransition(
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.3, 0),
      ).animate(CurvedAnimation(
        parent: secondaryAnimation,
        curve: Curves.fastEaseInToSlowEaseOut,
      )),
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.fastEaseInToSlowEaseOut)),
        ),
        child: child,
      ),
    );
  }
}

const _slideTransitions = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: _SlidePageTransitionsBuilder(),
    TargetPlatform.iOS: _SlidePageTransitionsBuilder(),
    TargetPlatform.macOS: _SlidePageTransitionsBuilder(),
    TargetPlatform.windows: _SlidePageTransitionsBuilder(),
    TargetPlatform.linux: _SlidePageTransitionsBuilder(),
    TargetPlatform.fuchsia: _SlidePageTransitionsBuilder(),
  },
);

class MeshengerApp extends StatelessWidget {
  const MeshengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Meshenger',
      routerConfig: appRouter,
      builder: (context, child) => CallOverlay(
        child: InAppBannerOverlay(child: child ?? const SizedBox.shrink()),
      ),
      theme: ThemeData.dark().copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.tealAccent,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF05070A),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        pageTransitionsTheme: _slideTransitions,
      ),
    );
  }
}
