import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'identity.dart';
import 'transport.dart';

/// Store-and-forward routing over the relay's transports.
///
/// The core never decrypts anything: envelopes are ciphertext plus a
/// routing header.
class RelayCore {
  /// Safety valve, not a range limit: dedup + the via window prevent
  /// loops, and physical distance is finite.
  static const int defaultMaxHops = 1000;

  /// Gossip floods more aggressively than envelopes; keep its depth
  /// bounded (matches the app's cap).
  static const int gossipMaxHops = 128;

  /// Envelopes carry only the most recent relayers.
  static const int viaWindow = 16;

  /// Network posts (public mesh-feed broadcasts) flood like gossip but
  /// carry content — bounded tighter (matches the app's cap).
  static const int postMaxHops = 64;

  /// How many active posts a gateway carries for the neighborhood feed.
  static const int postCacheMax = 48;

  static const Duration defaultEnvelopeLifetime = Duration(hours: 48);
  static const Duration gossipInterval = Duration(seconds: 25);

  /// Carriers get an envelope re-offered this long after a failed handoff
  /// (e.g. the next hop was shut down mid-transfer).
  static const Duration offerRetryBackoff = Duration(seconds: 90);

  /// Routes stop influencing forwarding after this long unrefreshed.
  static const Duration routeLifetime = Duration(minutes: 30);

  /// Gateways forward wider than phones — pushing traffic across is
  /// their whole job.
  static const int relayFanout = 8;

  final RelayIdentity identity;
  final String name;
  final int maxSpool;
  final List<RelayTransport> transports;

  final Set<String> _seen = <String>{};
  final List<String> _seenOrder = <String>[];
  final List<Map<String, Object?>> _spool = <Map<String, Object?>>[];
  final Map<String, Set<String>> _offeredTo = <String, Set<String>>{};
  final Map<String, int> _offerFailureMs = <String, int>{};
  final Map<String, int> _gossipFreshness = <String, int>{};
  final Map<String, String> _nicknames = <String, String>{};

  /// Active Network posts carried for the neighborhood (id → packet).
  /// Tombstones replace their post and keep flooding so deletions win.
  final Map<String, Map<String, Object?>> _postCache =
      <String, Map<String, Object?>>{};

  /// Which peers already accepted each carried post.
  final Map<String, Set<String>> _postOfferedTo = <String, Set<String>>{};

  /// Learned gradients: destination → next-hop neighbor → (hops, learned
  /// ms). Gossip forwarder stamps and envelope via-trails feed it; ranked
  /// next hops get envelopes first, epidemic spread stays the fallback.
  final Map<String, Map<String, (int, int)>> _routes =
      <String, Map<String, (int, int)>>{};
  final Random _random = Random();

  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _tick;
  int _forwarded = 0;
  int _delivered = 0;

  RelayCore({
    required this.identity,
    required this.name,
    required this.maxSpool,
    required this.transports,
  });

  void log(String message) {
    final now = DateTime.now().toIso8601String().substring(11, 19);
    stdout.writeln('[$now] $message');
  }

  Future<void> start() async {
    for (final transport in transports) {
      _subs.add(transport.onPacket.listen((packet) {
        unawaited(_handlePacket(packet, transport));
      }));
      _subs.add(transport.onPeersChanged.listen((peers) {
        unawaited(_onPeersChanged(transport, peers));
      }));
    }
    _tick = Timer.periodic(gossipInterval, (_) async {
      await _broadcastOwnGossip();
      _pruneSpool();
      _prunePostCache();
      final now = DateTime.now().millisecondsSinceEpoch;
      _offerFailureMs.removeWhere(
          (_, ts) => now - ts > offerRetryBackoff.inMilliseconds * 8);
      await _offerSpoolEverywhere();
      await _offerPostsEverywhere();
    });
    await _broadcastOwnGossip();
  }

  Future<void> stop() async {
    _tick?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    for (final transport in transports) {
      await transport.stop();
    }
  }

  String shortAddr(String address) =>
      address.length <= 12 ? address : '${address.substring(0, 12)}…';

  String _shortId(String id) =>
      id.length <= 8 ? id : id.substring(0, 8);

  String _label(String address) {
    final nick = _nicknames[address];
    return nick != null && nick.isNotEmpty
        ? '"$nick" (${shortAddr(address)})'
        : shortAddr(address);
  }

  int get totalPeers =>
      transports.fold(0, (sum, t) => sum + t.onlinePeers.length);

  // ---------------------------------------------------------------------
  // Packet handling
  // ---------------------------------------------------------------------

  Future<void> _handlePacket(
    Map<String, Object?> packet,
    RelayTransport origin,
  ) async {
    switch (packet['t']) {
      case 'msg':
        await _relayEnvelope(packet, origin);
      case 'gossip':
        await _handleGossip(packet, origin);
      case 'post':
        await _relayPost(packet, origin);
      case 'ftc':
      case 'fta':
        await _passThroughTransfer(packet, origin);
    }
  }

