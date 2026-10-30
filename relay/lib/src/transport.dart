/// A link layer the relay can move packets over. Mirrors the app's
/// MeshTransport: verified peer discovery + opaque JSON packets. All
/// routing decisions live in RelayCore.
abstract class RelayTransport {
  /// Short label for logs (e.g. "ble").
  String get name;

  /// Mesh addresses (base64 Ed25519 keys) directly reachable right now.
  Set<String> get onlinePeers;

  /// Every well-formed JSON packet received from any peer.
  Stream<Map<String, Object?>> get onPacket;

  /// Fires with the new peer set whenever a peer appears or disappears.
  Stream<Set<String>> get onPeersChanged;

  Future<void> start();

  Future<void> stop();

  /// Delivers [packet] to a directly reachable peer. True only when the
  /// peer's device acknowledged accepting it.
  Future<bool> sendPacket(String peerAddress, Map<String, Object?> packet);
}
