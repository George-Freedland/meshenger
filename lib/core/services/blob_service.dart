import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

import '../models/post_attachment.dart';
import 'identity_scope.dart';
import 'transport_log.dart';

enum BlobState {
  /// Not on this device and nobody asked for it.
  missing,

  /// Asking the devices in range who has it.
  searching,
  downloading,

  /// All bytes are here; checking them against the hash.
  verifying,
  done,
}

class BlobProgress {
  const BlobProgress(this.state, {this.receivedBytes = 0, this.totalBytes = 0});

  final BlobState state;
  final int receivedBytes;
  final int totalBytes;

  double get fraction =>
      totalBytes == 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);
}

/// Files attached to Network posts, stored by their SHA-256 and shared
/// device to device on request.
///
/// Posts only describe a file (name, size, hash, tags), so a song posted
/// to Global reaches everyone in moments without every phone carrying
/// megabytes. When someone taps it, this asks the devices in range who
/// has it (`bwho`/`bhave`), downloads it in windows of chunks from one of
/// them (`bget`/`bdat`), checks the hash, and from then on shares it too:
/// a file spreads to wherever people actually play it.
///
/// Downloads resume from their partial file and survive sources leaving;
/// a source that sends bytes not matching the hash is never asked again.
class BlobService {
  BlobService({Future<Directory> Function()? directory})
      : _directory = directory ?? _identityDirectory;

  static final BlobService instance = BlobService();

  static const int chunkSize = 24 * 1024;

  /// Chunks requested at once; the source sends them back to back.
  static const int window = 16;

  /// A download with no new chunk for this long re-asks its source…
  static const Duration stallAfter = Duration(seconds: 8);

  /// …and gives up on it after this many stalls in a row.
  static const int maxStalls = 3;

  /// How often a search re-asks the devices in range.
  static const Duration askEvery = Duration(seconds: 12);

  Future<Directory> Function() _directory;

  static Future<Directory> _identityDirectory() async {
    final fp = IdentityScope.activeFingerprint;
    if (fp == null) throw StateError('No active identity');
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/blobs/$fp');
  }

  @visibleForTesting
  set directoryForTesting(Directory dir) {
    _directory = () async => dir;
    _index = null;
  }

  // --- Wired by MessengerService -----------------------------------------
  Future<bool> Function(String peer, Map<String, Object?> packet)? _send;
  Set<String> Function()? _peers;
  Future<String?> Function()? _me;

  void attach({
    required Future<bool> Function(String peer, Map<String, Object?> packet)
        send,
    required Set<String> Function() onlinePeers,
    required Future<String?> Function() myAddress,
  }) {
    _send = send;
    _peers = onlinePeers;
    _me = myAddress;
  }

  Future<void> detach() async {
    _send = null;
    _peers = null;
    _me = null;
    _ticker?.cancel();
    _ticker = null;
    for (final download in _downloads.values) {
      await download.close();
    }
    _downloads.clear();
    _serving.clear();
    _index = null;
  }

  final StreamController<String> _changed = StreamController.broadcast();

  /// Emits a file's hash whenever its availability or progress moves.
  Stream<String> get onChanged => _changed.stream;

  final Map<String, _Download> _downloads = <String, _Download>{};

  /// Per (file, requester): bumping it stops an older serve loop.
  final Map<String, int> _serving = <String, int>{};
  Timer? _ticker;

  /// Complete files on disk: hash → path.
  Map<String, String>? _index;

  // ---------------------------------------------------------------------
  // Local files
  // ---------------------------------------------------------------------

  static String extensionFor(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return 'bin';
    final ext = name.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(ext) ? ext : 'bin';
  }

