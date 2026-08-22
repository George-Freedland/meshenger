import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'identity_scope.dart';

/// Where a media item came from.
enum MediaSource { import_, camera, memo, received, sent }

class MediaItem {
  final String id;
  final String name;
  final String mime;
  final int sizeBytes;
  final int createdMs;
  final MediaSource source;

  /// View-once media (hidden from the Storage library, deleted after view).
  final bool temp;

  /// Audio duration when known.
  final int? durationMs;

  const MediaItem({
    required this.id,
    required this.name,
    required this.mime,
    required this.sizeBytes,
    required this.createdMs,
    required this.source,
    this.temp = false,
    this.durationMs,
  });

  bool get isImage => mime.startsWith('image/');
  bool get isAudio => mime.startsWith('audio/');

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'mime': mime,
        'size': sizeBytes,
        'ts': createdMs,
        'src': source.name,
        if (temp) 'temp': true,
        if (durationMs != null) 'dur': durationMs,
      };

  static MediaItem fromJson(Map<String, Object?> json) => MediaItem(
        id: json['id'] as String,
        name: json['name'] as String,
        mime: json['mime'] as String,
        sizeBytes: (json['size'] as num?)?.toInt() ?? 0,
        createdMs: (json['ts'] as num?)?.toInt() ?? 0,
        source: MediaSource.values.firstWhere(
          (s) => s.name == json['src'],
          orElse: () => MediaSource.import_,
        ),
        temp: json['temp'] == true,
        durationMs: (json['dur'] as num?)?.toInt(),
      );
}

/// Identity-scoped media library backed by files on disk.
///
/// Files live in `<app support>/media/<identity fingerprint>/`, metadata in
/// SharedPreferences. Used by the Storage, Camera, and Voice Memos apps and
/// by chat attachments (sent copies and received media land here).
class MediaStore {
  MediaStore._();
  static final MediaStore instance = MediaStore._();

  static const _libraryKey = 'media_library_v1';
  static const int maxTransferBytes = 8 * 1024 * 1024; // mesh payload cap

  final _uuid = const Uuid();
  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  Future<Directory> _dir() async {
    final fp = IdentityScope.activeFingerprint;
    if (fp == null) throw StateError('No active identity');
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/media/$fp');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _extensionFor(String mime, String name) {
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx > 0 && dotIdx < name.length - 1) {
      return name.substring(dotIdx + 1).toLowerCase();
    }
    return switch (mime) {
      'image/jpeg' => 'jpg',
      'image/png' => 'png',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      'audio/mp4' || 'audio/aac' || 'audio/m4a' => 'm4a',
      'audio/mpeg' => 'mp3',
      'audio/wav' => 'wav',
      _ => 'bin',
    };
  }

  Future<File> fileFor(MediaItem item) async {
    final dir = await _dir();
    return File('${dir.path}/${item.id}.${_extensionFor(item.mime, item.name)}');
  }

  Future<MediaItem?> get(String id) async {
    final items = await _readAll();
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// Absolute file path for a stored item, or null when missing.
  Future<String?> pathFor(String id) async {
    final item = await get(id);
    if (item == null) return null;
    final file = await fileFor(item);
    return await file.exists() ? file.path : null;
  }

  Future<Uint8List?> readBytes(String id) async {
    final path = await pathFor(id);
    if (path == null) return null;
    return File(path).readAsBytes();
  }

  Future<MediaItem> saveBytes(
    Uint8List bytes, {
    required String name,
    required String mime,
    required MediaSource source,
    bool temp = false,
    int? durationMs,
  }) async {
    final item = MediaItem(
      id: _uuid.v4(),
      name: name,
      mime: mime,
      sizeBytes: bytes.length,
      createdMs: DateTime.now().millisecondsSinceEpoch,
      source: source,
      temp: temp,
      durationMs: durationMs,
    );
    final file = await fileFor(item);
    await file.writeAsBytes(bytes, flush: true);

    final items = await _readAll();
    items.add(item);
    await _writeAll(items);
    _changed.add(null);
    return item;
  }

  /// Registers an existing file by *moving* it into the library — no
  /// bytes pass through memory, so multi-GB files (completed P2P
  /// transfers) are adopted instantly.
  Future<MediaItem> adoptFile(
    String sourcePath, {
    required String name,
    required String mime,
    required MediaSource source,
  }) async {
    final sourceFile = File(sourcePath);
    final item = MediaItem(
      id: _uuid.v4(),
      name: name,
      mime: mime,
      sizeBytes: await sourceFile.length(),
      createdMs: DateTime.now().millisecondsSinceEpoch,
      source: source,
    );
    final dest = await fileFor(item);
    try {
      await sourceFile.rename(dest.path);
    } on FileSystemException {
      // Cross-device move: fall back to copy + delete.
      await sourceFile.copy(dest.path);
      await sourceFile.delete();
    }

    final items = await _readAll();
    items.add(item);
    await _writeAll(items);
    _changed.add(null);
    return item;
  }

  Future<void> delete(String id) async {
    final items = await _readAll();
    final idx = items.indexWhere((i) => i.id == id);
    if (idx < 0) return;
    final item = items.removeAt(idx);
    try {
      final file = await fileFor(item);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Metadata removal is what matters; stray files get cleaned next run.
    }
    await _writeAll(items);
    _changed.add(null);
  }

  /// Library listing (view-once items are hidden — they belong to chats).
  Future<List<MediaItem>> list({MediaSource? source}) async {
    final items = await _readAll();
    return items
        .where((i) => !i.temp && (source == null || i.source == source))
        .toList()
      ..sort((a, b) => b.createdMs.compareTo(a.createdMs));
  }

  Future<int> totalBytes() async {
    final items = await _readAll();
    var total = 0;
    for (final item in items) {
      total += item.sizeBytes;
    }
    return total;
  }

  Future<List<MediaItem>> _readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_libraryKey));
    if (raw == null || raw.isEmpty) return <MediaItem>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <MediaItem>[];
    return decoded
        .whereType<Map>()
        .map((m) => MediaItem.fromJson(m.cast<String, Object?>()))
        .toList();
  }

  Future<void> _writeAll(List<MediaItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_libraryKey),
      jsonEncode(items.map((i) => i.toJson()).toList()),
    );
  }
}
