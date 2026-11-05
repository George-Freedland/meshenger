import 'dart:async';
import 'dart:io';
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

/// Why this device has no position of its own.
enum LocationProblem {
  /// Location services are switched off for the whole device.
  servicesOff,

  /// The person refused Meshenger access, now or earlier.
  notAllowed,

  /// Nobody has been asked yet (access is only requested from Settings).
  notAsked,

  /// Access is fine, but the device couldn't work out where it is, and
  /// nobody it can hear is sharing one either.
  notFound,
}

/// Where the current reading came from.
enum LocationOrigin {
  /// Measured by this device.
  sensor,

  /// A measurement this device stored earlier.
  remembered,

  /// A device in direct radio range. This device has no position of its
  /// own, so it stands next to one it can hear.
  nearby,
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

  /// This device's own last measurement. Kept so a laptop still knows
  /// where it was after the radios that measured it go quiet.
  static const ownFixKey = 'location_own_fix_v1';

  /// Added to a neighbor's accuracy. Direct radio is tens of meters, not
  /// a GPS point.
  static const int nearbyRadioM = 100;

  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  GeoPoint? _fix;
  LocationOrigin? _origin;
  LocationProblem? _problem;
  bool _looking = false;
  StreamSubscription<Position>? _sensorSub;

  /// The spot a device in direct radio range is sharing, or null. The
  /// messenger installs this. Used when this device cannot measure one
  /// itself: a Mac has no GPS, and with Wi-Fi off it has no other sensor.
  /// Windows Location still answers then, from a position it saved or from
  /// the network; Core Location does not.
  Future<GeoPoint?> Function()? nearbyPosition;

  /// The latest reading of this device's own location.
  GeoPoint? get lastReading => _fix;

  /// How [lastReading] was obtained.
  LocationOrigin? get origin => _origin;

  /// Why the last attempt to read it failed, if it did.
  LocationProblem? get problem => _problem;

