import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  SettingsService._();
  static final SettingsService instance = SettingsService._();

  static const _allowAnyoneKey = 'allow_messages_from_anyone_v1';

  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  /// When false, incoming messages from addresses not in the contact list
  /// are discarded. Defaults to true (accept messages from anyone).
  Future<bool> getAllowMessagesFromAnyone() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_allowAnyoneKey) ?? true;
  }

  Future<void> setAllowMessagesFromAnyone(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowAnyoneKey, value);
    _changed.add(null);
  }
}
