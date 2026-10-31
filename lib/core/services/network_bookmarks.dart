import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

/// A saved Network browser address with a name of my choosing.
class MeshBookmark {
  const MeshBookmark({
    required this.url,
    required this.name,
    required this.addedMs,
  });

  /// The address as shown in the address bar (`global`, `<key>/blog`, …).
  final String url;
  final String name;
  final int addedMs;

  Map<String, Object?> toJson() =>
      <String, Object?>{'url': url, 'name': name, 'added': addedMs};

  static MeshBookmark fromJson(Map<String, Object?> json) => MeshBookmark(
        url: json['url'] as String,
        name: json['name'] as String? ?? '',
        addedMs: (json['added'] as num?)?.toInt() ?? 0,
      );
}

/// Bookmarks for the Network browser, kept per identity.
class NetworkBookmarks {
  NetworkBookmarks._();
  static final NetworkBookmarks instance = NetworkBookmarks._();

  static const _key = 'network_bookmarks_v1';

  final StreamController<void> _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  /// Oldest first, like a bookmarks bar.
  Future<List<MeshBookmark>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_key));
    if (raw == null || raw.isEmpty) return <MeshBookmark>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <MeshBookmark>[];
    return decoded
        .whereType<Map>()
        .map((m) => MeshBookmark.fromJson(m.cast<String, Object?>()))
        .toList()
      ..sort((a, b) => a.addedMs.compareTo(b.addedMs));
  }

  /// Adds [url] under [name], or renames it if already bookmarked.
  Future<void> save(String url, String name) async {
    final bookmarks = await list();
    final index = bookmarks.indexWhere((b) => b.url == url);
    final bookmark = MeshBookmark(
      url: url,
      name: name.trim().isEmpty ? url : name.trim(),
      addedMs: index >= 0
          ? bookmarks[index].addedMs
          : DateTime.now().millisecondsSinceEpoch,
    );
    if (index >= 0) {
      bookmarks[index] = bookmark;
    } else {
      bookmarks.add(bookmark);
    }
    await _write(bookmarks);
  }

  Future<void> remove(String url) async {
    final bookmarks = await list();
    bookmarks.removeWhere((b) => b.url == url);
    await _write(bookmarks);
  }

  Future<void> _write(List<MeshBookmark> bookmarks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_key),
      jsonEncode(bookmarks.map((b) => b.toJson()).toList()),
    );
    _changed.add(null);
  }
}
