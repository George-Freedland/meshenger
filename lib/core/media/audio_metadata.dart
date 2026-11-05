import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// What an audio file says about itself: tags, cover art and length.
class AudioMetadata {
  const AudioMetadata({
    this.title,
    this.artist,
    this.album,
    this.art,
    this.artMime,
    this.duration,
  });

  final String? title;
  final String? artist;
  final String? album;

  /// Embedded cover image (front cover when the file has several).
  final Uint8List? art;
  final String? artMime;
  final Duration? duration;

  static const empty = AudioMetadata();

  AudioMetadata _withDuration(Duration? d) => AudioMetadata(
        title: title,
        artist: artist,
        album: album,
        art: art,
        artMime: artMime,
        duration: duration ?? d,
      );

  AudioMetadata _fillFrom(AudioMetadata other) => AudioMetadata(
        title: title ?? other.title,
        artist: artist ?? other.artist,
        album: album ?? other.album,
        art: art ?? other.art,
        artMime: artMime ?? other.artMime,
        duration: duration ?? other.duration,
      );
}

/// Reads tags from MP3 (ID3v2.2–2.4 and ID3v1), M4A/MP4 (iTunes atoms) and
/// FLAC. Only headers are read, so even huge files are cheap. Never throws:
/// unknown or damaged files give [AudioMetadata.empty].
Future<AudioMetadata> readAudioMetadata(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final length = await raf.length();
    if (length < 4) return AudioMetadata.empty;
    final head = await _readAt(raf, 0, min(length, 12));

    if (_ascii(head, 0, 4) == 'fLaC') return await _readFlac(raf, length);
    if (head.length >= 8 && _ascii(head, 4, 8) == 'ftyp') {
      return await _readMp4(raf, length);
    }

    var meta = AudioMetadata.empty;
    var audioStart = 0;
    if (_ascii(head, 0, 3) == 'ID3' && head.length >= 10) {
      final tagSize =
          _syncsafe(head, 6) + 10 + ((head[5] & 0x10) != 0 ? 10 : 0);
      // Cover art can be large, but a tag past 32 MB is not a tag.
      final tag = await _readAt(raf, 0, min(tagSize, min(length, 32 << 20)));
      meta = parseId3v2(tag) ?? AudioMetadata.empty;
      audioStart = tagSize;
    }
    var hasId3v1 = false;
    if (length >= 128) {
      final tail = await _readAt(raf, length - 128, 128);
      final v1 = parseId3v1(tail);
      if (v1 != null) {
        hasId3v1 = true;
        meta = meta._fillFrom(v1);
      }
    }
    if (meta.duration == null && audioStart < length) {
      final frames =
          await _readAt(raf, audioStart, min(64 * 1024, length - audioStart));
      final audioBytes = length - audioStart - (hasId3v1 ? 128 : 0);
      meta = meta._withDuration(mp3Duration(frames, audioBytes: audioBytes));
    }
    return meta;
  } catch (_) {
    return AudioMetadata.empty;
  } finally {
    await raf?.close();
  }
}

Future<Uint8List> _readAt(RandomAccessFile raf, int offset, int count) async {
  await raf.setPosition(offset);
  return raf.read(count);
}

// ---------------------------------------------------------------------------
// ID3
// ---------------------------------------------------------------------------

