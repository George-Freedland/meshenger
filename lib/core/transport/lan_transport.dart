import 'dart:async';

import '../models/incoming_message.dart';

import 'lan_transport_stub.dart'
    if (dart.library.io) 'lan_transport_io.dart' as impl;

/// Offline transport that discovers peers on the local network (UDP
/// broadcast) and delivers end-to-end encrypted messages over TCP.
///
/// This is the first of several planned local transports (Bluetooth mesh,
/// standalone gateways). It requires no internet: two devices on the same
/// Wi-Fi network or hotspot can exchange messages directly.
abstract class LanTransport {
  bool get isRunning;

  /// Addresses (base64 Ed25519 public keys) currently visible on the LAN.
  Set<String> get onlinePeers;

  Stream<IncomingMessage> get onMessage;

  Stream<Set<String>> get onPeersChanged;

  /// Starts discovery and the inbound message server.
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

LanTransport createLanTransport() => impl.createTransport();