  /// A reading is under way.
  bool get isLooking => _looking;

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
    await _afterShareChange();
  }

  Future<void> setShareExact(bool value) async {
    await (await SharedPreferences.getInstance())
        .setBool(IdentityScope.key(_exactKey), value);
    await _afterShareChange();
  }

  Future<void> _afterShareChange() async {
    if (!await isSharing) await _stopSensor();
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

  /// This device's spot: the pin if there is one, otherwise its own
  /// reading, otherwise a device it can hear right now. Taken only while
  /// sharing is on. Never waits on the platform location service.
  Future<GeoPoint?> myPosition() async {
    final pin = await getPin();
    if (pin != null) return pin;
    if (!await isSharing) return null;
    final own = await _ownFix();
    if (own != null) {
      _ensureListening();
      return own;
    }
    final heard = await _heardNearby();
    if (heard != null) {
      _adopt(heard, LocationOrigin.nearby);
      _problem = null;
      _ensureListening();
      return heard;
    }
    if (_origin == LocationOrigin.nearby) {
      _fix = null;
      _origin = null;
      _changed.add(null);
    }
    _ensureListening();
    return null;
  }

  /// Background attempts are at least this far apart (every attempt tells
  /// listeners, which may ask again).
  static const Duration retryEvery = Duration(seconds: 30);
  int _lastAttemptMs = 0;

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

  /// Asks for location access (when a sharing setting is turned on, or the
  /// person taps Try again) and takes a reading. Returns what's in the
  /// way, if anything.
  Future<LocationProblem?> requestAccess() async {
    if (await getPin() != null) return null;
    if (!await isSharing) return LocationProblem.notAsked;
    await _acquire(askPermission: true);
    if (await myPosition() != null) {
      _problem = null;
      return null;
    }
    return _problem ?? LocationProblem.notFound;
  }

  /// What the person can do about [problem].
  static String describe(LocationProblem problem) => switch (problem) {
        LocationProblem.servicesOff =>
          'Location services are off on this device. Turn them on in its '
              'settings, or pin your spot on the globe.',
        LocationProblem.notAllowed =>
          "Meshenger isn't allowed to use this device's location. Allow it "
              "in the device's settings (Privacy & Security → Location "
              'Services), or pin your spot on the globe.',
        LocationProblem.notAsked =>
          'Meshenger still needs your OK to read this location: tap Try '
              'again and allow it.',
        LocationProblem.notFound =>
          'No position yet. Nobody in radio range is sharing a spot, and '
              "this device couldn't measure one itself. Pin yours on the "
              'globe: long-press it on the Mesh Map.',
      };

  /// Shown while a reading is in progress.
  static String finding({bool offerPin = false}) {
    final pin = offerPin ? ' Or long-press the globe to pin your spot.' : '';
    if (Platform.isMacOS) {
      return 'Looking for a position. This Mac has no GPS, so it uses a '
          'device in radio range that is sharing one.$pin';
    }
    return offerPin
        ? "Finding this device's location… or long-press your spot to pin it."
        : "Finding this device's location…";
  }

  /// How one position read is asked for. [macOS] overrides the platform so
  /// tests can cover both.
  ///
  /// A Mac has no GPS. Core Location's only other source is a Wi-Fi scan,
  /// which reports "unknown" immediately and can take minutes. The Mac
  /// path therefore has no deadline: a live subscription waits, and the
  /// screen does not. A kilometer is what that scan can actually meet.
  /// The point that comes back still carries its real accuracy.
  static LocationSettings readSettings({bool? macOS}) {
    if (macOS ?? Platform.isMacOS) {
      return const LocationSettings(accuracy: LocationAccuracy.low);
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 20),
    );
  }

  /// Opens the device's location settings, where access is allowed.
  Future<void> openDeviceSettings() async {
    try {
      if (_problem == LocationProblem.servicesOff) {
        await Geolocator.openLocationSettings();
      } else {
        await Geolocator.openAppSettings();
      }
    } catch (_) {}
  }

  /// This device's own fix: the one in memory, or the one it stored.
  Future<GeoPoint?> _ownFix() async {
    final memory = _fix;
    if (memory != null &&
        _origin != LocationOrigin.nearby &&
        _isFresh(memory)) {
      return memory;
    }
    final saved = await _savedOwnFix();
    if (saved == null) return null;
    _adopt(saved, LocationOrigin.remembered);
    return saved;
  }

  Future<GeoPoint?> _savedOwnFix() async {
    final prefs = await SharedPreferences.getInstance();
    final point =
        GeoPoint.decode(prefs.getString(IdentityScope.key(ownFixKey)) ?? '');
    if (point == null || !_isFresh(point)) return null;
    return point;
  }

  Future<void> _remember(GeoPoint point) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(IdentityScope.key(ownFixKey), point.encode());
  }

  /// A neighbor's spot, widened by radio range. The callback is responsible
  /// for only returning someone this device can hear right now.
  Future<GeoPoint?> _heardNearby() async {
    final point = await nearbyPosition?.call();
    if (point == null) return null;
    if (point.lat.abs() > 90 || point.lon.abs() > 180) return null;
    return GeoPoint(
      lat: point.lat,
      lon: point.lon,
      accuracyM: point.accuracyM + nearbyRadioM,
      tsMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  bool _isFresh(GeoPoint point) {
    final age = DateTime.now().millisecondsSinceEpoch - point.tsMs;
    return age >= 0 && age < maxAge.inMilliseconds;
  }

  void _adopt(GeoPoint point, LocationOrigin origin) {
    final previous = _fix;
    final same = previous != null &&
        _origin == origin &&
        previous.lat == point.lat &&
        previous.lon == point.lon &&
        previous.accuracyM == point.accuracyM;
    _fix = point;
    _origin = origin;
    _problem = null;
    if (!same) _changed.add(null);
  }

  GeoPoint? _accept(Position? position) {
    if (position == null) return null;
    final point = GeoPoint(
      lat: position.latitude,
      lon: position.longitude,
      accuracyM: max(0, position.accuracy.round()),
      tsMs: position.timestamp.millisecondsSinceEpoch,
    );
    return _isFresh(point) ? point : null;
  }

  /// Asks the platform, when [askPermission] says the person is waiting
  /// for the prompt. A position it already has is kept. A Mac is not
  /// blocked on the scan: the subscription delivers a fix later if one
  /// ever arrives.
  Future<void> _acquire({required bool askPermission}) async {
    _looking = true;
    _changed.add(null);
    try {
      if (!await _sensorAllowed(askPermission)) return;
      try {
        final last = _accept(await Geolocator.getLastKnownPosition());
        if (last != null) {
          _adopt(last, LocationOrigin.sensor);
          await _remember(last);
        }
      } catch (_) {}
      if (Platform.isMacOS) {
        _armLiveSensor();
        return;
      }
      try {
        final fix = _accept(await Geolocator.getCurrentPosition(
          locationSettings: readSettings(),
        ));
        if (fix == null) return;
        _adopt(fix, LocationOrigin.sensor);
        await _remember(fix);
      } catch (_) {
        if (_fix == null) _problem = LocationProblem.notFound;
      }
    } finally {
      _looking = false;
      _changed.add(null);
    }
  }

  Future<bool> _sensorAllowed(bool askPermission) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _problem = LocationProblem.servicesOff;
        return false;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && askPermission) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.deniedForever:
          _problem = LocationProblem.notAllowed;
          return false;
        case LocationPermission.denied:
          _problem = askPermission
              ? LocationProblem.notAllowed
              : LocationProblem.notAsked;
          return false;
        case LocationPermission.unableToDetermine:
          _problem = LocationProblem.notFound;
          return false;
        case LocationPermission.whileInUse:
        case LocationPermission.always:
          return true;
      }
    } catch (_) {
      if (_fix == null) _problem = LocationProblem.notFound;
      return false;
    }
  }

  /// Starts one live subscription if the platform will already allow it.
  /// Never prompts; the map polls this.
  void _ensureListening() {
    if (_sensorSub != null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final wait =
        _origin == LocationOrigin.sensor || _origin == LocationOrigin.remembered
            ? refreshEvery
            : retryEvery;
    if (now - _lastAttemptMs < wait.inMilliseconds) return;
    _lastAttemptMs = now;
    unawaited(_acquire(askPermission: false));
  }

  void _armLiveSensor() {
    if (_sensorSub != null) return;
    try {
      _sensorSub = Geolocator.getPositionStream(
        locationSettings: readSettings(),
      ).listen((position) {
        final fix = _accept(position);
        if (fix == null) return;
        _adopt(fix, LocationOrigin.sensor);
        unawaited(_remember(fix));
      }, onError: (Object _) {
        if (_fix == null) {
          _problem = LocationProblem.notFound;
          _changed.add(null);
        }
      });
    } catch (_) {
      if (_fix == null) _problem = LocationProblem.notFound;
    }
  }

  Future<void> _stopSensor() async {
    final sub = _sensorSub;
    _sensorSub = null;
    await sub?.cancel();
  }

  /// Forgets the in-memory reading (on identity switch or log out).
  void reset() {
    _fix = null;
    _origin = null;
    _problem = null;
    _lastAttemptMs = 0;
    nearbyPosition = null;
    unawaited(_stopSensor());
  }
}
