import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

/// One saved identity (profile) on this device.
class StoredIdentity {
  final String publicKey; // base64 Ed25519 (the address)
  final String encryptedPrivateKey; // JSON payload (nonce/cipherText/mac)
  final String salt; // base64 PBKDF2 salt
  final String? nickname;
  final int avatarId;

  const StoredIdentity({
    required this.publicKey,
    required this.encryptedPrivateKey,
    required this.salt,
    this.nickname,
    this.avatarId = 0,
  });

  StoredIdentity copyWith({String? nickname, int? avatarId}) => StoredIdentity(
        publicKey: publicKey,
        encryptedPrivateKey: encryptedPrivateKey,
        salt: salt,
        nickname: nickname ?? this.nickname,
        avatarId: avatarId ?? this.avatarId,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'pub': publicKey,
        'priv': encryptedPrivateKey,
        'salt': salt,
        'nickname': nickname,
        'avatar': avatarId,
      };

  static StoredIdentity fromJson(Map<String, Object?> json) => StoredIdentity(
        publicKey: json['pub'] as String,
        encryptedPrivateKey: json['priv'] as String,
        salt: json['salt'] as String,
        nickname: json['nickname'] as String?,
        avatarId: (json['avatar'] as num?)?.toInt() ?? 0,
      );
}

/// Manages the device's identities (Netflix-style profiles).
///
/// Each identity is an Ed25519 keypair; the private key is stored encrypted
/// under a password-derived key. All chat/contact/settings data is scoped
/// per identity via [IdentityScope], so profiles never see each other's data.
class IdentityService {
  IdentityService._();
  static final IdentityService instance = IdentityService._();

  // The macOS data-protection keychain requires a real Apple development
  // signing certificate; ad-hoc signed local builds get errSecMissingEntitlement
  // (-34018). The legacy file-based keychain works without one.
  static const _storage = FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  static const _identitiesKey = 'identities_v2';

  // Pre-multi-profile storage (single identity + unscoped data).
  static const _legacyPublicKeyKey = 'identity_public_key';
  static const _legacyPrivateKeyKey = 'identity_encrypted_private_key';
  static const _legacySaltKey = 'identity_kdf_salt';
  static const _legacyNicknameKey = 'profile_nickname_v1';

  // In-memory unlocked keys (for current session only).
  SimpleKeyPair? _identityKeyPair;
  SimplePublicKey? _publicKey;
  SimpleKeyPair? _agreementKeyPair; // X25519, derived from identity seed
  StoredIdentity? _active;

  SimplePublicKey? get publicKey => _publicKey;

  bool get isUnlocked => _identityKeyPair != null;

  /// The unlocked profile's metadata (nickname, avatar).
  StoredIdentity? get active => _active;

  // ---------------------------------------------------------------------
  // Registry
  // ---------------------------------------------------------------------

  Future<List<StoredIdentity>> listIdentities() async {
    await _migrateLegacyIfNeeded();
    final raw = await _storage.read(key: _identitiesKey);
    if (raw == null || raw.isEmpty) return <StoredIdentity>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <StoredIdentity>[];
    return decoded
        .whereType<Map>()
        .map((m) => StoredIdentity.fromJson(m.cast<String, Object?>()))
        .toList();
  }

  Future<void> _writeIdentities(List<StoredIdentity> identities) async {
    await _storage.write(
      key: _identitiesKey,
      value: jsonEncode(identities.map((i) => i.toJson()).toList()),
    );
  }

  /// Migrates the old single-identity storage into the registry, and claims
  /// all previously unscoped chat/contact data for that identity.
  Future<void> _migrateLegacyIfNeeded() async {
    final existing = await _storage.read(key: _identitiesKey);
    if (existing != null) return;

    final pub = await _storage.read(key: _legacyPublicKeyKey);
    final priv = await _storage.read(key: _legacyPrivateKeyKey);
    final salt = await _storage.read(key: _legacySaltKey);
    if (pub == null || priv == null || salt == null) return;

    final prefs = await SharedPreferences.getInstance();
    final nickname = prefs.getString(_legacyNicknameKey);

    await _writeIdentities([
      StoredIdentity(
        publicKey: pub,
        encryptedPrivateKey: priv,
        salt: salt,
        nickname: nickname,
      ),
    ]);
    await _migrateLegacyPrefsData(pub);

    await _storage.delete(key: _legacyPublicKeyKey);
    await _storage.delete(key: _legacyPrivateKeyKey);
    await _storage.delete(key: _legacySaltKey);
    await prefs.remove(_legacyNicknameKey);
  }

