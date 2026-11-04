import 'dart:convert';
import 'dart:typed_data';

/// How a packet (a JSON map) travels over a link.
///
/// Everyone understands UTF-8 JSON. Between apps that announce
/// [binaryCapability], a packet's long base64 fields travel as raw bytes
/// instead, a quarter fewer bytes on air. The receiver turns them back
/// into the exact same strings, so nothing above the transport (signatures,
/// spools, relays) can tell the difference.
///
/// Binary frame: `0xB1`, the header's length (uint32, big-endian), the
/// header (the packet as JSON, minus the moved fields, plus `_b`: a list
/// of `[field, byteLength]`), then those fields' bytes in order.
abstract final class PacketFrame {
  static const String binaryCapability = 'b1';
  static const int binaryMarker = 0xB1;

  /// Shorter strings aren't worth moving.
  static const int minBinaryField = 256;

  static const String _fieldsKey = '_b';

  static Uint8List encodeJson(Map<String, Object?> packet) =>
      Uint8List.fromList(utf8.encode(jsonEncode(packet)));

  static Uint8List encodeBinary(Map<String, Object?> packet) {
    final header = <String, Object?>{};
    final fields = <List<Object>>[];
    final bytes = <Uint8List>[];
    packet.forEach((key, value) {
      final raw = value is String ? _canonicalBase64(value) : null;
      if (raw == null) {
        header[key] = value;
      } else {
        fields.add(<Object>[key, raw.length]);
        bytes.add(raw);
      }
    });
    if (bytes.isEmpty) return encodeJson(packet);
    header[_fieldsKey] = fields;
    final head = utf8.encode(jsonEncode(header));
    final length = ByteData(4)..setUint32(0, head.length);
    final out = BytesBuilder(copy: false)
      ..addByte(binaryMarker)
      ..add(length.buffer.asUint8List())
      ..add(head);
    for (final field in bytes) {
      out.add(field);
    }
    return out.takeBytes();
  }

  /// The bytes behind [value] when encoding them again gives back exactly
  /// [value]; null for anything else (text, URL-safe or unpadded base64).
  static Uint8List? _canonicalBase64(String value) {
    if (value.length < minBinaryField || value.length % 4 != 0) return null;
    try {
      final raw = base64Decode(value);
      return base64Encode(raw) == value ? raw : null;
    } on FormatException {
      return null;
    }
  }

  /// The packet in [payload] (either form), or null when it isn't one.
  static Map<String, Object?>? decode(Uint8List payload) {
    try {
      if (payload.isNotEmpty && payload[0] == binaryMarker) {
        return _decodeBinary(payload);
      }
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is Map && decoded['t'] is String) {
        return decoded.cast<String, Object?>();
      }
    } catch (_) {}
    return null;
  }

  static Map<String, Object?>? _decodeBinary(Uint8List payload) {
    if (payload.length < 5) return null;
    final headLength = ByteData.sublistView(payload, 1, 5).getUint32(0);
    var offset = 5 + headLength;
    if (offset > payload.length) return null;
    final decoded =
        jsonDecode(utf8.decode(Uint8List.sublistView(payload, 5, offset)));
    if (decoded is! Map || decoded['t'] is! String) return null;
    final packet = decoded.cast<String, Object?>();
    final fields = packet.remove(_fieldsKey);
    if (fields is! List) return null;
    for (final field in fields) {
      if (field is! List || field.length != 2) return null;
      final key = field[0];
      final length = field[1];
      if (key is! String || length is! int || length < 0) return null;
      if (offset + length > payload.length) return null;
      packet[key] =
          base64Encode(Uint8List.sublistView(payload, offset, offset + length));
      offset += length;
    }
    return offset == payload.length ? packet : null;
  }
}
