import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// System-level (banner) notifications for mesh traffic that arrives while
/// the app is backgrounded — the visible half of push delivery: a relay
/// wakes the phone over BLE, the app decrypts, and this shows the banner.
///
/// Content stays private by design: banners name the sender and the kind of
/// message, never the (end-to-end encrypted) content.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _initAttempted = false;
  int _nextId = 1;

  Future<void> init() async {
    if (_initAttempted || kIsWeb) return;
    _initAttempted = true;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        macOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: WindowsInitializationSettings(
          appName: 'Meshenger',
          appUserModelId: 'com.meshenger.app',
          guid: 'a3b26cd4-1b6e-4d78-9c1f-6f2b3a8e5d01',
        ),
      );
      await _plugin.initialize(settings: settings);

      if (Platform.isAndroid) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      } else if (Platform.isMacOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin>()
            ?.requestPermissions(alert: true, badge: true, sound: true);
      }
      _ready = true;
    } catch (_) {
      // Platform without notification support; the app works fine without.
    }
  }

  bool get _appInForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// Shows a banner unless the app is in the foreground (in-app UI already
  /// surfaces the message there).
  Future<void> notify({required String title, required String body}) async {
    if (!_ready || _appInForeground) return;
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Messages',
          channelDescription:
              'Encrypted messages arriving over the Bluetooth mesh',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
        ),
        iOS: DarwinNotificationDetails(),
        macOS: DarwinNotificationDetails(),
        linux: LinuxNotificationDetails(),
      );
      await _plugin.show(
        id: _nextId++,
        title: title,
        body: body,
        notificationDetails: details,
      );
    } catch (_) {
      // Never let a notification failure disturb message handling.
    }
  }
}
