import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';
import 'media_store.dart';

class Story {
  final String id;
  final String author; // base64 address
  final String text;
  final int tsMs;
  final int expiresMs;

  /// Optional image attached to the story (id in the local MediaStore).
  final String? mediaId;
  final String? mediaMime;

  const Story({
    required this.id,
    required this.author,
    required this.text,
    required this.tsMs,
    required this.expiresMs,
    this.mediaId,
    this.mediaMime,
  });

  bool get isActive => DateTime.now().millisecondsSinceEpoch < expiresMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'author': author,
        'text': text,
        'ts': tsMs,
        'expires': expiresMs,
        if (mediaId != null) 'mediaId': mediaId,
        if (mediaMime != null) 'mediaMime': mediaMime,
      };

  static Story fromJson(Map<String, Object?> json) => Story(
        id: json['id'] as String,
        author: json['author'] as String,
        text: json['text'] as String,
        tsMs: (json['ts'] as num).toInt(),
        expiresMs: (json['expires'] as num).toInt(),
        mediaId: json['mediaId'] as String?,
        mediaMime: json['mediaMime'] as String?,
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
    final removed = stories.where((s) => s.id == id).toList();
    stories.removeWhere((s) => s.id == id);
    await _writeAll(stories);
    for (final story in removed) {
      final mediaId = story.mediaId;
      if (mediaId != null) await MediaStore.instance.delete(mediaId);
    }
    _changed.add(null);
  }

  /// Purges expired stories (and their media). Returns true when anything
  /// was removed.
  Future<bool> sweepExpired() async {
    final stories = await _readAll();
    final active = stories.where((s) => s.isActive).toList();
    if (active.length == stories.length) return false;
    final expired = stories.where((s) => !s.isActive);
    for (final story in expired) {
      final mediaId = story.mediaId;
      if (mediaId != null) await MediaStore.instance.delete(mediaId);
    }
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
