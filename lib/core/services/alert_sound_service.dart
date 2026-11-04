import 'dart:io';

import 'package:media_kit/media_kit.dart';

import 'settings_service.dart';

/// Built-in notification tones shipped with the app.
enum AlertTone {
  ping,
  chime,
  pulse,
  spark;

  String get asset => 'assets/sounds/$name.wav';

  String get label => switch (this) {
        AlertTone.ping => 'Ping',
        AlertTone.chime => 'Chime',
        AlertTone.pulse => 'Pulse',
        AlertTone.spark => 'Spark',
      };

  String get blurb => switch (this) {
        AlertTone.ping => 'Two bright notes',
        AlertTone.chime => 'Rising triad',
        AlertTone.pulse => 'Soft low then high',
        AlertTone.spark => 'Short sparkle',
      };

  static AlertTone fromName(String? raw) =>
      AlertTone.values.asNameMap()[raw] ?? AlertTone.ping;
}

/// Plays the user's chosen message tone. Used for in-app alerts on every
/// client (iOS, Android, macOS, Windows, Linux). The Pi gateway has no UI
/// and never loads this.
class AlertSoundService {
  AlertSoundService._();
  static final AlertSoundService instance = AlertSoundService._();

  // Created on the first sound, so muted devices never start a player.
  Player? _player;

  Future<void> play({AlertTone? tone, bool ignoreMute = false}) async {
    if (!ignoreMute && !await SettingsService.instance.getSoundEnabled()) {
      return;
    }
    // Unit tests run without the player's native library.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    final chosen =
        tone ?? AlertTone.fromName(await SettingsService.instance.getAlertToneName());
    try {
      final player = _player ??= Player();
      await player.open(Media('asset:///${chosen.asset}'));
    } catch (_) {
      // Sound is best-effort; never block message handling.
    }
  }
}
