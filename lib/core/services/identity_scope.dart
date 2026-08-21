/// Namespaces all locally stored data (chats, contacts, settings, stories)
/// by the active identity, so different identities on the same device never
/// see each other's data.
class IdentityScope {
  IdentityScope._();

  static String? _fingerprint;

  static bool get hasActive => _fingerprint != null;

  /// Fingerprint of the active identity (used for per-identity folders).
  static String? get activeFingerprint => _fingerprint;

  static void setActive(String publicKeyBase64) {
    _fingerprint = fingerprintOf(publicKeyBase64);
  }

  static void clear() {
    _fingerprint = null;
  }

  static String fingerprintOf(String publicKeyBase64) {
    final clean = publicKeyBase64.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return clean.length <= 16 ? clean : clean.substring(0, 16);
  }

  /// Returns the storage key for [base] under the active identity.
  static String key(String base) {
    final f = _fingerprint;
    if (f == null) {
      throw StateError('No active identity');
    }
    return 'u:$f:$base';
  }
}
