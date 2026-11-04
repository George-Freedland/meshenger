import 'dart:convert';

/// A file attached to a Network post. The post carries this description;
/// the bytes are identified by [sha256] and come from whichever device has
/// them (see BlobService), unless the file is small enough to ride inside
/// the post itself.
class PostAttachment {
  const PostAttachment({
    required this.name,
    required this.mime,
    required this.size,
    required this.sha256,
    this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.pieces,
  });

  final String name;
  final String mime;
  final int size;

  /// Lowercase hex SHA-256 of the file: its identity on the mesh, and how
  /// a download is checked.
  final String sha256;

  // Audio tags, so a song shows nicely before anyone downloads it.
  final String? title;
  final String? artist;
  final String? album;

  /// Playing time of a song or video.
  final int? durationMs;

  /// Hash of the file's piece list (see BlobService), which lets every
  /// chunk be checked on arrival and the file play while it downloads.
  /// Older apps ignore it.
  final String? pieces;

  static final RegExp shaPattern = RegExp(r'^[0-9a-f]{64}$');

  bool get isAudio => mime.startsWith('audio/');
  bool get isImage => mime.startsWith('image/');
  bool get isVideo => mime.startsWith('video/');

  /// Everything this attachment keeps in BlobService.
  List<String> get blobs => [sha256, if (pieces != null) pieces!];

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'mime': mime,
        'size': size,
        'sha': sha256,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (album != null) 'album': album,
        if (durationMs != null) 'dur': durationMs,
        if (pieces != null) 'pcs': pieces,
      };

  /// Null for anything malformed (it may have come from a stranger).
  static PostAttachment? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final mime = json['mime'];
    final size = json['size'];
    final sha = json['sha'];
    if (name is! String || name.trim().isEmpty || name.length > 255) {
      return null;
    }
    if (mime is! String || !mime.contains('/') || mime.length > 127) {
      return null;
    }
    if (size is! int || size <= 0) return null;
    if (sha is! String || !shaPattern.hasMatch(sha)) return null;
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty && value.length <= 300
            ? value.trim()
            : null;
    final dur = json['dur'];
    final pieces = json['pcs'];
    return PostAttachment(
      name: name.trim(),
      mime: mime,
      size: size,
      sha256: sha,
      title: text(json['title']),
      artist: text(json['artist']),
      album: text(json['album']),
      durationMs: dur is int && dur > 0 ? dur : null,
      pieces: pieces is String && shaPattern.hasMatch(pieces) ? pieces : null,
    );
  }

  /// Canonical text form: signed verbatim, so no re-encoding can break the
  /// signature.
  String encode() => jsonEncode(toJson());

  static PostAttachment? decode(String text) {
    try {
      return fromJson(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }
}
