import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

class Story {
  final String id;
  final String author; // base64 address
  final String text;
  final int tsMs;
  final int expiresMs;

  const Story({
    required this.id,
    required this.author,
    required this.text,
    required this.tsMs,
    required this.expiresMs,
  });

  bool get isActive => DateTime.now().millisecondsSinceEpoch < expiresMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'author': author,
        'text': text,
        'ts': tsMs,
        'expires': expiresMs,
      };

  static Story fromJson(Map<String, Object?> json) => Story(
        id: json['id'] as String,
        author: json['author'] as String,
        text: json['text'] as String,
        tsMs: (json['ts'] as num).toInt(),
        expiresMs: (json['expires'] as num).toInt(),
      );
}

/// Local store for status updates (mine + received from contacts).
class StoriesService {
  StoriesService._();
  static final StoriesService instance = StoriesService._();

  static const _storiesKey = 'stories_v1';

  final StreamController<void> _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  Future<List<Story>> listActive() async {
    final stories = await _readAll();
    return stories.where((s) => s.isActive).toList()
      ..sort((a, b) => b.tsMs.compareTo(a.tsMs));
  }

  Future<void> upsert(Story story) async {
    final stories = await _readAll();
    stories.removeWhere((s) => s.id == story.id);
    stories.add(story);
    await _writeAll(stories);
    _changed.add(null);
  }

  Future<void> remove(String id) async {
    final stories = await _readAll();
    stories.removeWhere((s) => s.id == id);
    await _writeAll(stories);
    _changed.add(null);
  }

  /// Purges expired stories. Returns true when anything was removed.
  Future<bool> sweepExpired() async {
    final stories = await _readAll();
    final active = stories.where((s) => s.isActive).toList();
    if (active.length == stories.length) return false;
    await _writeAll(active);
    _changed.add(null);
    return true;
  }

  Future<List<Story>> _readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_storiesKey));
    if (raw == null || raw.isEmpty) return <Story>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <Story>[];
    return decoded
        .whereType<Map>()
        .map((m) => Story.fromJson(m.cast<String, Object?>()))
        .toList();
  }

  Future<void> _writeAll(List<Story> stories) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_storiesKey),
      jsonEncode(stories.map((s) => s.toJson()).toList()),
    );
  }
}
