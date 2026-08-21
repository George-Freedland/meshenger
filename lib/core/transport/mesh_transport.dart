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

  /// Signal strength (RSSI, dBm) per reachable address, when the transport
  /// can measure it (Bluetooth). Empty for transports without signal info.
  Map<String, int> get peerRssi;

  Stream<IncomingMessage> get onMessage;

  Stream<Set<String>> get onPeersChanged;

  /// Starts discovery and inbound message handling.
  /// Requires the identity to be unlocked.
  Future<void> start();

  Future<void> stop();

  /// Attempts direct delivery to [peerAddress].
  ///
  /// [groupId]/[groupMembers]/[groupAdmin]/[groupName]/[groupEvent] tag
  /// group traffic; [action]/[targetId] carry message-level operations
  /// (edit/delete/story); [ttlSeconds] requests receiver-side auto-delete.
  ///
  /// Returns true only if the peer acknowledged receipt.
  Future<bool> sendMessage({
    required String peerAddress,
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
  });
}
