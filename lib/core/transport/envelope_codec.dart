import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../models/incoming_message.dart';
import '../services/identity_service.dart';

/// A verified peer identity learned from a signed announcement.
class PeerIdentity {
  final String address; // base64 Ed25519 public key
  final String x25519Base64; // base64 X25519 public key

  const PeerIdentity({required this.address, required this.x25519Base64});
}

/// Shared message envelope crypto used by every transport (LAN, Bluetooth).
///
/// Envelope: AES-256-GCM ciphertext under an X25519 ECDH shared key,
/// signed with the sender's Ed25519 identity key. Any relay only ever
/// sees ciphertext.
class EnvelopeCodec {
  EnvelopeCodec._();

  static Future<SecretKey> sharedKeyWith(String theirX25519Base64) async {
    final myKeyPair = await IdentityService.instance.getAgreementKeyPair();
    final shared = await X25519().sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(
        base64Decode(theirX25519Base64),
        type: KeyPairType.x25519,
      ),
    );
    // Hash the raw ECDH output into a uniform AES key.
    final hashed = await Sha256().hash(await shared.extractBytes());
    return SecretKey(hashed.bytes);
  }

  static Future<String> myX25519Base64() async {
    final keyPair = await IdentityService.instance.getAgreementKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return base64Encode(publicKey.bytes);
  }

  /// Builds the encrypted + signed message envelope.
  ///
  /// [groupId], [groupMembers], [groupAdmin], and [groupName] are included
  /// inside the encrypted body for group messages and group metadata events.
  static Future<Map<String, Object?>> encryptEnvelope({
    required String from,
    required String to,
    required String toX25519Base64,
    required String messageId,
    required String text,
    required DateTime timestamp,
    String? groupId,
    List<String>? groupMembers,
    String? groupAdmin,
    String? groupName,
    String? groupEvent,
    String? action,
    String? targetId,
    int? ttlSeconds,
  }) async {
    final sharedKey = await sharedKeyWith(toX25519Base64);

    final plaintext = utf8.encode(jsonEncode(<String, Object?>{
      'id': messageId,
      'text': text,
      'ts': timestamp.millisecondsSinceEpoch,
      if (groupId != null) 'gid': groupId,
      if (groupMembers != null) 'members': groupMembers,
      if (groupAdmin != null) 'admin': groupAdmin,
      if (groupName != null) 'gname': groupName,
      if (groupEvent != null) 'gevt': groupEvent,
      if (action != null) 'act': action,
      if (targetId != null) 'target': targetId,
      if (ttlSeconds != null) 'ttl': ttlSeconds,
    }));

    final algorithm = AesGcm.with256bits();
    final secretBox = await algorithm.encrypt(plaintext, secretKey: sharedKey);

    final nonceB64 = base64Encode(secretBox.nonce);
    final cipherB64 = base64Encode(secretBox.cipherText);
    final macB64 = base64Encode(secretBox.mac.bytes);
    final myX = await myX25519Base64();

    final signature = await IdentityService.instance.sign(
      utf8.encode('msg|$from|$to|$messageId|$nonceB64|$cipherB64|$macB64'),
    );

    return <String, Object?>{
      't': 'msg',
      'from': from,
      'to': to,
      'fromX': myX,
      'id': messageId,
      'nonce': nonceB64,
      'cipher': cipherB64,
      'mac': macB64,
      'sig': base64Encode(signature.bytes),
    };
  }

  /// Verifies the signature and decrypts a received envelope.
  ///
  /// Returns null when the envelope is malformed, not addressed to
  /// [myAddress], has a bad signature, or fails to decrypt.
  static Future<IncomingMessage?> decryptEnvelope(
    Map<Object?, Object?> decoded, {
    required String myAddress,
  }) async {
    try {
      if (decoded['t'] != 'msg') return null;

      final from = decoded['from'] as String;
      final to = decoded['to'] as String;
      final fromX = decoded['fromX'] as String;
      final id = decoded['id'] as String;
      final nonceB64 = decoded['nonce'] as String;
      final cipherB64 = decoded['cipher'] as String;
      final macB64 = decoded['mac'] as String;
      final sigB64 = decoded['sig'] as String;

      if (to != myAddress) return null;

      final valid = await IdentityService.verify(
        message: utf8.encode('msg|$from|$to|$id|$nonceB64|$cipherB64|$macB64'),
        signatureBytes: base64Decode(sigB64),
        publicKeyBase64: from,
      );
      if (!valid) return null;

      final sharedKey = await sharedKeyWith(fromX);
      final plainBytes = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(cipherB64),
          nonce: base64Decode(nonceB64),
          mac: Mac(base64Decode(macB64)),
        ),
        secretKey: sharedKey,
      );

      final body = jsonDecode(utf8.decode(plainBytes)) as Map;
      return IncomingMessage(
        fromAddress: from,
        id: body['id'] as String,
        text: body['text'] as String? ?? '',
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (body['ts'] as num).toInt(),
        ),
        groupId: body['gid'] as String?,
        groupMembers:
            (body['members'] as List?)?.whereType<String>().toList(),
        groupAdmin: body['admin'] as String?,
        groupName: body['gname'] as String?,
        groupEvent: body['gevt'] as String?,
        action: body['act'] as String?,
        targetId: body['target'] as String?,
        ttlSeconds: (body['ttl'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Bluetooth announcements (no host/port, signed over a fixed context)
  // -----------------------------------------------------------------------

  static Future<Uint8List> buildBleAnnouncementBytes() async {
    final identity = IdentityService.instance;
    final address = await identity.getPublicAddressBase64();
    if (address == null || !identity.isUnlocked) {
      throw StateError('Identity must be unlocked');
    }
    final x25519 = await myX25519Base64();
    final signature =
        await identity.sign(utf8.encode('announce|$address|$x25519|ble'));

    return Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
      't': 'announce',
      'addr': address,
      'x25519': x25519,
      'sig': base64Encode(signature.bytes),
    })));
  }

  static Future<PeerIdentity?> verifyBleAnnouncementBytes(
    Uint8List bytes,
  ) async {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map || decoded['t'] != 'announce') return null;

      final addr = decoded['addr'] as String?;
      final x25519 = decoded['x25519'] as String?;
      final sig = decoded['sig'] as String?;
      if (addr == null || x25519 == null || sig == null) return null;

      final valid = await IdentityService.verify(
        message: utf8.encode('announce|$addr|$x25519|ble'),
        signatureBytes: base64Decode(sig),
        publicKeyBase64: addr,
      );
      if (!valid) return null;

      return PeerIdentity(address: addr, x25519Base64: x25519);
    } catch (_) {
      return null;
    }
  }
}