  Future<Directory> _dir() async {
    final dir = await _directory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<Map<String, String>> _ensureIndex() async {
    final existing = _index;
    if (existing != null) return existing;
    final index = <String, String>{};
    await for (final entity in (await _dir()).list()) {
      if (entity is! File) continue;
      final base = entity.uri.pathSegments.last;
      final dot = base.indexOf('.');
      if (dot != 64) continue;
      final sha = base.substring(0, 64);
      if (!PostAttachment.shaPattern.hasMatch(sha)) continue;
      if (base.endsWith('.part')) continue;
      index[sha] = entity.path;
    }
    return _index = index;
  }

  /// The complete file for [sha] on this device, if any.
  Future<String?> pathFor(String sha) async {
    try {
      return (await _ensureIndex())[sha];
    } catch (_) {
      return null;
    }
  }

  BlobProgress progressOf(String sha, {int size = 0}) {
    final download = _downloads[sha];
    if (download != null) {
      return BlobProgress(
        download.state,
        receivedBytes: min(download.have * chunkSize, download.size),
        totalBytes: download.size,
      );
    }
    if (_index?.containsKey(sha) == true) {
      return BlobProgress(BlobState.done, receivedBytes: size, totalBytes: size);
    }
    return BlobProgress(BlobState.missing, totalBytes: size);
  }

  /// Keeps a copy of my own file, so this device can share it.
  Future<String> addLocalFile(
    String path, {
    required String sha,
    required String name,
  }) async {
    final index = await _ensureIndex();
    final existing = index[sha];
    if (existing != null && await File(existing).exists()) return existing;
    final dest = '${(await _dir()).path}/$sha.${extensionFor(name)}';
    await File(path).copy(dest);
    index[sha] = dest;
    _changed.add(sha);
    return dest;
  }

  /// Stores a file that arrived inside a post. Ignored unless the bytes
  /// match [sha].
  Future<String?> addBytes(
    Uint8List bytes, {
    required String sha,
    required String name,
  }) async {
    if (await sha256OfBytes(bytes) != sha) return null;
    final index = await _ensureIndex();
    final existing = index[sha];
    if (existing != null) return existing;
    final dest = '${(await _dir()).path}/$sha.${extensionFor(name)}';
    await File(dest).writeAsBytes(bytes, flush: true);
    index[sha] = dest;
    _changed.add(sha);
    return dest;
  }

  /// Deletes every file (and partial download) not in [keep] — files go
  /// when the last post pointing at them expires or is deleted.
  Future<void> retain(Set<String> keep) async {
    try {
      final index = await _ensureIndex();
      for (final sha in _downloads.keys.toList()) {
        if (!keep.contains(sha)) {
          await _downloads.remove(sha)?.close();
          _changed.add(sha);
        }
      }
      await for (final entity in (await _dir()).list()) {
        if (entity is! File) continue;
        final base = entity.uri.pathSegments.last;
        if (base.length < 64) continue;
        final sha = base.substring(0, 64);
        if (keep.contains(sha)) continue;
        await entity.delete();
        if (index.remove(sha) != null) _changed.add(sha);
      }
    } catch (_) {
      // Housekeeping only; a locked file just waits for the next sweep.
    }
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Future<String> sha256OfBytes(List<int> bytes) async =>
      _hex((await Sha256().hash(bytes)).bytes);

  /// Streams the file through SHA-256: memory stays flat for any size.
  static Future<String> sha256OfFile(String path) async {
    final sink = Sha256().newHashSink();
    await for (final chunk in File(path).openRead()) {
      sink.add(chunk);
    }
    sink.close();
    return _hex((await sink.hash()).bytes);
  }

  static int chunkCountFor(int size) => (size + chunkSize - 1) ~/ chunkSize;

  // ---------------------------------------------------------------------
  // Downloading
  // ---------------------------------------------------------------------

  /// Starts (or nudges) the download of [sha]. Safe to call repeatedly.
  Future<void> fetch({
    required String sha,
    required int size,
    required String name,
  }) async {
    if (!PostAttachment.shaPattern.hasMatch(sha) || size <= 0) return;
    if (await pathFor(sha) != null) return;
    final existing = _downloads[sha];
    if (existing != null) {
      await _ask(existing, force: true);
      return;
    }
    final download = _Download(sha: sha, size: size, ext: extensionFor(name));
    _downloads[sha] = download;
    await _openPart(download);
    _changed.add(sha);
    TransportLog.instance.log('Files: looking for "$name" '
        '(${(size / 1024).ceil()} KB) on nearby devices');
    await _ask(download, force: true);
    _ticker ??= Timer.periodic(const Duration(seconds: 2), (_) => _tick());
  }

  /// Stops downloading; the partial file stays so a later fetch resumes.
  Future<void> cancel(String sha) async {
    final download = _downloads.remove(sha);
    if (download == null) return;
    await download.close();
    _changed.add(sha);
  }

  Future<File> _partFile(String sha) async =>
      File('${(await _dir()).path}/$sha.part');

  Future<void> _openPart(_Download d) async {
    final part = await _partFile(d.sha);
    if (!await part.exists()) await part.create(recursive: true);
    final raf = await part.open(mode: FileMode.append);
    // Resume from whole chunks only; a torn last chunk is fetched again.
    final whole = min((await raf.length()) ~/ chunkSize, d.total);
    await raf.truncate(whole * chunkSize);
    d
      ..raf = raf
      ..have = whole;
  }

  Future<void> _ask(_Download d, {bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && now - d.lastAskMs < askEvery.inMilliseconds) return;
    d.lastAskMs = now;
    final send = _send;
    final me = await _me?.call();
    if (send == null || me == null) return;
    for (final peer in _peers?.call() ?? const <String>{}) {
      if (d.bad.contains(peer)) continue;
      unawaited(send(peer, <String, Object?>{
        't': 'bwho',
        'h': d.sha,
        'from': me,
      }));
    }
  }

  Future<void> _onHave(String sha, String from) async {
    final d = _downloads[sha];
    if (d == null || d.bad.contains(from)) return;
    d.sources.add(from);
    if (d.source == null && d.state == BlobState.searching) {
      d.source = from;
      d.stalls = 0;
      await _request(d);
    }
  }

  Future<void> _request(_Download d) async {
    final source = d.source;
    final send = _send;
    final me = await _me?.call();
    if (source == null || send == null || me == null) return;
    final count = min(window, d.total - d.have);
    if (count <= 0) return;
    d
      ..requestedUntil = d.have + count
      ..state = BlobState.downloading
      ..lastActivityMs = DateTime.now().millisecondsSinceEpoch;
    _changed.add(d.sha);
    final sent = await send(source, <String, Object?>{
      't': 'bget',
      'h': d.sha,
      'to': source,
      'from': me,
      'i': d.have,
      'n': count,
    });
    if (!sent) await _dropSource(d);
  }

  Future<void> _onData(String sha, String from, int i, String data) async {
    final d = _downloads[sha];
    if (d == null || d.source != from || d.state != BlobState.downloading) {
      return;
    }
    if (i < d.have || i >= d.requestedUntil) return;
    final Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } catch (_) {
      return;
    }
    final expected = i == d.total - 1 ? d.size - i * chunkSize : chunkSize;
    if (bytes.length != expected) return;
    d.pending[i] = bytes;
    d.lastActivityMs = DateTime.now().millisecondsSinceEpoch;
    d.stalls = 0;
    // Chunks can overtake each other; writes stay strictly in order.
    final task = d.writes.then((_) => _flush(d));
    d.writes = task.catchError((_) {});
    await task;
  }

  Future<void> _flush(_Download d) async {
    final raf = d.raf;
    if (raf == null || !identical(_downloads[d.sha], d)) return;
    var moved = false;
    while (d.pending.containsKey(d.have)) {
      await raf.setPosition(d.have * chunkSize);
      await raf.writeFrom(d.pending.remove(d.have)!);
      d.have++;
      moved = true;
    }
    if (!moved) return;
    _changed.add(d.sha);
    if (d.have >= d.total) {
      await _finish(d);
    } else if (d.have >= d.requestedUntil) {
      await _request(d);
    }
  }

  Future<void> _finish(_Download d) async {
    d.state = BlobState.verifying;
    _changed.add(d.sha);
    await d.close();
    final part = await _partFile(d.sha);
    final actual = await sha256OfFile(part.path);
    if (actual == d.sha) {
      final dest = '${(await _dir()).path}/${d.sha}.${d.ext}';
      await part.rename(dest);
      (await _ensureIndex())[d.sha] = dest;
      _downloads.remove(d.sha);
      d.state = BlobState.done;
      _changed.add(d.sha);
      TransportLog.instance.log('Files: got ${d.sha.substring(0, 8)}… '
          '(${(d.size / 1024).ceil()} KB) — sharing it from now on');
      return;
    }
    // Someone sent bytes that don't match: start over from someone else.
    TransportLog.instance.log('Files: ${d.sha.substring(0, 8)}… failed its '
        'check — retrying from another device');
    await part.delete();
    final liar = d.source;
    if (liar != null) {
      d.bad.add(liar);
      d.sources.remove(liar);
    }
    d
      ..source = null
      ..pending.clear()
      ..state = BlobState.searching;
    await _openPart(d);
    _changed.add(d.sha);
    await _useNextSource(d);
  }

  Future<void> _dropSource(_Download d) async {
    final gone = d.source;
    if (gone != null) d.sources.remove(gone);
    d
      ..source = null
      ..stalls = 0
      ..pending.clear()
      ..state = BlobState.searching;
    _changed.add(d.sha);
    await _useNextSource(d);
  }

  Future<void> _useNextSource(_Download d) async {
    final online = _peers?.call() ?? const <String>{};
    for (final candidate in d.sources) {
      if (online.contains(candidate) && !d.bad.contains(candidate)) {
        d.source = candidate;
        await _request(d);
        return;
      }
    }
    await _ask(d, force: true);
  }

  Future<void> _tick() async {
    if (_downloads.isEmpty) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final d in _downloads.values.toList()) {
      if (d.state == BlobState.downloading &&
          now - d.lastActivityMs > stallAfter.inMilliseconds) {
        d.stalls++;
        if (d.stalls >= maxStalls) {
          await _dropSource(d);
        } else {
          await _request(d); // re-ask from the last chunk on disk
        }
      } else if (d.state == BlobState.searching) {
        await _ask(d);
      }
    }
  }