/// Parses an ID3v2 tag ([data] starts at the "ID3" header).
AudioMetadata? parseId3v2(Uint8List data) {
  if (data.length < 10 || _ascii(data, 0, 3) != 'ID3') return null;
  final major = data[3];
  if (major < 2 || major > 4) return null;
  final flags = data[5];
  final size = _syncsafe(data, 6);
  var body = Uint8List.sublistView(data, 10, min(data.length, 10 + size));
  // v2.2/2.3 unsynchronise the whole tag; v2.4 does it per frame.
  if (major < 4 && (flags & 0x80) != 0) body = _deunsync(body);

  var pos = 0;
  if (major >= 3 && (flags & 0x40) != 0 && body.length >= 4) {
    // v2.3 counts the size field out of the extended header, v2.4 in.
    pos = major == 4 ? _syncsafe(body, 0) : _u32be(body, 0) + 4;
  }

  final idLength = major == 2 ? 3 : 4;
  final headerLength = major == 2 ? 6 : 10;
  String? title, artist, album;
  Uint8List? art;
  String? artMime;
  var artIsFront = false;
  Duration? length;

  while (pos + headerLength <= body.length) {
    if (body[pos] == 0) break; // padding
    final id = _ascii(body, pos, pos + idLength);
    final int frameSize;
    var frameFlags = 0;
    if (major == 2) {
      frameSize = (body[pos + 3] << 16) | (body[pos + 4] << 8) | body[pos + 5];
    } else {
      frameSize = major == 4 ? _syncsafe(body, pos + 4) : _u32be(body, pos + 4);
      frameFlags = (body[pos + 8] << 8) | body[pos + 9];
    }
    final start = pos + headerLength;
    final end = start + frameSize;
    if (frameSize <= 0 || end > body.length) break;
    pos = end;

    var frame = Uint8List.sublistView(body, start, end);
    if (major == 4) {
      if ((frameFlags & 0x000C) != 0) continue; // compressed or encrypted
      if ((frameFlags & 0x0001) != 0) {
        if (frame.length < 4) continue;
        frame = Uint8List.sublistView(frame, 4); // data length indicator
      }
      if ((frameFlags & 0x0002) != 0) frame = _deunsync(frame);
    } else if (major == 3) {
      if ((frameFlags & 0x00C0) != 0) continue; // compressed or encrypted
      if ((frameFlags & 0x0020) != 0) {
        if (frame.isEmpty) continue;
        frame = Uint8List.sublistView(frame, 1); // grouping id
      }
    }

    switch (id) {
      case 'TIT2' || 'TT2':
        title ??= _textFrame(frame);
      case 'TPE1' || 'TP1':
        artist ??= _textFrame(frame);
      case 'TALB' || 'TAL':
        album ??= _textFrame(frame);
      case 'TLEN' || 'TLE':
        final ms = int.tryParse(_textFrame(frame) ?? '');
        if (ms != null && ms > 0) length = Duration(milliseconds: ms);
      case 'APIC' || 'PIC':
        if (artIsFront) continue;
        final picture = id == 'PIC' ? _picV22(frame) : _apic(frame);
        if (picture == null) continue;
        if (art == null || picture.$3 == 3) {
          art = picture.$1;
          artMime = picture.$2;
          artIsFront = picture.$3 == 3;
        }
    }
  }

  return AudioMetadata(
    title: title,
    artist: artist,
    album: album,
    art: art,
    artMime: artMime,
    duration: length,
  );
}

/// Parses the 128-byte ID3v1 tag at the end of an MP3.
AudioMetadata? parseId3v1(Uint8List tail) {
  if (tail.length < 128 || _ascii(tail, 0, 3) != 'TAG') return null;
  String? field(int from, int to) {
    final value = latin1
        .decode(tail.sublist(from, to), allowInvalid: true)
        .replaceAll('\u0000', ' ')
        .trim();
    return value.isEmpty ? null : value;
  }

  return AudioMetadata(
    title: field(3, 33),
    artist: field(33, 63),
    album: field(63, 93),
  );
}

String? _textFrame(Uint8List frame) {
  if (frame.length < 2) return null;
  final text = _decodeText(Uint8List.sublistView(frame, 1), frame[0]);
  // v2.4 separates multiple values with NUL; show the first.
  for (final part in text.split('\u0000')) {
    final value = part.trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}

String _decodeText(Uint8List bytes, int encoding) {
  switch (encoding) {
    case 1:
      if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return _utf16(Uint8List.sublistView(bytes, 2), littleEndian: false);
      }
      if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return _utf16(Uint8List.sublistView(bytes, 2), littleEndian: true);
      }
      return _utf16(bytes, littleEndian: true);
    case 2:
      return _utf16(bytes, littleEndian: false);
    case 3:
      return utf8.decode(bytes, allowMalformed: true);
    default:
      return latin1.decode(bytes, allowInvalid: true);
  }
}

