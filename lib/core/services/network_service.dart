import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/post_attachment.dart';
import '../transport/envelope_codec.dart';
import 'blob_service.dart';
import 'identity_scope.dart';
import 'identity_service.dart';
import 'media_store.dart';

/// Something published on the Network: a post on the global square, a
/// post on the author's site, or one of the author's site pages (HTML).
/// Public posts are visible to everyone the mesh can reach, contacts or
/// not, until they expire; private ones never leave this device.
class NetworkPost {
  final String id;
  final String author; // base64 address
  final String? authorNick; // self-chosen name carried with the post
  /// Post text, or the HTML source of a page.
  final String text;
  final int tsMs;
  final int expiresMs;

  /// How many hops away the post was when it arrived (0 = posted here).
  final int hops;

  /// Optional image (id in the local MediaStore).
  final String? mediaId;
  final String? mediaMime;

  /// [EnvelopeCodec.scopeGlobal] or [EnvelopeCodec.scopeSite].
  final String scope;

  /// 'text' | 'image' | 'page' | 'file'.
  final String kind;

  /// Pages only: path under the author's site ('' = home page).
  final String? path;
  final String? title;

  /// File posts: what's attached (the bytes live in BlobService), and its
  /// cover art (id in the local MediaStore).
  final PostAttachment? attachment;
  final String? artMediaId;

  /// Mine and kept on this device only (never published, or withdrawn).
  final bool isPrivate;

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
    this.scope = EnvelopeCodec.scopeGlobal,
    String? kind,
    this.path,
    this.title,
    this.attachment,
    this.artMediaId,
    this.isPrivate = false,
  }) : kind = kind ??
            (attachment != null
                ? 'file'
                : mediaId != null
                    ? 'image'
                    : 'text');

  bool get isActive => DateTime.now().millisecondsSinceEpoch < expiresMs;
  bool get isPage => kind == 'page';
  bool get isGlobal => scope == EnvelopeCodec.scopeGlobal;

  NetworkPost copyWith({String? id, int? tsMs, bool? isPrivate}) =>
      NetworkPost(
        id: id ?? this.id,
        author: author,
        authorNick: authorNick,
        text: text,
        tsMs: tsMs ?? this.tsMs,
        expiresMs: expiresMs,
        hops: hops,
        mediaId: mediaId,
        mediaMime: mediaMime,
        scope: scope,
        kind: kind,
        path: path,
        title: title,
        attachment: attachment,
        artMediaId: artMediaId,
        isPrivate: isPrivate ?? this.isPrivate,
      );

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
        if (!isGlobal) 'scope': scope,
        'kind': kind,
        if (path != null) 'path': path,
        if (title != null) 'title': title,
        if (attachment != null) 'att': attachment!.toJson(),
        if (artMediaId != null) 'artMediaId': artMediaId,
        if (isPrivate) 'private': true,
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
        scope: json['scope'] as String? ?? EnvelopeCodec.scopeGlobal,
        kind: json['kind'] as String?,
        path: json['path'] as String?,
        title: json['title'] as String?,
        attachment: PostAttachment.fromJson(json['att']),
        artMediaId: json['artMediaId'] as String?,
        isPrivate: json['private'] == true,
      );

  /// Local media this post owns (deleted with it).
  Iterable<String> get ownedMedia =>
      [if (mediaId != null) mediaId!, if (artMediaId != null) artMediaId!];
}

/// Local store for the Network (my posts and pages + everything heard from
/// the mesh). Identity-scoped like everything else.
class NetworkService {
  NetworkService._();
  static final NetworkService instance = NetworkService._();

  static const _postsKey = 'network_posts_v1';
  static const _seenKey = 'network_seen_ms_v1';

  /// Other people's pages kept on this device; the oldest go first.
  static const int _maxForeignPages = 64;

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

  /// Every active post and page, newest first.
  Future<List<NetworkPost>> listActive() async {
    final posts = await _readAll();
    return posts.where((p) => p.isActive).toList()
      ..sort((a, b) => b.tsMs.compareTo(a.tsMs));
  }

  Future<NetworkPost?> byId(String id) async {
    for (final post in await _readAll()) {
      if (post.id == id) return post;
    }
    return null;
  }

  /// The newest version of [author]'s page at [path], if one reached us.
  Future<NetworkPost?> page(String author, String path) async {
    for (final post in await listActive()) {
      if (post.isPage && post.author == author && post.path == path) {
        return post;
      }
    }
    return null;
  }

  Future<void> upsert(NetworkPost post) async {
    final posts = await _readAll();
    if (post.isPage) {
      bool samePage(NetworkPost p) =>
          p.isPage &&
          p.id != post.id &&
          p.author == post.author &&
          p.path == post.path;
      // A page has one live version; an older copy arriving late loses.
      if (posts.any((p) => samePage(p) && p.tsMs > post.tsMs)) return;
      posts.removeWhere(samePage);
    }
    posts.removeWhere((p) => p.id == post.id);
    posts.add(post);
    if (post.isPage) {
      _capForeignPages(
          posts, await IdentityService.instance.getPublicAddressBase64());
    }
    await _writeAll(posts);
    _notifyPostsChanged();
  }

  void _capForeignPages(List<NetworkPost> posts, String? myAddress) {
    final foreign = posts
        .where((p) => p.isPage && p.author != myAddress)
        .toList()
      ..sort((a, b) => a.tsMs.compareTo(b.tsMs));
    var excess = foreign.length - _maxForeignPages;
    for (final page in foreign) {
      if (excess <= 0) break;
      posts.remove(page);
      excess--;
    }
  }

  /// Replaces the post stored as [oldId] with [replacement] (a re-publish
  /// under a fresh id), keeping its media.
  Future<void> rekey(String oldId, NetworkPost replacement) async {
    final posts = await _readAll();
    posts.removeWhere((p) => p.id == oldId || p.id == replacement.id);
    posts.add(replacement);
    await _writeAll(posts);
    _notifyPostsChanged();
  }

  Future<void> remove(String id) async {
    final posts = await _readAll();
    final removed = posts.where((p) => p.id == id).toList();
    if (removed.isEmpty) return;
    posts.removeWhere((p) => p.id == id);
    await _writeAll(posts);
    await _dropMediaOf(removed, posts);
    _notifyPostsChanged();
  }

  /// Purges expired posts (and their media). Returns true when anything
  /// was removed.
  Future<bool> sweepExpired() async {
    final posts = await _readAll();
    final active = posts.where((p) => p.isActive).toList();
    if (active.length == posts.length) return false;
    await _writeAll(active);
    await _dropMediaOf(posts.where((p) => !p.isActive), active);
    _notifyPostsChanged();
    return true;
  }

  /// Deletes what [gone] posts owned. Attached files are shared by hash,
  /// so one stays while any [remaining] post still points at it.
  Future<void> _dropMediaOf(
    Iterable<NetworkPost> gone,
    List<NetworkPost> remaining,
  ) async {
    for (final post in gone) {
      for (final mediaId in post.ownedMedia) {
        await MediaStore.instance.delete(mediaId);
      }
    }
    if (gone.any((p) => p.attachment != null)) {
      await BlobService.instance.retain({
        for (final p in remaining) ...?p.attachment?.blobs,
      });
    }
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

  /// Active posts from others that arrived since the feed was last open
  /// (page updates don't count).
  Future<int> unseenCount(String? myAddress) async {
    final since = await _lastSeenMs();
    final posts = await listActive();
    return posts
        .where((p) => !p.isPage && p.tsMs > since && p.author != myAddress)
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
