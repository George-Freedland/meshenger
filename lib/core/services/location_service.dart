import 'dart:async';
import 'dart:math';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

/// A place on Earth, as a device shares it on the Mesh Map.
class GeoPoint {
  final double lat;
  final double lon;

  /// How far off it may be, in meters.
  final int accuracyM;
  final int tsMs;

  const GeoPoint({
    required this.lat,
    required this.lon,
    required this.accuracyM,
    required this.tsMs,
  });

  /// The about-1 km grid cell this point is in. Always the same cell for
  /// the same spot, so repeated reports give nothing more away.
  GeoPoint approximate() => GeoPoint(
        lat: _snap(lat),
        lon: _snap(lon),
        accuracyM: max(LocationService.approximateAccuracyM, accuracyM),
        tsMs: tsMs,
      );

  static double _snap(double degrees) => (degrees * 100).round() / 100;

  /// `lat,lon,accuracy,time`: the form that is signed and sent.
  String encode() => '${lat.toStringAsFixed(5)},${lon.toStringAsFixed(5)},'
      '$accuracyM,$tsMs';

  static GeoPoint? decode(String value) {
    final parts = value.split(',');
    if (parts.length != 4) return null;
    final lat = double.tryParse(parts[0]);
    final lon = double.tryParse(parts[1]);
    final accuracy = int.tryParse(parts[2]);
    final ts = int.tryParse(parts[3]);
    if (lat == null || lon == null || accuracy == null || ts == null) {
      return null;
    }
    if (lat.abs() > 90 || lon.abs() > 180 || accuracy < 0) return null;
    return GeoPoint(lat: lat, lon: lon, accuracyM: accuracy, tsMs: ts);
  }

  Map<String, Object?> toJson() =>
      <String, Object?>{'lat': lat, 'lon': lon, 'acc': accuracyM, 'ts': tsMs};

  static GeoPoint? fromJson(Object? json) {
    if (json is! Map) return null;
    final lat = json['lat'];
    final lon = json['lon'];
    if (lat is! num || lon is! num) return null;
    return GeoPoint(
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      accuracyM: (json['acc'] as num?)?.toInt() ?? 0,
      tsMs: (json['ts'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Where this device is, for the Mesh Map globe, and how much of that it
/// shares. Both sharing settings are off until the person turns one on;
/// until then the device's location is never even read.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  static const int approximateAccuracyM = 1000;

  /// Locations older than this are left off the globe.
  static const Duration maxAge = Duration(hours: 24);

  /// How often a fresh position is read while sharing is on.
  static const Duration refreshEvery = Duration(minutes: 2);

  static const _approxKey = 'location_share_approx_v1';
  static const _exactKey = 'location_share_exact_v1';
  static const _pinKey = 'location_pin_v1';

  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  GeoPoint? _fix;
  Future<GeoPoint?>? _reading;

  Future<bool> getShareApproximate() async =>
      (await SharedPreferences.getInstance())
          .getBool(IdentityScope.key(_approxKey)) ??
      false;

  Future<bool> getShareExact() async =>
      (await SharedPreferences.getInstance())
          .getBool(IdentityScope.key(_exactKey)) ??
      false;

  Future<void> setShareApproximate(bool value) async {
    await (await SharedPreferences.getInstance())
        .setBool(IdentityScope.key(_approxKey), value);
    _changed.add(null);
  }

  Future<void> setShareExact(bool value) async {
    await (await SharedPreferences.getInstance())
        .setBool(IdentityScope.key(_exactKey), value);
    _changed.add(null);
  }

  Future<bool> get isSharing async =>
      await getShareExact() || await getShareApproximate();

  /// A spot the person placed on the globe themselves (laptops rarely know
  /// where they are offline). Used instead of the device's own reading.
  Future<GeoPoint?> getPin() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_pinKey));
    return raw == null ? null : GeoPoint.decode(raw);
  }

  Future<void> setPin(GeoPoint? pin) async {
    final prefs = await SharedPreferences.getInstance();
    if (pin == null) {
      await prefs.remove(IdentityScope.key(_pinKey));
    } else {
      await prefs.setString(IdentityScope.key(_pinKey), pin.encode());
    }
    _changed.add(null);
  }

  /// This device's spot: the pin if there is one, otherwise the latest
  /// reading — taken only while sharing is on. Never waits for a new
  /// reading (that can take many seconds); a stale one is refreshed in
  /// the background.
  Future<GeoPoint?> myPosition() async {
    final pin = await getPin();
    if (pin != null) return pin;
    if (!await isSharing) return null;
    final fix = _fix;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (fix == null || now - fix.tsMs >= refreshEvery.inMilliseconds) {
      unawaited(_read(askPermission: false));
    }
    return fix;
  }

  /// What this device puts in its gossip: nothing, its about-1 km cell, or
  /// its exact spot.
  Future<GeoPoint?> sharedPosition() async {
    final exact = await getShareExact();
    if (!exact && !await getShareApproximate()) return null;
    final position = await myPosition();
    if (position == null) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final current = GeoPoint(
      lat: position.lat,
      lon: position.lon,
      accuracyM: position.accuracyM,
      tsMs: now,
    );
    return exact ? current : current.approximate();
  }

  /// Asks for location access (when a sharing setting is turned on) and
  /// takes a first reading. Returns what went wrong, for the person.
  Future<String?> requestAccess() async {
    if (await getPin() != null) return null;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return 'Location services are off on this device. Turn them on, '
            'or long-press the globe on the Mesh Map to pin your spot.';
      }
    } catch (_) {
      return "This device can't report its location. Long-press the globe "
          'on the Mesh Map to pin your spot.';
    }
    final position = await _read(askPermission: true);
    if (position != null) return null;
    return "Couldn't find this device's location (laptops often can't "
        'without internet). Long-press the globe on the Mesh Map to pin '
        'your spot.';
  }

  Future<GeoPoint?> _read({required bool askPermission}) =>
      _reading ??= _readNow(askPermission).whenComplete(() => _reading = null);

  Future<GeoPoint?> _readNow(bool askPermission) async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && askPermission) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever ||
          permission == LocationPermission.unableToDetermine) {
        return null;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      final fix = GeoPoint(
        lat: position.latitude,
        lon: position.longitude,
        accuracyM: position.accuracy.round(),
        tsMs: DateTime.now().millisecondsSinceEpoch,
      );
      _fix = fix;
      _changed.add(null);
      return fix;
    } catch (_) {
      return null;
    }
  }

  /// Forgets the in-memory reading (on identity switch or log out).
  void reset() => _fix = null;
}