String _utf16(Uint8List bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

/// Index just past a NUL-terminated string in [encoding] starting at [from].
int _skipString(Uint8List bytes, int from, int encoding) {
  if (encoding == 1 || encoding == 2) {
    for (var i = from; i + 1 < bytes.length; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) return i + 2;
    }
    return bytes.length;
  }
  final end = bytes.indexOf(0, from);
  return end < 0 ? bytes.length : end + 1;
}

/// v2.3/2.4 APIC: encoding, MIME, picture type, description, image.
(Uint8List, String, int)? _apic(Uint8List frame) {
  if (frame.length < 4) return null;
  final encoding = frame[0];
  final mimeEnd = frame.indexOf(0, 1);
  if (mimeEnd < 0 || mimeEnd + 2 > frame.length) return null;
  final mime = latin1.decode(frame.sublist(1, mimeEnd), allowInvalid: true);
  final type = frame[mimeEnd + 1];
  final dataStart = _skipString(frame, mimeEnd + 2, encoding);
  if (dataStart >= frame.length) return null;
  final data = Uint8List.fromList(frame.sublist(dataStart));
  return (data, _imageMime(data, mime), type);
}

/// v2.2 PIC: encoding, 3-letter format, picture type, description, image.
(Uint8List, String, int)? _picV22(Uint8List frame) {
  if (frame.length < 6) return null;
  final encoding = frame[0];
  final format = _ascii(frame, 1, 4);
  final type = frame[4];
  final dataStart = _skipString(frame, 5, encoding);
  if (dataStart >= frame.length) return null;
  final data = Uint8List.fromList(frame.sublist(dataStart));
  return (data, _imageMime(data, 'image/${format.toLowerCase()}'), type);
}

/// Trusts the image's own magic bytes over whatever the tag claims.
String _imageMime(Uint8List data, String claimed) {
  if (data.length >= 3 && data[0] == 0xFF && data[1] == 0xD8) {
    return 'image/jpeg';
  }
  if (data.length >= 4 &&
      data[0] == 0x89 &&
      data[1] == 0x50 &&
      data[2] == 0x4E &&
      data[3] == 0x47) {
    return 'image/png';
  }
  final lower = claimed.toLowerCase();
  if (lower == 'image/jpg' || lower == 'jpg') return 'image/jpeg';
  return lower.contains('/') ? lower : 'image/$lower';
}

Uint8List _deunsync(Uint8List data) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < data.length; i++) {
    out.addByte(data[i]);
    if (data[i] == 0xFF && i + 1 < data.length && data[i + 1] == 0x00) i++;
  }
  return out.toBytes();
}

// ---------------------------------------------------------------------------
// MP3 length
// ---------------------------------------------------------------------------