  /// P2P file-transfer traffic (bulk chunks + progress signals) passes
  /// through *live* and is never spooled — multi-GB payloads must not pile
  /// up in gateway memory. If the target is reachable right now, pass it
  /// along; if not, drop it — the sender's flow-control window pauses the
  /// transfer and the receiver's watermark resumes it when the path is back.
  Future<void> _passThroughTransfer(
    Map<String, Object?> packet,
    RelayTransport origin,
  ) async {
    final to = packet['to'];
    if (to is! String) return;
    for (final transport in transports) {
      if (!transport.onlinePeers.contains(to)) continue;
      if (await transport.sendPacket(to, packet)) {
        _forwarded++;
        return;
      }
    }
  }

  void _markSeen(String id) {
    if (!_seen.add(id)) return;
    _seenOrder.add(id);
    while (_seenOrder.length > 8192) {
      _seen.remove(_seenOrder.removeAt(0));
    }
  }

  Future<void> _relayEnvelope(
    Map<String, Object?> packet,
    RelayTransport origin,
  ) async {
    final id = packet['id'];
    final to = packet['to'];
    if (id is! String || to is! String) return;

    // Every copy (duplicates included) teaches reverse routes: the via
    // trail is reachable through the neighbor that handed it over.
    _learnFromEnvelope(packet);

    if (to == identity.address) {
      // Addressed to the relay itself (someone messaged the gateway);
      // nothing to read here — relays hold no message keys.
      return;
    }
    if (_seen.contains(id)) return;
    _markSeen(id);

    final now = DateTime.now().millisecondsSinceEpoch;
    final exp = (packet['exp'] as num?)?.toInt();
    if (exp != null && exp < now) return;

    final hops = ((packet['hops'] as num?)?.toInt() ?? 0) + 1;
    final maxHops = (packet['max'] as num?)?.toInt() ?? defaultMaxHops;

    final envelope = Map<String, Object?>.from(packet);
    envelope['hops'] = hops;
    // Sliding window of recent relayers; dedup-by-ID prevents loops.
    final via = <String>[
      ...((packet['via'] as List?)?.whereType<String>() ?? const <String>[]),
      identity.address,
    ];
    while (via.length > viaWindow) {
      via.removeAt(0);
    }
    envelope['via'] = via;
    envelope['exp'] =
        exp ?? DateTime.now().add(defaultEnvelopeLifetime).millisecondsSinceEpoch;

    // Direct delivery to the recipient, on any transport, doesn't count
    // against the hop cap.
    for (final transport in transports) {
      if (!transport.onlinePeers.contains(to)) continue;
      if (await transport.sendPacket(to, envelope)) {
        _delivered++;
        log('Delivered envelope ${_shortId(id)} to ${_label(to)} '
            'over ${transport.name}'
            '${transport != origin ? ' (bridged from ${origin.name})' : ''}');
        return;
      }
    }

    if (hops > maxHops) return;

    _spool.add(envelope);
    while (_spool.length > maxSpool) {
      final dropped = _spool.removeAt(0);
      _offeredTo.remove(dropped['id']);
    }
    log('Carrying envelope ${_shortId(id)} for ${_label(to)} '
        '(hop $hops/$maxHops, spool ${_spool.length})');

    final from = packet['from'] as String?;
    for (final transport in transports) {
      await _offerToCarriers(
        transport,
        envelope,
        to,
        exclude: {...via, if (from != null) from},
      );
    }
  }

  // ---------------------------------------------------------------------
  // Route gradients
  // ---------------------------------------------------------------------

