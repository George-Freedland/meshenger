import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const _allowAnyoneKey = 'allow_messages_from_anyone_v1';
  static const _autoDeleteKey = 'auto_delete_seconds_v1';

  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  /// When false, incoming messages from addresses not in the contact list
  /// are discarded. Defaults to true (accept messages from anyone).
  Future<bool> getAllowMessagesFromAnyone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(IdentityScope.key(_allowAnyoneKey)) ?? true;
  }

  Future<void> setAllowMessagesFromAnyone(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(IdentityScope.key(_allowAnyoneKey), value);
    _changed.add(null);
  }

  /// Auto-delete timer for messages, in seconds. 0 = off (default).
  /// Applies to new messages: sent messages carry the TTL to the receiver
  /// (Telegram-style), and received messages are also capped by this value.
  Future<int> getAutoDeleteSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(IdentityScope.key(_autoDeleteKey)) ?? 0;
  }

  Future<void> setAutoDeleteSeconds(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(IdentityScope.key(_autoDeleteKey), seconds);
    _changed.add(null);
  }

  static const _relayKey = 'relay_enabled_v1';

  /// When true (default), this device stores and forwards encrypted
  /// envelopes for other people — it acts as a mesh amplifier. The
  /// content is never readable here; only routing headers are.
  Future<bool> getRelayEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(IdentityScope.key(_relayKey)) ?? true;
  }

  Future<void> setRelayEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(IdentityScope.key(_relayKey), value);
    _changed.add(null);
  }

  static const _soundEnabledKey = 'alert_sound_enabled_v1';
  static const _soundToneKey = 'alert_sound_tone_v1';

  /// In-app (and desktop) message tone. Default on.
  Future<bool> getSoundEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(IdentityScope.key(_soundEnabledKey)) ?? true;
  }

  Future<void> setSoundEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(IdentityScope.key(_soundEnabledKey), value);
    _changed.add(null);
  }

  Future<String> getAlertToneName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(IdentityScope.key(_soundToneKey)) ?? 'ping';
  }

  Future<void> setAlertToneName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(IdentityScope.key(_soundToneKey), name);
    _changed.add(null);
  }
}
