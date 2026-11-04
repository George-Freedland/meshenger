import 'dart:async';

/// What services send through: [MeshTransport.sendPacket], wired in by
/// MessengerService.
typedef PacketSender = Future<bool> Function(
  String peer,
  Map<String, Object?> packet, {
  bool bulk,
});

/// A local, serverless transport that discovers nearby peers and moves
/// packets (JSON maps) between directly-reachable devices.
///
/// Implemented by the Bluetooth LE transport, which works with no network
/// at all.
///
/// Transports are deliberately dumb pipes: they verify peer announcements
/// (so `onlinePeers` only contains proven identities) and move opaque
/// packets. Encryption, decryption, relaying, and gossip all live above
/// the transport in [MessengerService], which lets any node — including a
/// headless Raspberry Pi gateway — forward envelopes it cannot read.
abstract class MeshTransport {
  bool get isRunning;

  /// Non-fatal degradation the user should know about (e.g. Bluetooth
  /// running central-only because this adapter cannot advertise — the
  /// device can discover others but is not discoverable itself). Null when
  /// the transport is fully operational.
  String? get startupWarning;

  /// When true the device stays out of sight: it does not advertise, and
  /// the hellos it writes ask peers to keep it off their maps. It can still
  /// discover others, send, and receive over the channels it opens. Set
  /// before [start].
  abstract bool invisible;

  /// Addresses (base64 Ed25519 public keys) currently reachable directly.
  Set<String> get onlinePeers;

  /// The subset of [onlinePeers] that asked to stay hidden (invisible
  /// mode): reachable for delivery, but not to be shown.
  Set<String> get hiddenPeers;

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

  /// Forgets discovery backoffs and scans the surroundings again right away.
  Future<void> rescan();

  /// Delivers [packet] to a directly-reachable peer. Returns true when the
  /// peer's device acknowledged accepting the packet (transport-level ack;
  /// end-to-end delivery is confirmed separately with encrypted acks).
  ///
  /// [bulk] packets (file chunks) skip that ack and return once the radio
  /// has taken them: the transfer protocols above confirm and re-request on
  /// their own, and waiting on every packet would halve their speed.
  Future<bool> sendPacket(
    String peerAddress,
    Map<String, Object?> packet, {
    bool bulk = false,
  });
}