  /// New devices in range may have what a search is waiting for; a source
  /// that left hands its download to someone else.
  Future<void> onPeersChanged(Set<String> peers) async {
    for (final d in _downloads.values.toList()) {
      final source = d.source;
      if (source != null && !peers.contains(source)) {
        await _dropSource(d);
      } else if (d.state == BlobState.searching) {
        await _ask(d, force: true);
      }
    }
  }

  // ---------------------------------------------------------------------
  // Sharing
  // ---------------------------------------------------------------------

  Future<void> _serve(String sha, String to, int from, int count) async {
    final path = await pathFor(sha);
    final send = _send;
    final me = await _me?.call();
    if (path == null || send == null || me == null) return;
    final file = File(path);
    final size = await file.length();
    final total = chunkCountFor(size);
    if (from < 0 || from >= total) return;
    final end = min(total, from + count.clamp(1, window));

    // A newer request from the same device replaces this one.
    final key = '$sha|$to';
    final generation = (_serving[key] ?? 0) + 1;
    _serving[key] = generation;

    final raf = await file.open();
    try {
      for (var i = from; i < end; i++) {
        if (_serving[key] != generation) return;
        await raf.setPosition(i * chunkSize);
        final bytes = await raf.read(min(chunkSize, size - i * chunkSize));
        final sent = await send(to, <String, Object?>{
          't': 'bdat',
          'h': sha,
          'to': to,
          'from': me,
          'i': i,
          'data': base64Encode(bytes),
        });
        if (!sent) return;
      }
    } finally {
      await raf.close();
      if (_serving[key] == generation) _serving.remove(key);
    }
  }

