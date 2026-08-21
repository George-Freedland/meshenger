/// Learned routing gradients: for each destination somewhere in the mesh,
/// which direct neighbors have recently proven to be *on a path* to it,
/// and how far away it was through them.
///
/// Every packet teaches something:
/// - gossip re-floods are stamped with the forwarding neighbor (`v`), so a
///   record "Bob, 12 hops" arriving via neighbor N means N leads toward
///   Bob at ~13 hops;
/// - envelope `via` lists teach the reverse path — every relayer listed is
///   reachable through the neighbor that handed us the envelope (this is
///   how delivery acks find their way back without flooding).
///
/// Forwarding uses this as a *preference*, not a rule: best-known next
/// hops get an envelope first, and epidemic flooding to random carriers
/// remains the fallback, so a stale gradient can slow a message down but
/// never strand it. Entries expire — mobility churns paths constantly.
class RouteTable {
  RouteTable._();
  static final RouteTable instance = RouteTable._();

  /// Routes older than this stop influencing forwarding.
  static const Duration routeLifetime = Duration(minutes: 30);

  static const int _maxDestinations = 1024;
  static const int _maxNextHopsPerDestination = 4;

  /// destination → next-hop neighbor → route quality.
  final Map<String, Map<String, _Route>> _routes =
      <String, Map<String, _Route>>{};

  void learn(String destination, String nextHop, int hops) {
    if (destination == nextHop && hops > 1) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final viaMap = _routes.putIfAbsent(destination, () => <String, _Route>{});
    final existing = viaMap[nextHop];
    // Fresh info wins; among fresh entries keep the shortest distance.
    if (existing != null && _isFresh(existing, now) && existing.hops < hops) {
      viaMap[nextHop] = _Route(existing.hops, now);
    } else {
      viaMap[nextHop] = _Route(hops, now);
    }

    if (viaMap.length > _maxNextHopsPerDestination) {
      final worst = viaMap.entries.reduce((a, b) =>
          _score(a.value, now) >= _score(b.value, now) ? a : b);
      viaMap.remove(worst.key);
    }
    if (_routes.length > _maxDestinations) {
      // Evict the destination with the stalest best route.
      String? stalest;
      var stalestMs = now + 1;
      for (final entry in _routes.entries) {
        final newest = entry.value.values
            .map((r) => r.learnedMs)
            .reduce((a, b) => a > b ? a : b);
        if (newest < stalestMs) {
          stalestMs = newest;
          stalest = entry.key;
        }
      }
      if (stalest != null) _routes.remove(stalest);
    }
  }

  /// Neighbors (restricted to [online]) most likely to be on a path to
  /// [destination], best first. Empty when nothing is known — callers fall
  /// back to epidemic spread.
  List<String> nextHopsFor(String destination, {required Set<String> online}) {
    final viaMap = _routes[destination];
    if (viaMap == null) return const <String>[];
    final now = DateTime.now().millisecondsSinceEpoch;
    final candidates = viaMap.entries
        .where((e) => online.contains(e.key) && _isFresh(e.value, now))
        .toList()
      ..sort((a, b) => _score(a.value, now).compareTo(_score(b.value, now)));
    return candidates.map((e) => e.key).toList();
  }

  /// Lower is better: distance dominates, freshness breaks ties.
  static double _score(_Route route, int nowMs) =>
      route.hops + (nowMs - route.learnedMs) / routeLifetime.inMilliseconds;

  static bool _isFresh(_Route route, int nowMs) =>
      nowMs - route.learnedMs < routeLifetime.inMilliseconds;

  /// Clears everything (identity switch).
  void reset() => _routes.clear();
}

class _Route {
  final int hops;
  final int learnedMs;
  const _Route(this.hops, this.learnedMs);
}
