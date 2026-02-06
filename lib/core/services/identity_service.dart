import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Manages the user's cryptographic identity.
///
/// Identity model:
/// - Ed25519 keypair for identity (public key is the "address")
/// - Private key stored encrypted under a key derived from the password
class IdentityService {
  IdentityService._();
  static final IdentityService instance = IdentityService._();

  static const _storage = FlutterSecureStorage();

  static const _publicKeyKey = 'identity_public_key';
  static const _encryptedPrivateKeyKey = 'identity_encrypted_private_key';
  static const _saltKey = 'identity_kdf_salt';

  // In-memory unlocked keys (for current session only).
  SimpleKeyPair? _identityKeyPair;
  SimplePublicKey? _publicKey;

  SimplePublicKey? get publicKey => _publicKey;

  bool get isUnlocked => _identityKeyPair != null;

  /// Creates a new identity and stores it encrypted.
  Future<void> createIdentity(String password) async {
    // 1) Generate Ed25519 identity keypair
    final ed25519 = Ed25519();
    final keyPair = await ed25519.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();

    // 2) Derive symmetric key from password using PBKDF2
    final salt = _randomBytes(16);
    final secretKey = await _deriveKeyFromPassword(password, salt);

    // 3) Encrypt private key bytes using AES-GCM
    final algorithm = AesGcm.with256bits();
    final nonce = _randomBytes(12);
    final secretKeyBytes = await secretKey.extractBytes();

    final encrypted = await algorithm.encrypt(
      privateKey,
      secretKey: SecretKey(secretKeyBytes),
      nonce: nonce,
    );

    final payload = <String, dynamic>{
      'nonce': base64Encode(nonce),
      'cipherText': base64Encode(encrypted.cipherText),
      'mac': base64Encode(encrypted.mac.bytes),
    };

    // 4) Persist to secure storage
    await _storage.write(
      key: _publicKeyKey,
      value: base64Encode(publicKey.bytes),
    );
    await _storage.write(
      key: _encryptedPrivateKeyKey,
      value: jsonEncode(payload),
    );
    await _storage.write(
      key: _saltKey,
      value: base64Encode(salt),
    );

    // 5) Keep unlocked in memory for current run
    _identityKeyPair = keyPair;
    _publicKey = publicKey;
  }

  /// Attempts to unlock an existing identity using [password].
  ///
  /// Returns true if unlock succeeded, false if identity is missing
  /// or password is incorrect.
  Future<bool> unlockIdentity(String password) async {
    final encodedPublicKey = await _storage.read(key: _publicKeyKey);
    final encryptedJson = await _storage.read(key: _encryptedPrivateKeyKey);
    final encodedSalt = await _storage.read(key: _saltKey);

    if (encodedPublicKey == null ||
        encryptedJson == null ||
        encodedSalt == null) {
      return false;
    }

    try {
      final salt = base64Decode(encodedSalt);
      final secretKey = await _deriveKeyFromPassword(password, salt);
      final secretKeyBytes = await secretKey.extractBytes();

      final Map<String, dynamic> payload =
          jsonDecode(encryptedJson) as Map<String, dynamic>;

      final nonce = base64Decode(payload['nonce'] as String);
      final cipherText = base64Decode(payload['cipherText'] as String);
      final macBytes = base64Decode(payload['mac'] as String);

      final algorithm = AesGcm.with256bits();
      final secretBox = SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(macBytes),
      );

      final privateKeyBytes = await algorithm.decrypt(
        secretBox,
        secretKey: SecretKey(secretKeyBytes),
      );

      _identityKeyPair = SimpleKeyPairData(
        privateKeyBytes,
        publicKey: SimplePublicKey(
          base64Decode(encodedPublicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      );

      _publicKey = await _identityKeyPair!.extractPublicKey();

      return true;
    } catch (_) {
      // Most likely wrong password or tampered storage.
      _identityKeyPair = null;
      return false;
    }
  }

  /// Generates random bytes using [Random.secure].
  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<SecretKey> _deriveKeyFromPassword(
    String password,
    List<int> salt,
  ) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: 150000,
      bits: 256,
    );
    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return secretKey;
  }
}

