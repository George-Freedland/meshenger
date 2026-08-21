import 'dart:async';

/// A local, serverless transport that discovers nearby peers and moves
/// packets (JSON maps) between directly-reachable devices.
///
/// Implementations: Bluetooth LE (works with no network at all) and LAN
/// (UDP discovery + TCP delivery on the same Wi-Fi network/hotspot).
///
/// Transports are deliberately dumb pipes: they verify peer announcements
/// (so `onlinePeers` only contains proven identities) and move opaque
/// packets. Encryption, decryption, relaying, and gossip all live above
/// the transport in [MessengerService], which lets any node — including a
/// headless Raspberry Pi gateway — forward envelopes it cannot read.
abstract class MeshTransport {
  bool get isRunning;

  /// Addresses (base64 Ed25519 public keys) currently reachable directly.
  Set<String> get onlinePeers;

  /// Signal strength (RSSI, dBm) per reachable address, when the transport
  /// can measure it (Bluetooth). Empty for transports without signal info.
  Map<String, int> get peerRssi;

  /// The X25519 encryption key a directly-reachable peer announced, or null
  /// when the peer is unknown/offline.
  String? x25519For(String peerAddress);

  /// Every well-formed JSON packet received from any peer: encrypted
  /// message envelopes (`t: msg`, whether or not addressed to me) and
  /// gossip records (`t: gossip`).
  Stream<Map<String, Object?>> get onPacket;

  Stream<Set<String>> get onPeersChanged;

  /// Starts discovery and inbound packet handling.
  /// Requires the identity to be unlocked.
  Future<void> start();

  Future<void> stop();

  /// Delivers [packet] to a directly-reachable peer. Returns true when the
  /// peer's device acknowledged accepting the packet (transport-level ack;
  /// end-to-end delivery is confirmed separately with encrypted acks).
  Future<bool> sendPacket(String peerAddress, Map<String, Object?> packet);
}
