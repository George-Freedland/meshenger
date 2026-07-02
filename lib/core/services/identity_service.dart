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

  // The macOS data-protection keychain requires a real Apple development
  // signing certificate; ad-hoc signed local builds get errSecMissingEntitlement
  // (-34018). The legacy file-based keychain works without one.
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  static const _publicKeyKey = 'identity_public_key';
  static const _encryptedPrivateKeyKey = 'identity_encrypted_private_key';
  static const _saltKey = 'identity_kdf_salt';

  // In-memory unlocked keys (for current session only).
  SimpleKeyPair? _identityKeyPair;
  SimplePublicKey? _publicKey;
  SimpleKeyPair? _agreementKeyPair; // X25519, derived from identity seed

  SimplePublicKey? get publicKey => _publicKey;

  bool get isUnlocked => _identityKeyPair != null;

  /// Signs [message] with the unlocked Ed25519 identity key.
  Future<Signature> sign(List<int> message) async {
    final keyPair = _identityKeyPair;
    if (keyPair == null) {
      throw StateError('Identity is locked');
    }
    return Ed25519().sign(message, keyPair: keyPair);
  }

  /// Verifies an Ed25519 [signature] over [message] made by [publicKeyBase64].
  static Future<bool> verify({
    required List<int> message,
    required List<int> signatureBytes,
    required String publicKeyBase64,
  }) async {
    try {
      final publicKey = SimplePublicKey(
        base64Decode(publicKeyBase64),
        type: KeyPairType.ed25519,
      );
      return await Ed25519().verify(
        message,
        signature: Signature(signatureBytes, publicKey: publicKey),
      );
    } catch (_) {
      return false;
    }
  }

  /// X25519 keypair for encryption key agreement, deterministically derived
  /// from the identity seed so it is stable across sessions and devices only
  /// need the Ed25519 address to authenticate it (announcements are signed).
  Future<SimpleKeyPair> getAgreementKeyPair() async {
    final existing = _agreementKeyPair;
    if (existing != null) return existing;

    final identity = _identityKeyPair;
    if (identity == null) {
      throw StateError('Identity is locked');
    }

    final seed = await identity.extractPrivateKeyBytes();
    final derived = await Sha256().hash(<int>[
      ...utf8.encode('meshenger-x25519-v1'),
      ...seed,
    ]);
    final keyPair = await X25519().newKeyPairFromSeed(derived.bytes);
    _agreementKeyPair = keyPair;
    return keyPair;
  }

  /// Returns the public address as a base64 string.
  ///
  /// If the identity is currently unlocked, this uses the in-memory public key.
  /// Otherwise, it reads the persisted public key from secure storage.
  Future<String?> getPublicAddressBase64() async {
    final pk = _publicKey;
    if (pk != null) {
      return base64Encode(pk.bytes);
    }
    return _storage.read(key: _publicKeyKey);
  }

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

