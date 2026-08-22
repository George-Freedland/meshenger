import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

/// One presence change in the surrounding mesh: someone came into radio
/// range (joined your mesh) or dropped out of it.
class MeshActivityEvent {
  final String address;
  final String? nickname; // best-known name at the time
  final bool joined;
  final int tsMs;

  const MeshActivityEvent({
    required this.address,
    required this.nickname,
    required this.joined,
    required this.tsMs,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'addr': address,
        if (nickname != null) 'nick': nickname,
        'j': joined,
        'ts': tsMs,
      };

  static MeshActivityEvent fromJson(Map<String, Object?> json) =>
      MeshActivityEvent(
        address: json['addr'] as String,
        nickname: json['nick'] as String?,
        joined: json['j'] == true,
        tsMs: (json['ts'] as num?)?.toInt() ?? 0,
      );
}

/// Rolling log of who joined/left the mesh around this device — the
/// Network feed's "someone is nearby" pulse. Local-only and identity
/// scoped; nothing is broadcast.
class MeshActivityLog {
  MeshActivityLog._();
  static final MeshActivityLog instance = MeshActivityLog._();

  static const _logKey = 'mesh_activity_v1';
  static const int _cap = 120;

  /// Ignore join spam: the same node re-appearing within this window
  /// (flapping radio link) is not "news".
  static const Duration rejoinQuiet = Duration(minutes: 5);

  /// A node must have been around at least this long for its departure
  /// to count — sub-minute blips are link noise, not someone leaving.
  static const Duration minStayForLeave = Duration(seconds: 45);

  final StreamController<void> _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  List<MeshActivityEvent>? _cache;

  Future<List<MeshActivityEvent>> list() async {
    final events = await _readAll();
    return events.reversed.toList(); // newest first
  }

  Future<void> recordJoin(String address, {String? nickname}) async {
    final events = await _readAll();
    final now = DateTime.now().millisecondsSinceEpoch;
    for (var i = events.length - 1; i >= 0; i--) {
      final event = events[i];
      if (event.address != address) continue;
      if (event.joined && now - event.tsMs < rejoinQuiet.inMilliseconds) {
        return; // flapping link, not news
      }
      break;
    }
    events.add(MeshActivityEvent(
      address: address,
      nickname: nickname,
      joined: true,
      tsMs: now,
    ));
    await _writeAll(events);
    _changed.add(null);
  }

  Future<void> recordLeave(String address, {String? nickname}) async {
    final events = await _readAll();
    events.add(MeshActivityEvent(
      address: address,
      nickname: nickname,
      joined: false,
      tsMs: DateTime.now().millisecondsSinceEpoch,
    ));
    await _writeAll(events);
    _changed.add(null);
  }

  Future<List<MeshActivityEvent>> _readAll() async {
    final cached = _cache;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_logKey));
    final result = <MeshActivityEvent>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final entry in decoded.whereType<Map>()) {
            result.add(
              MeshActivityEvent.fromJson(entry.cast<String, Object?>()),
            );
          }
        }
      } catch (_) {}
    }
    _cache = result;
    return result;
  }

  Future<void> _writeAll(List<MeshActivityEvent> events) async {
    while (events.length > _cap) {
      events.removeAt(0);
    }
    _cache = events;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_logKey),
      jsonEncode(events.map((e) => e.toJson()).toList()),
    );
  }

  /// Clears the in-memory cache (on identity switch).
  void resetCache() {
    _cache = null;
  }
}
