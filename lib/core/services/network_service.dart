import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';
import 'media_store.dart';

/// A post on the Network feed: public content from someone in the mesh —
/// a status, a song, a photo of something happening nearby. Visible to
/// everyone the mesh can reach, contacts or not, until it expires.
class NetworkPost {
  final String id;
  final String author; // base64 address
  final String? authorNick; // self-chosen name carried with the post
  final String text;
  final int tsMs;
  final int expiresMs;

  /// How many hops away the post was when it arrived (0 = posted here).
  final int hops;

  /// Optional image (id in the local MediaStore).
  final String? mediaId;
  final String? mediaMime;

  const NetworkPost({
    required this.id,
    required this.author,
    required this.text,
    required this.tsMs,
    required this.expiresMs,
    this.authorNick,
    this.hops = 0,
    this.mediaId,
    this.mediaMime,
  });

  bool get isActive => DateTime.now().millisecondsSinceEpoch < expiresMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'author': author,
        if (authorNick != null) 'nick': authorNick,
        'text': text,
        'ts': tsMs,
        'expires': expiresMs,
        if (hops != 0) 'hops': hops,
        if (mediaId != null) 'mediaId': mediaId,
        if (mediaMime != null) 'mediaMime': mediaMime,
      };

  static NetworkPost fromJson(Map<String, Object?> json) => NetworkPost(
        id: json['id'] as String,
        author: json['author'] as String,
        authorNick: json['nick'] as String?,
        text: json['text'] as String? ?? '',
        tsMs: (json['ts'] as num).toInt(),
        expiresMs: (json['expires'] as num).toInt(),
        hops: (json['hops'] as num?)?.toInt() ?? 0,
        mediaId: json['mediaId'] as String?,
        mediaMime: json['mediaMime'] as String?,
      );
}

/// Local store for the Network feed (my posts + everything heard from
/// the mesh). Identity-scoped like everything else.
class NetworkService {
  NetworkService._();
  static final NetworkService instance = NetworkService._();

  static const _postsKey = 'network_posts_v1';
  static const _seenKey = 'network_seen_ms_v1';

  final StreamController<void> _changed = StreamController<void>.broadcast();
  final StreamController<void> _postsChanged =
      StreamController<void>.broadcast();

  /// Fires on any change, including the feed being marked seen (badges).
  Stream<void> get onChanged => _changed.stream;

  /// Fires only when the set of posts changes. The feed screen listens to
  /// this one: it calls [markSeen] on every reload, so listening to
  /// [onChanged] would make it reload itself forever.
  Stream<void> get onPostsChanged => _postsChanged.stream;

  void _notifyPostsChanged() {
    _postsChanged.add(null);
    _changed.add(null);
  }

  Future<List<NetworkPost>> listActive() async {
    final posts = await _readAll();
    return posts.where((p) => p.isActive).toList()
      ..sort((a, b) => b.tsMs.compareTo(a.tsMs));
  }

  Future<void> upsert(NetworkPost post) async {
    final posts = await _readAll();
    posts.removeWhere((p) => p.id == post.id);
    posts.add(post);
    await _writeAll(posts);
    _notifyPostsChanged();
  }

  Future<void> remove(String id) async {
    final posts = await _readAll();
    final removed = posts.where((p) => p.id == id).toList();
    if (removed.isEmpty) return;
    posts.removeWhere((p) => p.id == id);
    await _writeAll(posts);
    for (final post in removed) {
      final mediaId = post.mediaId;
      if (mediaId != null) await MediaStore.instance.delete(mediaId);
    }
    _notifyPostsChanged();
  }

  /// Purges expired posts (and their media). Returns true when anything
  /// was removed.
  Future<bool> sweepExpired() async {
    final posts = await _readAll();
    final active = posts.where((p) => p.isActive).toList();
    if (active.length == posts.length) return false;
    final expired = posts.where((p) => !p.isActive);
    for (final post in expired) {
      final mediaId = post.mediaId;
      if (mediaId != null) await MediaStore.instance.delete(mediaId);
    }
    await _writeAll(active);
    _notifyPostsChanged();
    return true;
  }

  // ---------------------------------------------------------------------
  // Unseen tracking (powers the Network app badge)
  // ---------------------------------------------------------------------

  Future<int> _lastSeenMs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(IdentityScope.key(_seenKey)) ?? 0;
  }

  /// Marks the feed as caught-up right now.
  Future<void> markSeen() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      IdentityScope.key(_seenKey),
      DateTime.now().millisecondsSinceEpoch,
    );
    _changed.add(null);
  }

  /// Active posts from others that arrived since the feed was last open.
  Future<int> unseenCount(String? myAddress) async {
    final since = await _lastSeenMs();
    final posts = await listActive();
    return posts
        .where((p) => p.tsMs > since && p.author != myAddress)
        .length;
  }

  Future<List<NetworkPost>> _readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_postsKey));
    if (raw == null || raw.isEmpty) return <NetworkPost>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <NetworkPost>[];
    return decoded
        .whereType<Map>()
        .map((m) => NetworkPost.fromJson(m.cast<String, Object?>()))
        .toList();
  }

  Future<void> _writeAll(List<NetworkPost> posts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_postsKey),
      jsonEncode(posts.map((p) => p.toJson()).toList()),
    );
  }
}
