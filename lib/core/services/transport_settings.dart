import 'package:shared_preferences/shared_preferences.dart';

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
    final raw = prefs.getString(_modeKey);
    return TransportMode.values.asNameMap()[raw] ?? TransportMode.bluetooth;
  }

  Future<void> setMode(TransportMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, mode.name);
  }
}