  /// `bwho` / `bhave` / `bget` / `bdat` from a device in range.
  Future<void> handlePacket(Map<String, Object?> packet) async {
    final sha = packet['h'];
    final from = packet['from'];
    if (sha is! String || !PostAttachment.shaPattern.hasMatch(sha)) return;
    if (from is! String || from.isEmpty) return;
    switch (packet['t']) {
      case 'bwho':
        final me = await _me?.call();
        final send = _send;
        if (me == null || send == null || from == me) return;
        if (await pathFor(sha) == null) return;
        await send(from, <String, Object?>{
          't': 'bhave',
          'h': sha,
          'to': from,
          'from': me,
        });
      case 'bhave':
        await _onHave(sha, from);
      case 'bget':
        final i = packet['i'];
        final n = packet['n'];
        if (i is int && n is int) await _serve(sha, from, i, n);
      case 'bdat':
        final i = packet['i'];
        final data = packet['data'];
        if (i is int && data is String) await _onData(sha, from, i, data);
    }
  }
}

class _Download {
  _Download({required this.sha, required this.size, required this.ext});

  final String sha;
  final int size;
  final String ext;
  int get total => BlobService.chunkCountFor(size);

  BlobState state = BlobState.searching;

  /// Whole chunks written to the partial file, in order.
  int have = 0;
  int requestedUntil = 0;

  String? source;
  final Set<String> sources = <String>{};

  /// Devices whose bytes failed the hash check.
  final Set<String> bad = <String>{};

  final Map<int, Uint8List> pending = <int, Uint8List>{};
  Future<void> writes = Future<void>.value();
  RandomAccessFile? raf;

  int lastActivityMs = 0;
  int lastAskMs = 0;
  int stalls = 0;

  Future<void> close() async {
    final open = raf;
    raf = null;
    if (open == null) return;
    try {
      await open.close();
    } catch (_) {}
  }
}
