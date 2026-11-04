import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../models/post_attachment.dart';
import '../services/blob_service.dart';
import '../transport/envelope_codec.dart';
import 'audio_metadata.dart';

/// A file ready to attach to a Network post.
class PreparedPostFile {
  const PreparedPostFile({
    required this.path,
    required this.attachment,
    this.inlineBytes,
    this.cover,
    this.pieceList,
  });

  final String path;
  final PostAttachment attachment;

  /// The whole file, when it is small enough to ride inside the post.
  final Uint8List? inlineBytes;

  /// Cover art small enough to embed (JPEG or PNG).
  final Uint8List? cover;

  /// Every chunk's hash (see BlobService); its own hash goes in the post.
  final Uint8List? pieceList;
}

/// MP4-family videos keep their playing time where the audio tag reader
/// looks; other containers it would misread.
const Set<String> _mp4Videos = {'video/mp4', 'video/quicktime', 'video/x-m4v'};

/// Hashes [path], reads an audio file's tags and cover (or a video's
/// length), and keeps small files' bytes for embedding. Streams the file,
/// so any size works.
Future<PreparedPostFile> preparePostFile({
  required String path,
  required String name,
  required String mime,
}) async {
  final size = await File(path).length();
  if (size == 0) throw StateError('That file is empty');
  final (sha, pieceList) = await BlobService.hashFile(path);
  final inline = size <= EnvelopeCodec.maxInlineFileBytes;
  final withPieces = !inline && size <= BlobService.maxPiecesFileBytes;
  var meta = AudioMetadata.empty;
  Uint8List? cover;
  if (mime.startsWith('audio/')) {
    meta = await readAudioMetadata(path);
    final art = meta.art;
    if (art != null) cover = await coverForPost(art);
  } else if (_mp4Videos.contains(mime)) {
    final length = (await readAudioMetadata(path)).duration;
    meta = AudioMetadata(duration: length);
  }
  return PreparedPostFile(
    path: path,
    attachment: PostAttachment(
      name: name,
      mime: mime,
      size: size,
      sha256: sha,
      title: meta.title,
      artist: meta.artist,
      album: meta.album,
      durationMs: meta.duration?.inMilliseconds,
      pieces: withPieces ? await BlobService.sha256OfBytes(pieceList) : null,
    ),
    inlineBytes: inline ? await File(path).readAsBytes() : null,
    cover: cover,
    pieceList: withPieces ? pieceList : null,
  );
}

/// Cover art that fits in a post: the original when it already does,
/// otherwise a JPEG scaled down to [maxSide] pixels. Null when the image
/// can't be decoded.
Future<Uint8List?> coverForPost(
  Uint8List art, {
  int maxBytes = EnvelopeCodec.maxPostArtBytes,
  int maxSide = 320,
}) async {
  final isJpeg = art.length > 2 && art[0] == 0xFF && art[1] == 0xD8;
  final isPng = art.length > 4 && art[0] == 0x89 && art[1] == 0x50;
  if (art.length <= maxBytes && (isJpeg || isPng)) return art;
  try {
    final buffer = await ui.ImmutableBuffer.fromUint8List(art);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final scale = min(1.0, maxSide / max(descriptor.width, descriptor.height));
    final width = max(1, (descriptor.width * scale).round());
    final height = max(1, (descriptor.height * scale).round());
    final codec = await descriptor.instantiateCodec(
        targetWidth: width, targetHeight: height);
    final frame = await codec.getNextFrame();
    final rgba =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    frame.image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    if (rgba == null) return null;
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    for (final quality in const [82, 68, 52]) {
      final jpeg = img.encodeJpg(image, quality: quality);
      if (jpeg.length <= maxBytes) return jpeg;
    }
    return null;
  } catch (_) {
    return null;
  }
}