const _bitratesV1 = <List<int>>[
  [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
  [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
];
const _bitratesV2 = <List<int>>[
  [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
  [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
  [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
];
const _sampleRates = <List<int>>[
  [44100, 48000, 32000], // MPEG 1
  [22050, 24000, 16000], // MPEG 2
  [11025, 12000, 8000], // MPEG 2.5
];

class _MpegFrame {
  _MpegFrame({
    required this.mpeg1,
    required this.layer,
    required this.bitrateKbps,
    required this.sampleRate,
    required this.mono,
    required this.length,
  });

  final bool mpeg1;
  final int layer; // 1, 2 or 3
  final int bitrateKbps;
  final int sampleRate;
  final bool mono;
  final int length;

  int get samplesPerFrame =>
      layer == 1 ? 384 : (layer == 3 && !mpeg1 ? 576 : 1152);

  /// Layer III side information, which the Xing header follows.
  int get sideInfoLength => mpeg1 ? (mono ? 17 : 32) : (mono ? 9 : 17);

  static _MpegFrame? at(Uint8List b, int i) {
    if (i + 4 > b.length || b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) {
      return null;
    }
    final versionBits = (b[i + 1] >> 3) & 0x3;
    final layerBits = (b[i + 1] >> 1) & 0x3;
    final bitrateIndex = b[i + 2] >> 4;
    final rateIndex = (b[i + 2] >> 2) & 0x3;
    final padding = (b[i + 2] >> 1) & 0x1;
    if (versionBits == 1 || layerBits == 0) return null;
    if (bitrateIndex == 0 || bitrateIndex == 15 || rateIndex == 3) return null;
    final mpeg1 = versionBits == 3;
    final layer = 4 - layerBits;
    final bitrate =
        (mpeg1 ? _bitratesV1 : _bitratesV2)[layer - 1][bitrateIndex];
    final sampleRate =
        _sampleRates[mpeg1 ? 0 : (versionBits == 2 ? 1 : 2)][rateIndex];
    final int length;
    if (layer == 1) {
      length = (12 * bitrate * 1000 ~/ sampleRate + padding) * 4;
    } else {
      final factor = layer == 3 && !mpeg1 ? 72 : 144;
      length = factor * bitrate * 1000 ~/ sampleRate + padding;
    }
    return _MpegFrame(
      mpeg1: mpeg1,
      layer: layer,
      bitrateKbps: bitrate,
      sampleRate: sampleRate,
      mono: (b[i + 3] >> 6) == 3,
      length: length,
    );
  }
}

/// Length of an MP3 from its first frames: exact from a Xing/Info or VBRI
/// header when present, otherwise estimated from the bitrate.
/// [audioBytes] is the size of the audio data (file minus tags).
Duration? mp3Duration(Uint8List frames, {required int audioBytes}) {
  for (var i = 0; i + 4 <= frames.length; i++) {
    final frame = _MpegFrame.at(frames, i);
    if (frame == null) continue;
    // A real frame is followed by another one; random bytes rarely are.
    final next = i + frame.length;
    if (next + 4 <= frames.length && _MpegFrame.at(frames, next) == null) {
      continue;
    }

    Duration fromFrames(int count) => Duration(
        microseconds:
            count * frame.samplesPerFrame * 1000000 ~/ frame.sampleRate);

    if (frame.layer == 3) {
      final xing = i + 4 + frame.sideInfoLength;
      if (xing + 12 <= frames.length) {
        final tag = _ascii(frames, xing, xing + 4);
        if ((tag == 'Xing' || tag == 'Info') &&
            (_u32be(frames, xing + 4) & 0x1) != 0) {
          return fromFrames(_u32be(frames, xing + 8));
        }
      }
    }
    final vbri = i + 36;
    if (vbri + 18 <= frames.length &&
        _ascii(frames, vbri, vbri + 4) == 'VBRI') {
      return fromFrames(_u32be(frames, vbri + 14));
    }
    final bytes = audioBytes - i;
    if (bytes <= 0) return null;
    return Duration(milliseconds: bytes * 8 ~/ frame.bitrateKbps);
  }
  return null;
}

// ---------------------------------------------------------------------------
// MP4 / M4A
// ---------------------------------------------------------------------------

Future<AudioMetadata> _readMp4(RandomAccessFile raf, int length) async {
  var pos = 0;
  while (pos + 8 <= length) {
    final header = await _readAt(raf, pos, 16);
    if (header.length < 8) break;
    var size = _u32be(header, 0);
    final type = _ascii(header, 4, 8);
    var headerSize = 8;
    if (size == 1 && header.length >= 16) {
      size = _u64be(header, 8);
      headerSize = 16;
    } else if (size == 0) {
      size = length - pos;
    }
    if (size < headerSize) break;
    if (type == 'moov') {
      final moov = await _readAt(
          raf, pos + headerSize, min(size - headerSize, 32 << 20));
      return parseMp4Moov(moov);
    }
    pos += size;
  }
  return AudioMetadata.empty;
}

/// Parses the contents of a `moov` atom: `mvhd` for the length and the
/// iTunes `ilst` items for tags and cover.
AudioMetadata parseMp4Moov(Uint8List moov) {
  Duration? duration;
  String? title, artist, album;
  Uint8List? art;
  String? artMime;

  void walk(Uint8List box, int from, int to) {
    var pos = from;
    while (pos + 8 <= to) {
      final size = _u32be(box, pos);
      final type = _ascii(box, pos + 4, pos + 8);
      final end = size == 0 ? to : pos + size;
      if ((size < 8 && size != 0) || end > to) return;
      switch (type) {
        case 'mvhd':
          final version = box[pos + 8];
          if (version == 1 && pos + 40 <= end) {
            final timescale = _u32be(box, pos + 28);
            final units = _u64be(box, pos + 32);
            if (timescale > 0) {
              duration = Duration(microseconds: units * 1000000 ~/ timescale);
            }
          } else if (pos + 28 <= end) {
            final timescale = _u32be(box, pos + 20);
            final units = _u32be(box, pos + 24);
            if (timescale > 0) {
              duration = Duration(microseconds: units * 1000000 ~/ timescale);
            }
          }
        case 'udta' || 'ilst':
          walk(box, pos + 8, end);
        case 'meta':
          // iTunes writes `meta` as a full box (4 bytes of version and
          // flags before the children); newer QuickTime files don't.
          final fullBox = pos + 16 <= end &&
              _ascii(box, pos + 12, pos + 16) != 'hdlr' &&
              _u32be(box, pos + 8) == 0;
          walk(box, pos + (fullBox ? 12 : 8), end);
        case '\u00a9nam' || '\u00a9ART' || '\u00a9alb' || 'aART' || 'covr':
          final data = _mp4Data(box, pos + 8, end);
          if (data == null) break;
          final (kind, value) = data;
          switch (type) {
            case '\u00a9nam':
              title ??= _mp4Text(value);
            case '\u00a9ART':
              artist ??= _mp4Text(value);
            case 'aART':
              artist ??= _mp4Text(value);
            case '\u00a9alb':
              album ??= _mp4Text(value);
            case 'covr':
              if (art == null && value.isNotEmpty) {
                final image = Uint8List.fromList(value);
                art = image;
                artMime =
                    _imageMime(image, kind == 14 ? 'image/png' : 'image/jpeg');
              }
          }
      }
      pos = end;
    }
  }

  walk(moov, 0, moov.length);
  return AudioMetadata(
    title: title,
    artist: artist,
    album: album,
    art: art,
    artMime: artMime,
    duration: duration,
  );
}

/// The first `data` atom inside an `ilst` item: (type code, value bytes).
(int, Uint8List)? _mp4Data(Uint8List box, int from, int to) {
  var pos = from;
  while (pos + 16 <= to) {
    final size = _u32be(box, pos);
    if (size < 16 || pos + size > to) return null;
    if (_ascii(box, pos + 4, pos + 8) == 'data') {
      final kind = _u32be(box, pos + 8) & 0xFFFFFF;
      return (kind, Uint8List.sublistView(box, pos + 16, pos + size));
    }
    pos += size;
  }
  return null;
}

String? _mp4Text(Uint8List value) {
  final text = utf8.decode(value, allowMalformed: true).trim();
  return text.isEmpty ? null : text;
}

// ---------------------------------------------------------------------------
// FLAC
// ---------------------------------------------------------------------------

Future<AudioMetadata> _readFlac(RandomAccessFile raf, int length) async {
  var pos = 4;
  Duration? duration;
  String? title, artist, album;
  Uint8List? art;
  String? artMime;
  var artIsFront = false;

  while (pos + 4 <= length) {
    final header = await _readAt(raf, pos, 4);
    if (header.length < 4) break;
    final last = (header[0] & 0x80) != 0;
    final type = header[0] & 0x7F;
    final size = (header[1] << 16) | (header[2] << 8) | header[3];
    final start = pos + 4;
    if (start + size > length) break;

    if (type == 0 && size >= 18) {
      final info = await _readAt(raf, start, 18);
      final rate = (info[10] << 12) | (info[11] << 4) | (info[12] >> 4);
      final samples = ((info[13] & 0x0F) << 32) |
          (info[14] << 24) |
          (info[15] << 16) |
          (info[16] << 8) |
          info[17];
      if (rate > 0 && samples > 0) {
        duration = Duration(microseconds: samples * 1000000 ~/ rate);
      }
    } else if (type == 4) {
      final block = await _readAt(raf, start, size);
      final comments = parseVorbisComments(block);
      title ??= comments['TITLE'];
      artist ??= comments['ARTIST'];
      album ??= comments['ALBUM'];
    } else if (type == 6 && !artIsFront && size < (32 << 20)) {
      final block = await _readAt(raf, start, size);
      final picture = _flacPicture(block);
      if (picture != null && (art == null || picture.$3 == 3)) {
        art = picture.$1;
        artMime = picture.$2;
        artIsFront = picture.$3 == 3;
      }
    }
    pos = start + size;
    if (last) break;
  }
  return AudioMetadata(
    title: title,
    artist: artist,
    album: album,
    art: art,
    artMime: artMime,
    duration: duration,
  );
}

/// Vorbis comments (FLAC, Ogg): `KEY=value` pairs, keys upper-cased. The
/// first value wins for repeated keys.
Map<String, String> parseVorbisComments(Uint8List block) {
  final out = <String, String>{};
  if (block.length < 8) return out;
  var pos = 0;
  final vendorLength = _u32le(block, pos);
  pos += 4 + vendorLength;
  if (pos + 4 > block.length) return out;
  final count = _u32le(block, pos);
  pos += 4;
  for (var i = 0; i < count && pos + 4 <= block.length; i++) {
    final length = _u32le(block, pos);
    pos += 4;
    if (pos + length > block.length) break;
    final entry =
        utf8.decode(block.sublist(pos, pos + length), allowMalformed: true);
    pos += length;
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    final value = entry.substring(eq + 1).trim();
    if (value.isEmpty) continue;
    out.putIfAbsent(entry.substring(0, eq).toUpperCase(), () => value);
  }
  return out;
}

(Uint8List, String, int)? _flacPicture(Uint8List block) {
  if (block.length < 32) return null;
  var pos = 0;
  final type = _u32be(block, pos);
  pos += 4;
  final mimeLength = _u32be(block, pos);
  pos += 4;
  if (pos + mimeLength > block.length) return null;
  final mime =
      latin1.decode(block.sublist(pos, pos + mimeLength), allowInvalid: true);
  pos += mimeLength;
  if (pos + 4 > block.length) return null;
  final descLength = _u32be(block, pos);
  pos += 4 + descLength + 16; // description, width, height, depth, colors
  if (pos + 4 > block.length) return null;
  final dataLength = _u32be(block, pos);
  pos += 4;
  if (dataLength <= 0 || pos + dataLength > block.length) return null;
  final data = Uint8List.fromList(block.sublist(pos, pos + dataLength));
  return (data, _imageMime(data, mime), type);
}

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

String _ascii(List<int> b, int from, int to) {
  if (to > b.length) return '';
  return String.fromCharCodes(b.sublist(from, to));
}

int _syncsafe(List<int> b, int i) =>
    ((b[i] & 0x7F) << 21) |
    ((b[i + 1] & 0x7F) << 14) |
    ((b[i + 2] & 0x7F) << 7) |
    (b[i + 3] & 0x7F);

int _u32be(List<int> b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

int _u32le(List<int> b, int i) =>
    b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

int _u64be(List<int> b, int i) => (_u32be(b, i) << 32) | _u32be(b, i + 4);
