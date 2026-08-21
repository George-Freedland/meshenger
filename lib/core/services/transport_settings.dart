import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

/// Which local transport carries messages.
enum TransportMode {
  /// Bluetooth LE: works with no network infrastructure at all. Default.
  bluetooth,

  /// LAN: same Wi-Fi network or hotspot (UDP discovery + TCP delivery).
  lan,
}

class TransportSettings {
  TransportSettings._();
  static final TransportSettings instance = TransportSettings._();

  static const _modeKey = 'transport_mode_v1';

  Future<TransportMode> getMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_modeKey));
    return TransportMode.values.asNameMap()[raw] ?? TransportMode.bluetooth;
  }

  Future<void> setMode(TransportMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(IdentityScope.key(_modeKey), mode.name);
  }
}
