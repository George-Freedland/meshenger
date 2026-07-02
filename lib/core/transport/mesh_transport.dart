import 'dart:async';

import '../models/incoming_message.dart';

/// A local, serverless transport that discovers nearby peers and delivers
/// end-to-end encrypted messages directly to them.
///
/// Implementations: Bluetooth LE (works with no network at all) and LAN
/// (UDP discovery + TCP delivery on the same Wi-Fi network/hotspot).
abstract class MeshTransport {
  bool get isRunning;

  /// Addresses (base64 Ed25519 public keys) currently reachable.
  Set<String> get onlinePeers;

  Stream<IncomingMessage> get onMessage;

  Stream<Set<String>> get onPeersChanged;

  /// Starts discovery and inbound message handling.
  /// Requires the identity to be unlocked.
  Future<void> start();

  Future<void> stop();

  /// Attempts direct delivery to [peerAddress].
  ///
  /// Returns true only if the peer acknowledged receipt.
  Future<bool> sendMessage({
    required String peerAddress,
    required String messageId,
    required String text,
    required DateTime timestamp,
  });
}
