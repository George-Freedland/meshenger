import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The relay's own keypair. It signs presence announcements and gossip so
/// peers can prove who they're talking to — it holds NO message keys and
/// can never decrypt the envelopes it forwards.
class RelayIdentity {
  final SimpleKeyPair _keyPair;

  /// Base64 Ed25519 public key — the relay's mesh address.
  final String address;

  /// Base64 X25519 public key (same deterministic derivation as the app).
  final String x25519;

  RelayIdentity._(this._keyPair, this.address, this.x25519);

  static Future<RelayIdentity> loadOrCreate(String path) async {
    final ed25519 = Ed25519();
    final file = File(path);
    SimpleKeyPair keyPair;
    var created = false;
    if (await file.exists()) {
      final decoded = jsonDecode(await file.readAsString()) as Map;
      final seed = base64Decode(decoded['seed'] as String);
      keyPair = await ed25519.newKeyPairFromSeed(seed);
    } else {
      keyPair = await ed25519.newKeyPair();
      final seed = await keyPair.extractPrivateKeyBytes();
      await file.writeAsString(jsonEncode({'seed': base64Encode(seed)}));
      created = true;
    }

    final publicKey = await keyPair.extractPublicKey();
    final address = base64Encode(publicKey.bytes);

    final seed = await keyPair.extractPrivateKeyBytes();
    final derived = await Sha256().hash(<int>[
      ...utf8.encode('meshenger-x25519-v1'),
      ...seed,
    ]);
    final x = await X25519().newKeyPairFromSeed(derived.bytes);
    final xPub = await x.extractPublicKey();

    final identity =
        RelayIdentity._(keyPair, address, base64Encode(xPub.bytes));
    if (created) {
      stdout.writeln('Created new relay identity at $path');
    }
    return identity;
  }

  Future<String> sign(String message) async {
    final signature =
        await Ed25519().sign(utf8.encode(message), keyPair: _keyPair);
    return base64Encode(signature.bytes);
  }

  /// Verifies an Ed25519 signature made by [addressBase64].
  static Future<bool> verify(
    String message,
    String signatureBase64,
    String addressBase64,
  ) async {
    try {
      final publicKey = SimplePublicKey(
        base64Decode(addressBase64),
        type: KeyPairType.ed25519,
      );
      return await Ed25519().verify(
        utf8.encode(message),
        signature:
            Signature(base64Decode(signatureBase64), publicKey: publicKey),
      );
    } catch (_) {
      return false;
    }
  }

  /// The signed BLE announcement served on the announce characteristic —
  /// byte-identical format to the app's.
  Future<Uint8List> bleAnnouncementBytes() async {
    final sig = await sign('announce|$address|$x25519|ble');
    return Uint8List.fromList(utf8.encode(jsonEncode(<String, Object?>{
      't': 'announce',
      'addr': address,
      'x25519': x25519,
      'sig': sig,
    })));
  }
}