  /// Moves unscoped data keys under the migrated identity's namespace.
  Future<void> _migrateLegacyPrefsData(String publicKeyBase64) async {
    final prefs = await SharedPreferences.getInstance();
    final fp = IdentityScope.fingerprintOf(publicKeyBase64);

    const exact = <String>{
      'chats_v1',
      'chats_unread_v1',
      'contacts_v1',
      'allow_messages_from_anyone_v1',
      'transport_mode_v1',
    };
    const prefixes = <String>[
      'chat_messages_v1:',
      'group_meta_v2:',
      'group_info_v1:',
    ];

    for (final key in prefs.getKeys().toList()) {
      final matches =
          exact.contains(key) || prefixes.any((p) => key.startsWith(p));
      if (!matches) continue;
      final value = prefs.get(key);
      final scoped = 'u:$fp:$key';
      if (value is String) await prefs.setString(scoped, value);
      if (value is bool) await prefs.setBool(scoped, value);
      await prefs.remove(key);
    }
  }

  // ---------------------------------------------------------------------
  // Create / unlock / lock
  // ---------------------------------------------------------------------

  /// Creates a new identity, adds it to the registry, and unlocks it.
  Future<void> createIdentity({
    required String password,
    String? nickname,
    int avatarId = 0,
  }) async {
    final ed25519 = Ed25519();
    final keyPair = await ed25519.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();

    final salt = _randomBytes(16);
    final secretKey = await _deriveKeyFromPassword(password, salt);

    final algorithm = AesGcm.with256bits();
    final nonce = _randomBytes(12);
    final encrypted = await algorithm.encrypt(
      privateKey,
      secretKey: SecretKey(await secretKey.extractBytes()),
      nonce: nonce,
    );

    final payload = jsonEncode(<String, dynamic>{
      'nonce': base64Encode(nonce),
      'cipherText': base64Encode(encrypted.cipherText),
      'mac': base64Encode(encrypted.mac.bytes),
    });

    final trimmedNickname = nickname?.trim();
    final entry = StoredIdentity(
      publicKey: base64Encode(publicKey.bytes),
      encryptedPrivateKey: payload,
      salt: base64Encode(salt),
      nickname: (trimmedNickname == null || trimmedNickname.isEmpty)
          ? null
          : trimmedNickname,
      avatarId: avatarId,
    );

    final identities = await listIdentities();
    identities.add(entry);
    await _writeIdentities(identities);

    _identityKeyPair = keyPair;
    _publicKey = publicKey;
    _agreementKeyPair = null;
    _active = entry;
    IdentityScope.setActive(entry.publicKey);
  }

  /// Unlocks the identity whose address is [publicKey] using [password].
  Future<bool> unlockIdentity({
    required String publicKey,
    required String password,
  }) async {
    final identities = await listIdentities();
    StoredIdentity? entry;
    for (final identity in identities) {
      if (identity.publicKey == publicKey) {
        entry = identity;
        break;
      }
    }
    if (entry == null) return false;

    try {
      final salt = base64Decode(entry.salt);
      final secretKey = await _deriveKeyFromPassword(password, salt);

      final Map<String, dynamic> payload =
          jsonDecode(entry.encryptedPrivateKey) as Map<String, dynamic>;

      final privateKeyBytes = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(payload['cipherText'] as String),
          nonce: base64Decode(payload['nonce'] as String),
          mac: Mac(base64Decode(payload['mac'] as String)),
        ),
        secretKey: SecretKey(await secretKey.extractBytes()),
      );

      _identityKeyPair = SimpleKeyPairData(
        privateKeyBytes,
        publicKey: SimplePublicKey(
          base64Decode(entry.publicKey),
          type: KeyPairType.ed25519,
        ),
        type: KeyPairType.ed25519,
      );
      _publicKey = await _identityKeyPair!.extractPublicKey();
      _agreementKeyPair = null;
      _active = entry;
      IdentityScope.setActive(entry.publicKey);
      return true;
    } catch (_) {
      // Wrong password or tampered storage.
      _identityKeyPair = null;
      return false;
    }
  }

  /// Locks the current identity (logout). Clears all in-memory key material.
  void lock() {
    _identityKeyPair = null;
    _publicKey = null;
    _agreementKeyPair = null;
    _active = null;
    IdentityScope.clear();
  }

  /// Updates nickname/avatar for the unlocked profile.
  Future<void> updateActiveProfile({String? nickname, int? avatarId}) async {
    final current = _active;
    if (current == null) throw StateError('Identity is locked');

    final identities = await listIdentities();
    final idx =
        identities.indexWhere((i) => i.publicKey == current.publicKey);
    if (idx < 0) return;

    final trimmed = nickname?.trim();
    final updated = identities[idx].copyWith(
      nickname: trimmed == null ? null : (trimmed.isEmpty ? null : trimmed),
      avatarId: avatarId,
    );
    identities[idx] = updated;
    await _writeIdentities(identities);
    _active = updated;
  }

  // ---------------------------------------------------------------------
  // Crypto operations
  // ---------------------------------------------------------------------

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
  /// from the identity seed so it is stable across sessions.
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

  /// Returns the unlocked identity's public address as base64, or null.
  Future<String?> getPublicAddressBase64() async {
    final pk = _publicKey;
    if (pk != null) {
      return base64Encode(pk.bytes);
    }
    return null;
  }

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
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }
}