  void _learnRoute(String destination, String nextHop, int hops) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final viaMap =
        _routes.putIfAbsent(destination, () => <String, (int, int)>{});
    final existing = viaMap[nextHop];
    if (existing != null &&
        now - existing.$2 < routeLifetime.inMilliseconds &&
        existing.$1 < hops) {
      viaMap[nextHop] = (existing.$1, now);
    } else {
      viaMap[nextHop] = (hops, now);
    }
    while (viaMap.length > 4) {
      final worst = viaMap.entries
          .reduce((a, b) => a.value.$1 >= b.value.$1 ? a : b);
      viaMap.remove(worst.key);
    }
    if (_routes.length > 2048) {
      _routes.remove(_routes.keys.first);
    }
  }

  void _learnFromEnvelope(Map<String, Object?> packet) {
    final via =
        (packet['via'] as List?)?.whereType<String>().toList() ?? const [];
    if (via.isEmpty) return;
    final nextHop = via.last;
    final from = packet['from'] as String?;
    if (from != null) _learnRoute(from, nextHop, via.length + 1);
    for (var i = 0; i < via.length; i++) {
      _learnRoute(via[i], nextHop, via.length - i);
    }
  }

  /// Online neighbors most likely to lead toward [destination], best first.
  List<String> _rankedNextHops(String destination, Set<String> online) {
    final viaMap = _routes[destination];
    if (viaMap == null) return const <String>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    final fresh = viaMap.entries
        .where((e) =>
            online.contains(e.key) &&
            now - e.value.$2 < routeLifetime.inMilliseconds)
        .toList()
      ..sort((a, b) => a.value.$1.compareTo(b.value.$1));
    return fresh.map((e) => e.key).toList();
  }

  /// Offers [envelope] to up to [budget] of [transport]'s peers — ranked
  /// next hops first, then random carriers. Only accepted handoffs count
  /// as offered; failures (peer died mid-transfer) retry after
  /// [offerRetryBackoff] while other paths are tried immediately.
  Future<int> _offerToCarriers(
    RelayTransport transport,
    Map<String, Object?> envelope,
    String to, {
    Set<String> exclude = const {},
    int budget = relayFanout,
  }) async {
    final peers = transport.onlinePeers;
    if (peers.isEmpty) return 0;
    final id = envelope['id'] as String? ?? '';
    final offered = _offeredTo[id] ?? const <String>{};
    final now = DateTime.now().millisecondsSinceEpoch;

    bool eligible(String peer) =>
        peer != to &&
        !exclude.contains(peer) &&
        !offered.contains(peer) &&
        now - (_offerFailureMs['$id:$peer'] ?? 0) >
            offerRetryBackoff.inMilliseconds;

    final ranked = _rankedNextHops(to, peers).where(eligible).toList();
    final rest = peers
        .where((peer) => eligible(peer) && !ranked.contains(peer))
        .toList()
      ..shuffle(_random);

    var accepted = 0;
    for (final peer in [...ranked, ...rest]) {
      if (accepted >= budget) break;
      if (await transport.sendPacket(peer, envelope)) {
        _noteOffered(id, peer);
        _offerFailureMs.remove('$id:$peer');
        _forwarded++;
        accepted++;
      } else {
        _offerFailureMs['$id:$peer'] = now;
      }
    }
    return accepted;
  }

  /// Network posts: public feed broadcasts. The relay verifies nothing
  /// (apps check the signature); it floods, caches active posts, and
  /// hands them to whoever walks into range — that is what makes a Pi
  /// gateway a neighborhood bulletin board.
  Future<void> _relayPost(
    Map<String, Object?> packet,
    RelayTransport origin,
  ) async {
    final id = packet['id'];
    if (id is! String) return;
    final deleted = packet['del'] == true;
    final dedupKey = deleted ? 'postdel:$id' : 'post:$id';
    if (_seen.contains(dedupKey)) return;
    _markSeen(dedupKey);

    final now = DateTime.now().millisecondsSinceEpoch;
    final exp = (packet['exp'] as num?)?.toInt();
    if (exp == null || exp < now) return;

    final hops = ((packet['hops'] as num?)?.toInt() ?? 0) + 1;
    final maxHops = (packet['max'] as num?)?.toInt() ?? postMaxHops;
    if (hops > maxHops) return;

    final forwarded = Map<String, Object?>.from(packet);
    forwarded['hops'] = hops;

    // Cache (tombstones replace their post so deletions propagate too).
    _postCache[id] = forwarded;
    _postOfferedTo.remove(id);
    while (_postCache.length > postCacheMax) {
      final oldest = _postCache.keys.first;
      _postCache.remove(oldest);
      _postOfferedTo.remove(oldest);
    }

    final author = packet['author'] as String?;
    log('${deleted ? 'Post tombstone' : 'Network post'} ${_shortId(id)} '
        'from ${author != null ? _label(author) : 'unknown'} '
        '(hop $hops/$maxHops, over ${origin.name}, carrying '
        '${_postCache.length})');

    await _offerPostsEverywhere();
  }

  void _prunePostCache() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _postCache.removeWhere((id, packet) {
      final exp = (packet['exp'] as num?)?.toInt();
      final expired = exp != null && exp < now;
      if (expired) _postOfferedTo.remove(id);
      return expired;
    });
  }

  Future<void> _offerPostsEverywhere() async {
    for (final transport in transports) {
      await _offerPostsTo(transport, transport.onlinePeers);
    }
  }

  Future<void> _offerPostsTo(
    RelayTransport transport,
    Set<String> peers,
  ) async {
    if (_postCache.isEmpty || peers.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in _postCache.entries.toList()) {
      final packet = entry.value;
      final exp = (packet['exp'] as num?)?.toInt();
      if (exp != null && exp < now) continue;
      final author = packet['author'] as String?;
      final offered =
          _postOfferedTo.putIfAbsent(entry.key, () => <String>{});
      for (final peer in peers) {
        if (peer == author || offered.contains(peer)) continue;
        if (await transport.sendPacket(peer, packet)) {
          offered.add(peer);
          _forwarded++;
        }
      }
    }
  }

  Future<void> _handleGossip(
    Map<String, Object?> packet,
    RelayTransport origin,
  ) async {
    final addr = packet['addr'] as String?;
    final ts = (packet['ts'] as num?)?.toInt();
    if (addr == null || ts == null || addr == identity.address) return;

    // Route learning happens on every copy — even stale duplicates prove
    // which neighbor leads toward the gossiped node.
    final gossipHops = (packet['hops'] as num?)?.toInt() ?? 0;
    final forwarder = packet['v'] as String?;
    _learnRoute(addr, forwarder ?? addr, gossipHops + 1);

    final known = _gossipFreshness[addr];
    if (known != null && known >= ts) return;
    _gossipFreshness[addr] = ts;

    final nick = packet['nick'] as String?;
    if (nick != null && nick.isNotEmpty) {
      if (_nicknames[addr] != nick) {
        log('Mesh node: ${'"$nick"'} ${shortAddr(addr)} '
            '(heard over ${origin.name})');
      }
      _nicknames[addr] = nick;
    }

    final hops = gossipHops + 1;
    final maxHops = (packet['max'] as num?)?.toInt() ?? gossipMaxHops;
    if (hops > maxHops) return;

    final forwarded = Map<String, Object?>.from(packet);
    forwarded['hops'] = hops;
    // Stamped so receivers learn the gradient back through this gateway.
    forwarded['v'] = identity.address;
    for (final transport in transports) {
      for (final peer in transport.onlinePeers) {
        if (peer == addr) continue;
        unawaited(transport.sendPacket(peer, forwarded));
      }
    }
  }

  Future<void> _broadcastOwnGossip() async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await identity
        .sign('gossip|${identity.address}|${identity.x25519}|$name|$ts');
    final gossip = <String, Object?>{
      't': 'gossip',
      'addr': identity.address,
      'x25519': identity.x25519,
      'nick': name,
      'ts': ts,
      'sig': sig,
      'hops': 0,
      'max': gossipMaxHops,
    };
    for (final transport in transports) {
      for (final peer in transport.onlinePeers) {
        unawaited(transport.sendPacket(peer, gossip));
      }
    }
  }

  // ---------------------------------------------------------------------
  // Spool
  // ---------------------------------------------------------------------

  void _noteOffered(String id, String peerAddress) {
    _offeredTo.putIfAbsent(id, () => <String>{}).add(peerAddress);
  }

  void _pruneSpool() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _spool.removeWhere((envelope) {
      final exp = (envelope['exp'] as num?)?.toInt();
      final expired = exp != null && exp < now;
      if (expired) {
        _offeredTo.remove(envelope['id']);
        log('Envelope ${_shortId(envelope['id'] as String)} expired '
            'unclaimed');
      }
      return expired;
    });
  }

  Future<void> _onPeersChanged(
    RelayTransport transport,
    Set<String> peers,
  ) async {
    if (peers.isEmpty) return;
    await _offerSpoolTo(transport, peers);
    await _offerPostsTo(transport, peers);
    await _broadcastOwnGossip();
  }

  Future<void> _offerSpoolEverywhere() async {
    for (final transport in transports) {
      await _offerSpoolTo(transport, transport.onlinePeers);
    }
  }

  Future<void> _offerSpoolTo(
    RelayTransport transport,
    Set<String> peers,
  ) async {
    if (_spool.isEmpty || peers.isEmpty) return;
    final delivered = <Map<String, Object?>>[];

    for (final envelope in _spool.toList()) {
      final id = envelope['id'] as String? ?? '';
      final to = envelope['to'] as String?;
      final from = envelope['from'] as String?;
      final via =
          (envelope['via'] as List?)?.whereType<String>().toSet() ?? {};

      if (to != null && peers.contains(to)) {
        if (await transport.sendPacket(to, envelope)) {
          delivered.add(envelope);
          _delivered++;
          log('Spooled envelope ${_shortId(id)} reached '
              '${_label(to)} over ${transport.name}');
          continue;
        }
      }

      await _offerToCarriers(
        transport,
        envelope,
        to ?? '',
        exclude: {...via, if (from != null) from},
      );
    }

    for (final envelope in delivered) {
      _spool.remove(envelope);
      _offeredTo.remove(envelope['id']);
    }
  }

  String get stats =>
      'peers $totalPeers · spool ${_spool.length} · '
      'posts ${_postCache.length} · '
      'delivered $_delivered · forwarded $_forwarded';
}
