import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'identity_scope.dart';

/// A node known to exist somewhere in the mesh.
class KnownPeer {
  final String address; // base64 Ed25519 public key
  final String x25519Base64; // base64 X25519 encryption key
  final String? nickname; // self-chosen public name from gossip
  final int hops; // 0 = seen directly, N = via N relays
  final int lastSeenMs;

  const KnownPeer({
    required this.address,
    required this.x25519Base64,
    required this.nickname,
    required this.hops,
    required this.lastSeenMs,
  });

  bool get isDirect => hops == 0;

  Map<String, Object?> toJson() => <String, Object?>{
        'addr': address,
        'x': x25519Base64,
        if (nickname != null) 'nick': nickname,
        'hops': hops,
        'seen': lastSeenMs,
      };

  static KnownPeer fromJson(Map<String, Object?> json) => KnownPeer(
        address: json['addr'] as String,
        x25519Base64: json['x'] as String,
        nickname: json['nick'] as String?,
        hops: (json['hops'] as num?)?.toInt() ?? 0,
        lastSeenMs: (json['seen'] as num?)?.toInt() ?? 0,
      );
}

/// Directory of every node this device has learned about — directly (radio
/// range) or through gossip relayed across the mesh.
///
/// This is what makes true mesh messaging possible: to encrypt to someone
/// you have never met directly, you need their X25519 key, which arrives
/// here via gossip. It also powers the Mesh Map's extended-network view.
class PeerDirectory {
  PeerDirectory._();
  static final PeerDirectory instance = PeerDirectory._();

  static const _directoryKey = 'peer_directory_v1';

  /// Entries older than this stop being listed as "recently known".
  static const Duration freshWindow = Duration(minutes: 30);

  Map<String, KnownPeer>? _cache;
  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  /// Records a node seen directly by a transport (announcement verified).
  Future<void> recordDirect(
    String address,
    String x25519Base64, {
    String? nickname,
  }) =>
      _record(address, x25519Base64,
          nickname: nickname, hops: 0, tsMs: DateTime.now().millisecondsSinceEpoch);

  /// Records a node learned via verified gossip. Returns true when the
  /// record was new or fresher than what we had (callers re-flood those).
  Future<bool> recordGossip(
    String address,
    String x25519Base64, {
    String? nickname,
    required int hops,
    required int tsMs,
  }) async {
    final existing = (await _read())[address];
    if (existing != null && existing.lastSeenMs >= tsMs) return false;
    await _record(address, x25519Base64,
        nickname: nickname, hops: hops, tsMs: tsMs);
    return true;
  }

  Future<void> _record(
    String address,
    String x25519Base64, {
    String? nickname,
    required int hops,
    required int tsMs,
  }) async {
    final peers = await _read();
    final existing = peers[address];
    peers[address] = KnownPeer(
      address: address,
      x25519Base64: x25519Base64,
      nickname: nickname ?? existing?.nickname,
      // Keep the best (lowest) hop count we've seen recently.
      hops: existing != null && existing.hops < hops && _isFresh(existing)
          ? existing.hops
          : hops,
      lastSeenMs: tsMs,
    );
    await _write(peers);
    _changed.add(null);
  }

  bool _isFresh(KnownPeer peer) =>
      DateTime.now().millisecondsSinceEpoch - peer.lastSeenMs <
      freshWindow.inMilliseconds;

  /// Stores an encryption key learned out-of-band (QR contact exchange).
  ///
  /// This is what makes truly long-range first contact possible: gossip
  /// only propagates keys so far, but a scanned QR carries the key
  /// directly, so the mesh can start relaying encrypted envelopes toward
  /// someone thousands of hops away immediately. Never counts as
  /// "recently seen" and never overrides live gossip.
  Future<void> seedKey(String address, String x25519Base64) async {
    final peers = await _read();
    if (peers.containsKey(address)) return;
    peers[address] = KnownPeer(
      address: address,
      x25519Base64: x25519Base64,
      nickname: null,
      hops: 999,
      lastSeenMs: 0,
    );
    await _write(peers);
    _changed.add(null);
  }

  /// The known encryption key for [address], regardless of freshness
  /// (identity keys are long-lived).
  Future<String?> x25519For(String address) async =>
      (await _read())[address]?.x25519Base64;

  Future<KnownPeer?> get(String address) async => (await _read())[address];

  /// All peers heard from within [freshWindow], sorted nearest-first.
  Future<List<KnownPeer>> listRecent() async {
    final peers = (await _read()).values.where(_isFresh).toList()
      ..sort((a, b) {
        if (a.hops != b.hops) return a.hops.compareTo(b.hops);
        return b.lastSeenMs.compareTo(a.lastSeenMs);
      });
    return peers;
  }

  Future<Map<String, KnownPeer>> _read() async {
    final cached = _cache;
    if (cached != null) return cached;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_directoryKey));
    final result = <String, KnownPeer>{};
    if (raw != null && raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final entry in decoded.whereType<Map>()) {
          final peer = KnownPeer.fromJson(entry.cast<String, Object?>());
          result[peer.address] = peer;
        }
      }
    }
    _cache = result;
    return result;
  }

  Future<void> _write(Map<String, KnownPeer> peers) async {
    // Cap the directory so it cannot grow without bound.
    if (peers.length > 512) {
      final sorted = peers.values.toList()
        ..sort((a, b) => b.lastSeenMs.compareTo(a.lastSeenMs));
      peers
        ..clear()
        ..addEntries(sorted.take(512).map((p) => MapEntry(p.address, p)));
    }
    _cache = peers;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_directoryKey),
      jsonEncode(peers.values.map((p) => p.toJson()).toList()),
    );
  }

  /// Forgets every learned node (live sightings, gossip, and QR-seeded
  /// keys). Contacts and chats are untouched — this only wipes the mesh
  /// map and the encryption keys discovered through it.
  Future<void> clear() async {
    await _write(<String, KnownPeer>{});
    _changed.add(null);
  }

  /// Clears the in-memory cache (on identity switch).
  void resetCache() {
    _cache = null;
  }
}
