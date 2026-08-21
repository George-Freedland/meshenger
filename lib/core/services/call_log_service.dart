import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

enum CallOutcome { completed, missed, declined, noAnswer, failed }

class CallLogEntry {
  final String peer; // base64 address
  final bool video;
  final bool outgoing;
  final int tsMs;
  final CallOutcome outcome;
  final int durationSeconds;

  const CallLogEntry({
    required this.peer,
    required this.video,
    required this.outgoing,
    required this.tsMs,
    required this.outcome,
    this.durationSeconds = 0,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'peer': peer,
        'video': video,
        'out': outgoing,
        'ts': tsMs,
        'outcome': outcome.name,
        'dur': durationSeconds,
      };

  static CallLogEntry fromJson(Map<String, Object?> json) => CallLogEntry(
        peer: json['peer'] as String,
        video: json['video'] == true,
        outgoing: json['out'] == true,
        tsMs: (json['ts'] as num).toInt(),
        outcome: CallOutcome.values.firstWhere(
          (o) => o.name == json['outcome'],
          orElse: () => CallOutcome.failed,
        ),
        durationSeconds: (json['dur'] as num?)?.toInt() ?? 0,
      );
}

/// Recents list for the Phone and FaceTime apps (identity-scoped).
class CallLogService {
  CallLogService._();
  static final CallLogService instance = CallLogService._();

  static const _logKey = 'call_log_v1';
  static const int _maxEntries = 200;

  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  Future<List<CallLogEntry>> list({bool? video}) async {
    final entries = await _readAll();
    return entries
        .where((e) => video == null || e.video == video)
        .toList()
      ..sort((a, b) => b.tsMs.compareTo(a.tsMs));
  }

  Future<void> add(CallLogEntry entry) async {
    final entries = await _readAll();
    entries.add(entry);
    entries.sort((a, b) => b.tsMs.compareTo(a.tsMs));
    if (entries.length > _maxEntries) {
      entries.removeRange(_maxEntries, entries.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_logKey),
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
    _changed.add(null);
  }

  Future<List<CallLogEntry>> _readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_logKey));
    if (raw == null || raw.isEmpty) return <CallLogEntry>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <CallLogEntry>[];
    return decoded
        .whereType<Map>()
        .map((m) => CallLogEntry.fromJson(m.cast<String, Object?>()))
        .toList();
  }
}
