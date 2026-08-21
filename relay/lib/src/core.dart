import 'dart:async';
import 'dart:io';

import 'identity.dart';
import 'transport.dart';

/// Store-and-forward routing shared by every relay transport.
///
/// The core never decrypts anything: envelopes are ciphertext plus a
/// routing header. It bridges *between* transports — an envelope that
/// arrives over Bluetooth is offered to LAN peers and vice versa, which is
/// what lets a Raspberry Pi stitch two Bluetooth islands together over a
/// house's Wi-Fi (or a long Ethernet run).
class RelayCore {
  static const int defaultMaxHops = 10;
  static const Duration defaultEnvelopeLifetime = Duration(hours: 48);
  static const Duration gossipInterval = Duration(seconds: 25);

  final RelayIdentity identity;
  final String name;
  final int maxSpool;
  final List<RelayTransport> transports;

  final Set<String> _seen = <String>{};
  final List<String> _seenOrder = <String>[];
  final List<Map<String, Object?>> _spool = <Map<String, Object?>>[];
  final Map<String, Set<String>> _offeredTo = <String, Set<String>>{};
  final Map<String, int> _gossipFreshness = <String, int>{};
  final Map<String, String> _nicknames = <String, String>{};

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
      await _offerSpoolEverywhere();
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
      id.length <= 8 ? id : _shortId(id);

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
    envelope['via'] = <String>[
      ...((packet['via'] as List?)?.whereType<String>() ?? const <String>[]),
      identity.address,
    ];
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
    final via = (envelope['via'] as List).whereType<String>().toSet();
    for (final transport in transports) {
      for (final peer in transport.onlinePeers) {
        if (peer == from || via.contains(peer)) continue;
        _noteOffered(id, peer);
        _forwarded++;
        unawaited(transport.sendPacket(peer, envelope));
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

    final hops = ((packet['hops'] as num?)?.toInt() ?? 0) + 1;
    final maxHops = (packet['max'] as num?)?.toInt() ?? defaultMaxHops;
    if (hops > maxHops) return;

    final forwarded = Map<String, Object?>.from(packet);
    forwarded['hops'] = hops;
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
      'max': defaultMaxHops,
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

      for (final peer in peers) {
        if (to == peer) {
          if (await transport.sendPacket(peer, envelope)) {
            delivered.add(envelope);
            _delivered++;
            log('Spooled envelope ${_shortId(id)} reached '
                '${_label(peer)} over ${transport.name}');
          }
          continue;
        }
        if (peer == from || via.contains(peer)) continue;
        if (_offeredTo[id]?.contains(peer) ?? false) continue;
        _noteOffered(id, peer);
        _forwarded++;
        unawaited(transport.sendPacket(peer, envelope));
      }
    }

    for (final envelope in delivered) {
      _spool.remove(envelope);
      _offeredTo.remove(envelope['id']);
    }
  }

  String get stats =>
      'peers $totalPeers · spool ${_spool.length} · '
      'delivered $_delivered · forwarded $_forwarded';
}
