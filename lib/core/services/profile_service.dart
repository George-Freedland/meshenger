import 'package:shared_preferences/shared_preferences.dart';

/// Local, non-sensitive profile settings (nickname, etc.).
class ProfileService {
  ProfileService._();
  static final ProfileService instance = ProfileService._();

  static const _nicknameKey = 'profile_nickname_v1';

  Future<String?> getNickname() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_nicknameKey);
    return (v == null || v.trim().isEmpty) ? null : v.trim();
  }

  Future<void> setNickname(String? nickname) async {
    final prefs = await SharedPreferences.getInstance();
    final v = nickname?.trim() ?? '';
    if (v.isEmpty) {
      await prefs.remove(_nicknameKey);
    } else {
      await prefs.setString(_nicknameKey, v);
    }
  }
}
