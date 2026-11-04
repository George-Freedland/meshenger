import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../media/audio_metadata.dart';
import '../media/post_file.dart';
import '../models/group_info.dart';
import '../models/incoming_message.dart';
import '../models/message.dart';
import '../models/post_attachment.dart';
import '../transport/ble_transport.dart';
import '../transport/envelope_codec.dart';
import '../transport/mesh_transport.dart';
import '../transport/message_body.dart';
import 'blob_service.dart';
import 'chat_storage.dart';
import 'contacts_service.dart';
import 'file_transfer_service.dart';
import 'identity_scope.dart';
import 'identity_service.dart';
import 'media_store.dart';
import 'alert_sound_service.dart';
import 'in_app_notice_service.dart';
import 'location_service.dart';
import 'mesh_activity.dart';
import 'network_service.dart';
import 'notification_service.dart';
import 'peer_directory.dart';
import 'route_log.dart';
import 'route_table.dart';
import 'safety_service.dart';
import 'settings_service.dart';
import 'transport_log.dart';

/// The mesh router: coordinates the Bluetooth transport, end-to-end
/// encryption, local storage, store-and-forward relaying, gossip, and
/// delivery acks.
///
/// Relay model (epidemic store-and-forward): envelopes not addressed to
/// this device are spooled and re-offered to every node that comes into
/// range, hop-limited and deduplicated, until they expire. Only the final
/// recipient can decrypt; relays (including headless Raspberry Pi
/// gateways running `bin/relay.dart`) move ciphertext blindly.
class MessengerService {
  MessengerService._();
  static final MessengerService instance = MessengerService._();

  static const _controlOutboxKey = 'control_outbox_v1';
  static const _spoolKey = 'relay_spool_v1';
  static const _postSpoolKey = 'network_post_spool_v1';

  /// Spool limits: how much we are willing to carry for other people.
  static const int _spoolMaxEntries = 64;
  static const int _spoolMaxChars = 3 * 1024 * 1024;

  /// Network posts and pages we carry and re-flood (our own + everyone
  /// else's).
  static const int _postSpoolMaxEntries = 48;
  static const int _postSpoolMaxChars = 3000000;

  /// How many online peers get a copy when the recipient is unreachable.
  /// Best-known next hops (route table) fill the first slots; random
  /// carriers fill the rest, so gradients guide but never gate delivery.
  static const int _relayFanout = 4;

  /// A carrier that failed to accept (mid-transfer shutdown, link drop) is
  /// retried after this long — other carriers are tried in the meantime.
  static const Duration _offerRetryBackoff = Duration(seconds: 90);

  /// Never handed to anyone within this window → flag as failed (mesh gap).
  static const Duration _pendingFailAfter = Duration(minutes: 3);

  /// Handed off but no end-to-end ack within this window → flag as failed.
  /// Background retries continue regardless; delivery any time later still
  /// flips the message to delivered.
  static const Duration _ackFailAfter = Duration(minutes: 30);

  /// After an app restart, give the mesh a moment before re-flagging old
  /// unconfirmed messages.
  static const Duration _failRecheckGrace = Duration(minutes: 2);

  final _uuid = const Uuid();
  final Random _random = Random();

  MeshTransport? _transport;
  bool _invisible = false;
  Timer? _sweepTimer;
  Timer? _meshTimer;

  String? transportError;

  /// Non-fatal transport degradation worth showing (e.g. Bluetooth running
  /// central-only because this adapter cannot advertise).
  String? get transportWarning =>
      isTransportRunning ? _transport?.startupWarning : null;
  String? _lastTransportWarning;

  final _changed = StreamController<String>.broadcast();
  final _peers = StreamController<Set<String>>.broadcast();
  final _transportChanged = StreamController<void>.broadcast();
  final _callSignals = StreamController<IncomingMessage>.broadcast();

  StreamSubscription<dynamic>? _packetSub;
  StreamSubscription<dynamic>? _peersSub;

  /// Recently handled packet ids (dedup for relayed envelopes).
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  static const int _seenCap = 4096;

  /// Which peers already received a given spooled envelope (memory-only).
  final Map<String, Set<String>> _spoolOfferedTo = <String, Set<String>>{};

  /// Failed handoff attempts ('envelopeId:peer' → last attempt ms): the
  /// next-hop died mid-transfer or rejected; retried after backoff while
  /// other paths are tried immediately.
  final Map<String, int> _offerFailureMs = <String, int>{};

  /// Delivery-confirmation deadlines per outgoing message (memory-only;
  /// rebuilt lazily after restart).
  final Map<String, int> _ackDeadlineMs = <String, int>{};

  /// Throttle for relay-handoff retries of pending messages.
  final Map<String, int> _lastRelayAttemptMs = <String, int>{};

  /// Which peers already accepted a given Network post (memory-only).
  final Map<String, Set<String>> _postOfferedTo = <String, Set<String>>{};

  /// Post ids known to be deleted — a tombstone beat (or replaced) the
  /// content, so late-arriving copies must not resurrect it.
  final Set<String> _deletedPostIds = <String>{};

  /// Presence tracking for the Network feed's joined/left pulse.
  Set<String> _presenceSnapshot = <String>{};
  final Map<String, int> _peerSinceMs = <String, int>{};

  Stream<String> get onChanged => _changed.stream;
  Stream<Set<String>> get onPeersChanged => _peers.stream;
  Stream<void> get onTransportChanged => _transportChanged.stream;

  /// Lets screens broadcast that they changed chat state directly (e.g.
  /// marking a chat read on open), so lists showing badges refresh live.
  void pingChanged(String chatKey) => _changed.add(chatKey);

  /// Incoming `call-*` signals, consumed by the CallService.
  Stream<IncomingMessage> get onCallSignal => _callSignals.stream;

  /// Every peer reachable directly right now — what routing uses.
  Set<String> get onlinePeers => _transport?.onlinePeers ?? const <String>{};

  /// [onlinePeers] minus invisible ones: what screens show as "in range".
  /// [onPeersChanged] emits this set too.
  Set<String> get visiblePeers => _visible(onlinePeers);

  Set<String> _visible(Set<String> peers) {
    final hidden = _transport?.hiddenPeers ?? const <String>{};
    return hidden.isEmpty ? peers : peers.difference(hidden);
  }

  /// Whether this device is in invisible mode (not advertising, not
  /// announcing itself to the mesh).
  bool get isInvisible => _invisible;

  /// Signal strength per online peer (dBm), when the transport measures it.
  Map<String, int> get peerSignal => _transport?.peerRssi ?? const {};

  /// The most precise spot among devices in direct radio range that are
  /// sharing one. Relayed devices are not used: they can be far away.
  Future<GeoPoint?> _positionHeardNearby() async {
    final inRange = visiblePeers;
    if (inRange.isEmpty) return null;
    GeoPoint? best;
    for (final address in inRange) {
      final point = (await PeerDirectory.instance.get(address))?.recentLocation;
      if (point == null) continue;
      if (best == null || point.accuracyM < best.accuracyM) best = point;
    }
    return best;
  }

  bool get isTransportRunning => _transport?.isRunning ?? false;

  Future<void> start() async {
    _invisible = await SettingsService.instance.getInvisible();
    PeerDirectory.instance.resetCache();
    RouteTable.instance.reset();
    RouteLog.instance.clear();
    LocationService.instance.reset();
    // A Mac with Wi-Fi off has no position sensor. A device it can hear
    // that is already sharing a spot places it on the globe instead.
    LocationService.instance.nearbyPosition = _positionHeardNearby;
    MeshActivityLog.instance.resetCache();
    await _seedDeletedPostIds();
    unawaited(NotificationService.instance.init());
    FileTransferService.instance.attach(
      sendControl: (act, peer, tid, meta, {bool unique = false}) =>
          _enqueueControl(
        act: act,
        chatKey: peer,
        target: tid,
        text: meta,
        unique: unique,
      ),
      sendPacket: (peer, packet, {bool bulk = false}) async =>
          await _transport?.sendPacket(peer, packet, bulk: bulk) ?? false,
      onlinePeers: () => onlinePeers,
      onCompleted: (transfer) {
        _changed.add(transfer.peer);
        unawaited(_notifyIncoming(
          chatKey: transfer.peer,
          fromAddress: transfer.peer,
          body: 'File "${transfer.name}" received — saved to Storage',
        ));
      },
    );
    BlobService.instance.attach(
      send: (peer, packet, {bool bulk = false}) async =>
          await _transport?.sendPacket(peer, packet, bulk: bulk) ?? false,
      onlinePeers: () => onlinePeers,
      myAddress: IdentityService.instance.getPublicAddressBase64,
    );
    await _startTransport();
    _sweepTimer ??=
        Timer.periodic(const Duration(seconds: 15), (_) => _sweepExpired());
    _meshTimer ??=
        Timer.periodic(const Duration(seconds: 25), (_) => _meshTick());
    await _sweepExpired();
  }

  /// Stops and restarts the active transport — the retry action after a
  /// startup failure (e.g. once the user granted Bluetooth permission).
  Future<void> restartTransport() async {
    await _stopTransport();
    await _startTransport();
  }

  /// Turns invisible mode on or off; the radio restarts in the new mode.
  Future<void> setInvisible(bool value) async {
    if (value == _invisible) return;
    _invisible = value;
    await SettingsService.instance.setInvisible(value);
    TransportLog.instance
        .log(value ? 'Mesh: invisible mode on' : 'Mesh: invisible mode off');
    await restartTransport();
  }

  /// Manual "look around again": clears discovery backoffs, scans afresh,
  /// and refreshes presence, spool, and pending deliveries with whoever
  /// answers. Restarts the radio when it isn't running.
  Future<void> rescan() async {
    final transport = _transport;
    if (transport == null || !transport.isRunning) {
      await restartTransport();
      return;
    }
    await transport.rescan();
    await _meshTick();
  }

  /// Forgets every device this identity has seen on the mesh map. Contacts
  /// and chats stay. Devices still in radio range reappear on the next scan.
  Future<void> clearMeshSightings() async {
    await PeerDirectory.instance.clear();
    RouteTable.instance.reset();
    TransportLog.instance.log('Mesh: sightings cleared — map reset to just you');
  }

  Future<void> stop() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _meshTimer?.cancel();
    _meshTimer = null;
    _seen.clear();
    _spoolOfferedTo.clear();
    _offerFailureMs.clear();
    _ackDeadlineMs.clear();
    _lastRelayAttemptMs.clear();
    _postOfferedTo.clear();
    _deletedPostIds.clear();
    await FileTransferService.instance.detach();
    await BlobService.instance.detach();
    await _stopTransport();
  }

  Future<void> _startTransport() async {
    if (isTransportRunning) return;
    transportError = null;

    final transport = createBleTransport()..invisible = _invisible;
    _transport = transport;

    try {
      await transport.start();
    } catch (e) {
      transportError = e is StateError ? e.message : e.toString();
      TransportLog.instance
          .log('Transport failed to start (bluetooth): $transportError');
      _transportChanged.add(null);
      _peers.add(const <String>{});
      return;
    }

    _packetSub = transport.onPacket.listen(_handlePacket);
    _peersSub = transport.onPeersChanged.listen((peers) {
      _peers.add(_visible(peers));
      _onPeersAppeared(peers);
    });

    _transportChanged.add(null);
    _peers.add(_visible(transport.onlinePeers));
    unawaited(_onPeersAppeared(transport.onlinePeers));
  }

  Future<void> _stopTransport() async {
    await _packetSub?.cancel();
    _packetSub = null;
    await _peersSub?.cancel();
    _peersSub = null;
    // Radio going down is not "everyone left the mesh" — reset the
    // presence baseline without logging departures.
    _presenceSnapshot = <String>{};
    _peerSinceMs.clear();
    await _transport?.stop();
    _transport = null;
    _peers.add(const <String>{});
  }

  Future<void> _sweepExpired() async {
    if (!IdentityScope.hasActive) return;
    final (changed, mediaIds) = await ChatStorage.instance.sweepExpired();
    for (final mediaId in mediaIds) {
      await MediaStore.instance.delete(mediaId);
    }
    for (final chatKey in changed) {
      _changed.add(chatKey);
    }
    await NetworkService.instance.sweepExpired();
    await _prunePostSpool();
  }

  void _armDeliveryDeadline(String messageId, MessageStatus status) {
    final window =
        status == MessageStatus.pending ? _pendingFailAfter : _ackFailAfter;
    _ackDeadlineMs[messageId] =
        DateTime.now().millisecondsSinceEpoch + window.inMilliseconds;
  }

  /// Time-monitors every unconfirmed outgoing message. When the deadline
  /// passes without an end-to-end ack, the message is flagged failed so
  /// the sender *knows* — the biggest signal that there is a gap in the
  /// mesh. Background retries keep running; a late ack still delivers.
  Future<void> _sweepDeliveryDeadlines() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final chats = await ChatStorage.instance.listChats();
    for (final chatKey in chats) {
      // Group messages surface per-member pending badges instead.
      if (ChatStorage.isGroupChat(chatKey)) continue;
      final messages = await ChatStorage.instance.listMessages(chatKey);
      var changed = false;
      for (final message in messages) {
        if (!message.isMe || message.isSystem) continue;
        if (message.status != MessageStatus.pending &&
            message.status != MessageStatus.sent) {
          continue;
        }
        // Rebuild deadlines lazily after a restart, with a grace period so
        // the mesh gets a chance before old messages are re-flagged.
        final deadline = _ackDeadlineMs[message.id] ??= max(
          message.timestamp.millisecondsSinceEpoch +
              (message.status == MessageStatus.pending
                      ? _pendingFailAfter
                      : _ackFailAfter)
                  .inMilliseconds,
          now + _failRecheckGrace.inMilliseconds,
        );
        if (now <= deadline) continue;

        await ChatStorage.instance
            .updateMessageStatus(chatKey, message.id, MessageStatus.failed);
        _ackDeadlineMs.remove(message.id);
        changed = true;
        TransportLog.instance.log(
            'Mesh: message ${message.id.length <= 8 ? message.id : message.id.substring(0, 8)} '
            'unconfirmed past deadline — flagged failed (mesh gap?). '
            'Background retries continue.');
      }
      if (changed) _changed.add(chatKey);
    }
  }

  // ---------------------------------------------------------------------
  // Mesh maintenance: gossip + spool
  // ---------------------------------------------------------------------

  Future<void> _onPeersAppeared(Set<String> peersNow) async {
    if (!IdentityScope.hasActive) return;
    final transport = _transport;
    if (transport == null) return;

    // Record directly-seen peers in the directory (invisible ones stay off
    // the map and out of the presence feed).
    final visible = _visible(peersNow);
    for (final peer in visible) {
      final x = transport.x25519For(peer);
      if (x != null) {
        await PeerDirectory.instance.recordDirect(peer, x);
      }
    }

    await _recordPresenceChanges(visible);
    await _broadcastGossip(peersNow);
    await _deliverSpoolTo(peersNow);
    await _flushPendingFor(peersNow);
    await _flushControlOutbox(peersNow);
    await _offerPostsTo(peersNow);
    await FileTransferService.instance.onPeersChanged(peersNow);
    await BlobService.instance.onPeersChanged(peersNow);
  }

  /// Diffs the direct-range peer set and logs joins/leaves for the
  /// Network feed ("suzuki joined your mesh"), with flap suppression.
  Future<void> _recordPresenceChanges(Set<String> peersNow) async {
    final prev = _presenceSnapshot;
    final joined = peersNow.difference(prev);
    final left = prev.difference(peersNow);
    if (joined.isEmpty && left.isEmpty) return;
    _presenceSnapshot = {...peersNow};

    final now = DateTime.now().millisecondsSinceEpoch;
    for (final address in joined) {
      _peerSinceMs[address] = now;
      final peer = await PeerDirectory.instance.get(address);
      unawaited(
        MeshActivityLog.instance.recordJoin(address, nickname: peer?.nickname),
      );
    }
    for (final address in left) {
      final since = _peerSinceMs.remove(address);
      if (since == null ||
          now - since < MeshActivityLog.minStayForLeave.inMilliseconds) {
        continue; // sub-minute blip: link noise, not a departure
      }
      final peer = await PeerDirectory.instance.get(address);
      unawaited(
        MeshActivityLog.instance.recordLeave(address, nickname: peer?.nickname),
      );
    }
  }

  Future<void> _meshTick() async {
    if (!IdentityScope.hasActive || !isTransportRunning) return;
    // The transport's warning can change while it runs (Bluetooth going
    // quiet, then recovering); the status banner listens for this.
    final warning = transportWarning;
    if (warning != _lastTransportWarning) {
      _lastTransportWarning = warning;
      _transportChanged.add(null);
    }
    // Deadline sweep runs even with zero peers — "no nodes in range at
    // all" is exactly the mesh-gap signal the sender must see.
    await _sweepDeliveryDeadlines();
    final now = DateTime.now().millisecondsSinceEpoch;
    _offerFailureMs.removeWhere(
        (_, ts) => now - ts > _offerRetryBackoff.inMilliseconds * 8);
    final peersNow = onlinePeers;
    if (peersNow.isEmpty) {
      await _pruneSpool();
      return;
    }
    await _broadcastGossip(peersNow);
    await _pruneSpool();
    await _deliverSpoolTo(peersNow);
    await _flushPendingFor(peersNow);
    await _flushControlOutbox(peersNow);
    await _offerPostsTo(peersNow);
  }

  Future<void> _broadcastGossip(Set<String> peersNow) async {
    final transport = _transport;
    if (transport == null || peersNow.isEmpty || _invisible) return;
    try {
      final gossip = await EnvelopeCodec.buildGossip(
        nickname: IdentityService.instance.active?.nickname,
        location: await LocationService.instance.sharedPosition(),
      );
      for (final peer in peersNow) {
        unawaited(transport.sendPacket(peer, gossip));
      }
    } catch (_) {
      // Identity locked mid-flight; ignore.
    }
  }

  // ---------------------------------------------------------------------
  // Packet router
  // ---------------------------------------------------------------------

  /// A packet, as if a device in range had just sent it.
  @visibleForTesting
  Future<void> debugHandlePacket(Map<String, Object?> packet) =>
      _handlePacket(packet);

  Future<void> _handlePacket(Map<String, Object?> packet) async {
    if (!IdentityScope.hasActive) return;
    switch (packet['t']) {
      case 'gossip':
        await _handleGossip(packet);
      case 'msg':
        await _handleEnvelope(packet);
      case 'post':
        await _handleNetworkPost(packet);
      case 'ftc':
      case 'fta':
        await _handleTransferPacket(packet);
      case 'bwho':
      case 'bhave':
      case 'bget':
      case 'bdat':
        await BlobService.instance.handlePacket(packet);
    }
  }

  /// Bulk file-transfer traffic: chunks (`ftc`) and progress (`fta`).
  /// Addressed to me → hand to the transfer engine. Addressed to someone
  /// directly reachable → pass it through live (this is how a phone or Pi
  /// in the middle bridges a transfer). Never spooled: multi-GB payloads
  /// must not pile up on middle nodes — the sender's flow-control window
  /// and the receiver's rewind signals handle loss instead.
  Future<void> _handleTransferPacket(Map<String, Object?> packet) async {
    final to = packet['to'] as String?;
    if (to == null) return;
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) return;

    if (to != me) {
      if (onlinePeers.contains(to)) {
        unawaited(
            _transport?.sendPacket(to, packet, bulk: packet['t'] == 'ftc'));
      }
      return;
    }
    if (packet['t'] == 'ftc') {
      await FileTransferService.instance.handleChunk(packet);
    } else {
      await FileTransferService.instance.handleProgress(packet);
    }
  }

  Future<void> _handleGossip(Map<String, Object?> packet) async {
    final record = await EnvelopeCodec.verifyGossip(packet);
    if (record == null) return;

    final me = await IdentityService.instance.getPublicAddressBase64();
    if (record.address == me) return;

    // Route learning: the neighbor that forwarded this record ('v', or the
    // origin itself for hops=0) leads toward record.address. Even stale
    // duplicates teach alternate paths.
    final forwarder = packet['v'] as String?;
    RouteTable.instance.learn(
      record.address,
      forwarder ?? record.address,
      record.hops + 1,
    );

    final fresher = await PeerDirectory.instance.recordGossip(
      record.address,
      record.x25519Base64,
      nickname: record.nickname,
      hops: record.hops,
      tsMs: record.tsMs,
      location: record.location,
    );
    if (!fresher) return;

    // Re-flood fresher gossip so presence spreads across the mesh, stamped
    // with our address so receivers learn the gradient back toward it.
    final maxHops =
        (packet['max'] as num?)?.toInt() ?? EnvelopeCodec.gossipMaxHops;
    final nextHops = record.hops + 1;
    if (nextHops > maxHops) return;
    final transport = _transport;
    if (transport == null) return;
    final forwarded = Map<String, Object?>.from(packet);
    forwarded['hops'] = nextHops;
    forwarded['v'] = me;
    for (final peer in onlinePeers) {
      if (peer == record.address) continue;
      unawaited(transport.sendPacket(peer, forwarded));
    }
  }

  Future<void> _handleEnvelope(Map<String, Object?> packet) async {
    final id = packet['id'];
    final to = packet['to'];
    if (id is! String || to is! String) return;

    // Every arriving copy teaches reverse routes (duplicates included —
    // they prove alternate paths), so acks and replies flow back along
    // the gradient instead of flooding.
    _learnFromEnvelope(packet);

    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) return;
    _noteRoute(packet, id, to: to, me: me);

    // Dedup: relayed envelopes can arrive several times over several paths.
    if (_seen.contains(id)) return;
    _markSeen(id);

    if (to != me) {
      await _relayEnvelope(packet, to);
      return;
    }

    final incoming = await EnvelopeCodec.decryptEnvelope(packet, myAddress: me);
    if (incoming == null) return;
    await _handleIncoming(incoming);
  }

  void _markSeen(String id) {
    _seen.add(id);
    while (_seen.length > _seenCap) {
      _seen.remove(_seen.first);
    }
  }

  /// How the first copy of each envelope addressed to me got here; it goes
  /// back to the sender inside the delivery receipt.
  final LinkedHashMap<String, (List<String>, int)> _arrivalRoutes =
      LinkedHashMap<String, (List<String>, int)>();

  /// Puts this copy's journey (sender, relays, me) on the Mesh Map.
  void _noteRoute(
    Map<String, Object?> packet,
    String id, {
    required String to,
    required String me,
  }) {
    final from = packet['from'];
    if (from is! String || from == me) return;
    final via =
        (packet['via'] as List?)?.whereType<String>().toList() ?? const [];
    final path = <String>[from, ...via, me];
    final hops = (packet['hops'] as num?)?.toInt() ?? via.length;
    RouteLog.instance.note(
      messageId: id,
      path: path,
      delivered: to == me,
      truncated: hops > via.length,
    );
    if (to == me && !_arrivalRoutes.containsKey(id)) {
      _arrivalRoutes[id] = (path, hops);
      while (_arrivalRoutes.length > 200) {
        _arrivalRoutes.remove(_arrivalRoutes.keys.first);
      }
    }
  }

  /// The envelope's via list is a breadcrumb trail: its last entry handed
  /// us the packet, so everything on the trail (and the original sender)
  /// is reachable through that neighbor.
  void _learnFromEnvelope(Map<String, Object?> packet) {
    final via =
        (packet['via'] as List?)?.whereType<String>().toList() ?? const [];
    if (via.isEmpty) return; // Came straight from the sender.
    final nextHop = via.last;
    final from = packet['from'] as String?;
    if (from != null) {
      RouteTable.instance.learn(from, nextHop, via.length + 1);
    }
    for (var i = 0; i < via.length; i++) {
      RouteTable.instance.learn(via[i], nextHop, via.length - i);
    }
  }

  // ---------------------------------------------------------------------
  // Relaying (store-and-forward for other people's envelopes)
  // ---------------------------------------------------------------------

  Future<void> _relayEnvelope(Map<String, Object?> packet, String to) async {
    if (!await SettingsService.instance.getRelayEnabled()) return;
    final transport = _transport;
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (transport == null || me == null) return;

    final exp = (packet['exp'] as num?)?.toInt();
    if (exp != null && exp < DateTime.now().millisecondsSinceEpoch) return;

    final hops = ((packet['hops'] as num?)?.toInt() ?? 0) + 1;
    final maxHops =
        (packet['max'] as num?)?.toInt() ?? EnvelopeCodec.defaultMaxHops;

    final envelope = Map<String, Object?>.from(packet);
    envelope['hops'] = hops;
    // The via list is a sliding window of recent relayers: dedup-by-ID
    // already prevents loops, so ancient path history is dead weight on
    // thousand-hop journeys.
    final via = [
      ...((packet['via'] as List?)?.whereType<String>() ?? const <String>[]),
      me,
    ];
    while (via.length > EnvelopeCodec.viaWindow) {
      via.removeAt(0);
    }
    envelope['via'] = via;

    // Direct delivery to the recipient doesn't count against the hop cap.
    if (onlinePeers.contains(to)) {
      final ok = await transport.sendPacket(to, envelope);
      if (ok) {
        TransportLog.instance
            .log('Relay: delivered envelope ${_shortId(packet)} to recipient');
        return;
      }
    }

    if (hops > maxHops) return;

    await _addToSpool(envelope);
    TransportLog.instance.log(
        'Relay: carrying envelope ${_shortId(packet)} (hop $hops/$maxHops)');

    final from = packet['from'] as String?;
    await _offerToCarriers(
      envelope,
      to,
      candidates: onlinePeers,
      exclude: {...via, if (from != null) from},
    );
  }

  String _shortId(Map<String, Object?> packet) {
    final id = packet['id'];
    if (id is! String) return '?';
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  String _spoolEntryKey(Map<String, Object?> envelope) =>
      envelope['id'] as String? ?? '';

  void _noteOffered(Map<String, Object?> envelope, String peer) {
    _spoolOfferedTo
        .putIfAbsent(_spoolEntryKey(envelope), () => <String>{})
        .add(peer);
  }

  /// Hands [envelope] to up to [budget] carriers: neighbors the route
  /// table ranks as leading toward [to] first, then random carriers
  /// (epidemic fallback). Only *accepted* handoffs are marked as offered —
  /// a carrier that dies mid-transfer is retried after
  /// [_offerRetryBackoff] while other paths are tried right away.
  Future<int> _offerToCarriers(
    Map<String, Object?> envelope,
    String to, {
    required Set<String> candidates,
    Set<String> exclude = const {},
    int budget = _relayFanout,
  }) async {
    final transport = _transport;
    if (transport == null || candidates.isEmpty) return 0;
    final id = _spoolEntryKey(envelope);
    final offered = _spoolOfferedTo[id] ?? const <String>{};
    final now = DateTime.now().millisecondsSinceEpoch;

    bool eligible(String peer) =>
        peer != to &&
        !exclude.contains(peer) &&
        !offered.contains(peer) &&
        now - (_offerFailureMs['$id:$peer'] ?? 0) >
            _offerRetryBackoff.inMilliseconds;

    final ranked = RouteTable.instance
        .nextHopsFor(to, online: candidates)
        .where(eligible)
        .toList();
    final rest = candidates
        .where((peer) => eligible(peer) && !ranked.contains(peer))
        .toList()
      ..shuffle(_random);

    var accepted = 0;
    for (final peer in [...ranked, ...rest]) {
      if (accepted >= budget) break;
      if (await transport.sendPacket(peer, envelope)) {
        _noteOffered(envelope, peer);
        _offerFailureMs.remove('$id:$peer');
        accepted++;
      } else {
        _offerFailureMs['$id:$peer'] = now;
      }
    }
    return accepted;
  }

  Future<void> _addToSpool(Map<String, Object?> envelope) async {
    final spool = await _readSpool();
    final id = _spoolEntryKey(envelope);
    if (spool.any((e) => _spoolEntryKey(e) == id)) return;
    spool.add(envelope);

    // Enforce caps, oldest first.
    while (spool.length > _spoolMaxEntries) {
      spool.removeAt(0);
    }
    var encoded = jsonEncode(spool);
    while (encoded.length > _spoolMaxChars && spool.isNotEmpty) {
      spool.removeAt(0);
      encoded = jsonEncode(spool);
    }
    await _writeSpool(spool);
  }

  Future<void> _pruneSpool() async {
    final spool = await _readSpool();
    final now = DateTime.now().millisecondsSinceEpoch;
    final kept = spool.where((e) {
      final exp = (e['exp'] as num?)?.toInt();
      return exp == null || exp > now;
    }).toList();
    if (kept.length != spool.length) {
      await _writeSpool(kept);
    }
  }

  /// Offers spooled envelopes to peers now in range: recipient directly
  /// when possible, otherwise epidemic spread to new carriers.
  Future<void> _deliverSpoolTo(Set<String> peersNow) async {
    final transport = _transport;
    if (transport == null || peersNow.isEmpty) return;
    final spool = await _readSpool();
    if (spool.isEmpty) return;

    final remaining = <Map<String, Object?>>[];
    var changed = false;

    for (final envelope in spool) {
      final to = envelope['to'] as String?;
      final from = envelope['from'] as String?;
      final via =
          (envelope['via'] as List?)?.whereType<String>().toSet() ?? {};
      var deliveredToRecipient = false;

      if (to != null && peersNow.contains(to)) {
        deliveredToRecipient = await transport.sendPacket(to, envelope);
      }

      if (deliveredToRecipient) {
        changed = true;
        _spoolOfferedTo.remove(_spoolEntryKey(envelope));
        TransportLog.instance.log(
            'Relay: spooled envelope ${_shortId(envelope)} reached recipient');
        continue;
      }

      await _offerToCarriers(
        envelope,
        to ?? '',
        candidates: peersNow,
        exclude: {...via, if (from != null) from},
      );
      remaining.add(envelope);
    }

    if (changed) {
      await _writeSpool(remaining);
    }
  }

  Future<List<Map<String, Object?>>> _readSpool() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_spoolKey));
    if (raw == null || raw.isEmpty) return <Map<String, Object?>>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <Map<String, Object?>>[];
    return decoded
        .whereType<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList();
  }

  Future<void> _writeSpool(List<Map<String, Object?>> spool) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(IdentityScope.key(_spoolKey), jsonEncode(spool));
  }

  // ---------------------------------------------------------------------
  // Delivery core
  // ---------------------------------------------------------------------

  /// Encrypts [body] for [recipient] and hands it to the mesh.
  ///
  /// Tries direct delivery first; when the recipient is out of range the
  /// envelope goes to up to [_relayFanout] nearby nodes (and the local
  /// spool) for store-and-forward. Returns true when at least one node
  /// accepted the envelope.
  Future<bool> _deliverBody(String recipient, MessageBody body) async {
    final transport = _transport;
    if (transport == null) return false;
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) return false;

    final x25519 = transport.x25519For(recipient) ??
        await PeerDirectory.instance.x25519For(recipient);
    if (x25519 == null) return false; // Never met them — no key yet.

    final Map<String, Object?> envelope;
    try {
      envelope = await EnvelopeCodec.encryptEnvelope(
        from: me,
        to: recipient,
        toX25519Base64: x25519,
        body: body,
      );
    } catch (_) {
      return false;
    }
    // Never re-process our own envelope if it echoes back through the mesh.
    _markSeen(envelope['id'] as String);

    if (onlinePeers.contains(recipient)) {
      if (await transport.sendPacket(recipient, envelope)) {
        return true;
      }
    }

    // Recipient unreachable: hand to carriers, best-known routes first.
    final accepted = await _offerToCarriers(
      envelope,
      recipient,
      candidates: onlinePeers,
    );
    if (accepted > 0) {
      // Also keep a local copy: if we meet the recipient before a relay
      // does, we deliver it ourselves. Recipient deduplicates.
      await _addToSpool(envelope);
    }
    return accepted > 0;
  }

  // ---------------------------------------------------------------------
  // Incoming
  // ---------------------------------------------------------------------

  /// A decrypted message, as if it had just arrived over the mesh.
  @visibleForTesting
  Future<void> debugHandleIncoming(IncomingMessage incoming) =>
      _handleIncoming(incoming);

  Future<void> _handleIncoming(IncomingMessage incoming) async {
    final action = incoming.action;

    // End-to-end delivery receipts and call signaling bypass the
    // contacts-only filter only for acks (they answer traffic we sent).
    if (action == 'ack') {
      await _handleAck(incoming);
      return;
    }

    if (await SafetyService.instance.isBlocked(incoming.fromAddress)) return;

    final allowAnyone =
        await SettingsService.instance.getAllowMessagesFromAnyone();
    if (!allowAnyone) {
      final contact =
          await ContactsService.instance.getContact(incoming.fromAddress);
      if (contact == null) return;
    }

    if (action != null && action.startsWith('call-')) {
      if (action == 'call-invite') {
        unawaited(_notifyIncoming(
          chatKey: incoming.fromAddress,
          fromAddress: incoming.fromAddress,
          body: 'Incoming call',
        ));
      }
      _callSignals.add(incoming);
      return;
    }

    switch (action) {
      case 'edit':
        await _handleRemoteEdit(incoming);
        return;
      case 'delete':
        await _handleRemoteDelete(incoming);
        return;
      case 'wipechat':
        await _handleRemoteWipeChat(incoming);
        return;
      case 'story':
        await _handleRemoteStory(incoming);
        return;
      case 'ftoffer':
        await _handleTransferOffer(incoming);
        return;
      case 'ftaccept':
        await FileTransferService.instance.handleAccept(
          incoming.fromAddress,
          incoming.targetId ?? '',
          _ftHave(incoming.text),
        );
        return;
      case 'ftdecline':
        await FileTransferService.instance
            .handleDecline(incoming.fromAddress, incoming.targetId ?? '');
        return;
      case 'ftcancel':
        await FileTransferService.instance
            .handleCancel(incoming.fromAddress, incoming.targetId ?? '');
        return;
      case 'ftdone':
        await FileTransferService.instance
            .handleDone(incoming.fromAddress, incoming.targetId ?? '');
        return;
    }

    if (incoming.isGroupEvent) {
      await _handleGroupEvent(incoming);
      return;
    }

    final String chatKey;
    if (incoming.groupId != null) {
      chatKey = ChatStorage.groupChatKey(incoming.groupId!);
      final me = await IdentityService.instance.getPublicAddressBase64();
      final existing =
          await ChatStorage.instance.getGroupInfo(incoming.groupId!);
      if (me != null &&
          incoming.groupMembers != null &&
          !incoming.groupMembers!.contains(me)) {
        return;
      }
      await ChatStorage.instance.saveGroupInfo(GroupInfo(
        id: incoming.groupId!,
        adminAddress: incoming.groupAdmin ??
            existing?.adminAddress ??
        incoming.fromAddress,
        name: incoming.groupName ?? existing?.name,
        members: incoming.groupMembers ?? existing?.members ?? <String>[],
      ));
    } else {
      chatKey = incoming.fromAddress;
    }

    final expiresAtMs = await _incomingExpiry(incoming);

    // Persist any media attachment to the local store.
    String? mediaId;
    if (incoming.kind != null && incoming.mediaB64 != null) {
      try {
        final bytes = base64Decode(incoming.mediaB64!);
        if (bytes.length <= MediaStore.maxTransferBytes) {
          final item = await MediaStore.instance.saveBytes(
            Uint8List.fromList(bytes),
            name: incoming.mediaName ?? 'attachment',
            mime: incoming.mediaMime ?? 'application/octet-stream',
            source: MediaSource.received,
            temp: incoming.mediaTemp,
            durationMs: incoming.durationMs,
          );
          mediaId = item.id;
        }
      } catch (_) {
        // Corrupt media: keep the text part of the message.
      }
    }

    await ChatStorage.instance.ensureChatExists(chatKey);
    await ChatStorage.instance.appendMessage(
      chatKey,
        ChatMessage(
          id: incoming.id,
          text: incoming.text,
          isMe: false,
          timestamp: incoming.timestamp,
          status: MessageStatus.sent,
        senderAddress: incoming.fromAddress,
        expiresAtMs: expiresAtMs,
        kind: mediaId != null ? incoming.kind : null,
        mediaId: mediaId,
        mediaName: incoming.mediaName,
        mediaMime: incoming.mediaMime,
        mediaTemp: incoming.mediaTemp,
        durationMs: incoming.durationMs,
        voicemail: incoming.voicemail,
      ),
    );
    await ChatStorage.instance.markUnread(chatKey);
    _changed.add(chatKey);

    unawaited(_notifyIncoming(
      chatKey: chatKey,
      fromAddress: incoming.fromAddress,
      body: switch (incoming.kind) {
        'image' => 'Sent you a photo',
        'audio' =>
          incoming.voicemail ? 'Left you a voicemail' : 'Sent a voice message',
        'file' => 'Sent you a file',
        _ => 'Sent you an encrypted message',
      },
    ));

    // Send the end-to-end delivery receipt (works across relays too). Its
    // text tells the sender which way the message came, for their Mesh
    // Map; older builds ignore an ack's text.
    final arrival = _arrivalRoutes.remove(incoming.id);
    unawaited(_deliverBody(
      incoming.fromAddress,
      MessageBody(
        messageId: _uuid.v4(),
        text: arrival == null
            ? ''
            : jsonEncode(<String, Object?>{
                'route': arrival.$1,
                'hops': arrival.$2,
              }),
        timestamp: DateTime.now(),
        action: 'ack',
        targetId: incoming.id,
        groupId: incoming.groupId,
      ),
    ));
  }

  /// Sound + in-app banner when you are looking at another screen; OS
  /// banner when the app is backgrounded. Never includes message content.
  Future<void> _notifyIncoming({
    required String chatKey,
    required String fromAddress,
    required String body,
  }) async {
    try {
      final contact = await ContactsService.instance.getContact(fromAddress);
      final nickname = contact?.nickname?.trim();
      final title = (nickname != null && nickname.isNotEmpty)
          ? nickname
          : (fromAddress.length <= 12
              ? fromAddress
              : '${fromAddress.substring(0, 12)}…');
      final viewing = InAppNoticeService.instance.isViewingChat(chatKey);
      if (!viewing) {
        unawaited(AlertSoundService.instance.play());
        InAppNoticeService.instance.show(InAppNotice(
          chatKey: chatKey,
          title: title,
          body: body,
        ));
      }
      await NotificationService.instance.notify(title: title, body: body);
    } catch (_) {
      // Alerts are best-effort.
    }
  }

  Future<void> _handleAck(IncomingMessage incoming) async {
    final target = incoming.targetId;
    if (target == null) return;
    _ackDeadlineMs.remove(target);
    _noteDeliveredRoute(target, incoming.text);
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) return;

    final String chatKey;
    List<String> allRecipients;
    if (incoming.groupId != null) {
      chatKey = ChatStorage.groupChatKey(incoming.groupId!);
      final info = await ChatStorage.instance.getGroupInfo(incoming.groupId!);
      allRecipients =
          (info?.members ?? const <String>[]).where((a) => a != me).toList();
    } else {
      chatKey = incoming.fromAddress;
      allRecipients = [incoming.fromAddress];
    }

    final changed = await ChatStorage.instance.applyDeliveryAck(
      chatKey,
      target,
      incoming.fromAddress,
      allRecipients: allRecipients,
    );
    if (changed) _changed.add(chatKey);
  }

  /// The route a message of mine took to its recipient, from their receipt.
  void _noteDeliveredRoute(String messageId, String text) {
    if (!text.startsWith('{')) return;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final route = (decoded['route'] as List?)?.whereType<String>().toList();
      if (route == null || route.length < 2) return;
      final hops = (decoded['hops'] as num?)?.toInt() ?? route.length - 2;
      RouteLog.instance.note(
        messageId: messageId,
        path: route,
        delivered: true,
        truncated: hops > route.length - 2,
      );
    } on FormatException {
      // Not a route.
    }
  }

  /// The earliest applicable auto-delete deadline: the sender's TTL and my
  /// own auto-delete setting both apply.
  Future<int?> _incomingExpiry(IncomingMessage incoming) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final candidates = <int>[];
    final senderTtl = incoming.ttlSeconds;
    if (senderTtl != null && senderTtl > 0) {
      candidates.add(now + senderTtl * 1000);
    }
    final mine = await SettingsService.instance.getAutoDeleteSeconds();
    if (mine > 0) {
      candidates.add(now + mine * 1000);
    }
    if (candidates.isEmpty) return null;
    candidates.sort();
    return candidates.first;
  }

  String _chatKeyForIncoming(IncomingMessage incoming) =>
      incoming.groupId != null
          ? ChatStorage.groupChatKey(incoming.groupId!)
          : incoming.fromAddress;

  Future<void> _handleRemoteEdit(IncomingMessage incoming) async {
    final target = incoming.targetId;
    if (target == null) return;
    final chatKey = _chatKeyForIncoming(incoming);
    final applied = await ChatStorage.instance.editMessage(
      chatKey,
      target,
      incoming.text,
      requireSender: incoming.fromAddress,
    );
    if (applied) _changed.add(chatKey);
  }

  Future<void> _handleRemoteDelete(IncomingMessage incoming) async {
    final target = incoming.targetId;
    if (target == null) return;
    final chatKey = _chatKeyForIncoming(incoming);
    final existing = await ChatStorage.instance.getMessage(chatKey, target);
    final applied = await ChatStorage.instance.deleteMessage(
      chatKey,
      target,
      requireSender: incoming.fromAddress,
    );
    if (applied) {
      final mediaId = existing?.mediaId;
      if (mediaId != null) await MediaStore.instance.delete(mediaId);
      _changed.add(chatKey);
    }
  }

  static int _ftHave(String metaJson) {
    try {
      final decoded = jsonDecode(metaJson);
      if (decoded is Map) return (decoded['have'] as num?)?.toInt() ?? 0;
    } catch (_) {}
    return 0;
  }

  /// A peer wants to send us a large file: register the transfer and drop
  /// an accept/decline bubble into the chat.
  Future<void> _handleTransferOffer(IncomingMessage incoming) async {
    final transfer = await FileTransferService.instance
        .handleOffer(incoming.fromAddress, incoming.text);
    if (transfer == null) return; // malformed or duplicate

    final chatKey = incoming.fromAddress;
    await ChatStorage.instance.ensureChatExists(chatKey);
    await ChatStorage.instance.appendMessage(
      chatKey,
      ChatMessage(
        id: 'ft:${transfer.tid}',
        text: '',
        isMe: false,
        timestamp: incoming.timestamp,
        status: MessageStatus.sent,
        senderAddress: chatKey,
        kind: 'transfer',
        mediaId: transfer.tid,
        mediaName: transfer.name,
        mediaMime: transfer.mime,
      ),
    );
    await ChatStorage.instance.markUnread(chatKey);
    _changed.add(chatKey);
    final auto = transfer.size <= autoAcceptFileBytes &&
        await ContactsService.instance.getContact(chatKey) != null;
    if (auto) unawaited(FileTransferService.instance.accept(transfer.tid));
    unawaited(_notifyIncoming(
      chatKey: chatKey,
      fromAddress: chatKey,
      body: auto
          ? 'Sending you "${transfer.name}"'
          : 'Wants to send you "${transfer.name}"',
    ));
  }

  /// Files from contacts up to this size download without asking; bigger
  /// ones, and anything from strangers, wait for Accept.
  static const int autoAcceptFileBytes = 100 * 1024 * 1024;

  /// Chat files up to this size travel like a message, so relays can carry
  /// them to someone out of range; bigger ones stream device to device,
  /// much faster and with a live progress bar.
  static const int inlineChatFileBytes = 64 * 1024;

  /// Offers a large file to a 1:1 peer over the P2P transfer engine and
  /// drops the live progress bubble into the chat.
  Future<void> sendFileTransfer(
    String chatKey, {
    required String path,
    required String name,
    required String mime,
  }) async {
    if (ChatStorage.isGroupChat(chatKey)) {
      throw StateError('File transfer is 1:1 (pick a member directly)');
    }
    final transfer = await FileTransferService.instance.offer(
      peer: chatKey,
      path: path,
      name: name,
      mime: mime,
      durationMs: await _playingTimeOf(path, mime),
    );
    await ChatStorage.instance.ensureChatExists(chatKey);
    await ChatStorage.instance.appendMessage(
      chatKey,
      ChatMessage(
        id: 'ft:${transfer.tid}',
        text: '',
        isMe: true,
        timestamp: DateTime.now(),
        status: MessageStatus.sent,
        kind: 'transfer',
        mediaId: transfer.tid,
        mediaName: name,
        mediaMime: mime,
      ),
    );
    _changed.add(chatKey);
  }

  /// A song's or MP4-family video's length, so the other side can start
  /// playing before the transfer finishes.
  static Future<int?> _playingTimeOf(String path, String mime) async {
    final media = mime.startsWith('audio/') ||
        const {'video/mp4', 'video/quicktime', 'video/x-m4v'}.contains(mime);
    if (!media) return null;
    try {
      return (await readAudioMetadata(path)).duration?.inMilliseconds;
    } catch (_) {
      return null;
    }
  }

  /// The peer deleted our whole conversation for everyone. Scope is
  /// inherent: a sender can only ever wipe the 1:1 thread with themself.
  Future<void> _handleRemoteWipeChat(IncomingMessage incoming) async {
    final chatKey = incoming.fromAddress;
    await deleteChatLocally(chatKey);
    TransportLog.instance
        .log('Chat with ${_shortAddr(chatKey)} deleted by the other side');
  }

  /// Removes a 1:1 chat and everything attached to it on this device.
  Future<void> deleteChatLocally(String chatKey) async {
    for (final mediaId in await ChatStorage.instance.mediaIdsIn(chatKey)) {
      await MediaStore.instance.delete(mediaId);
    }
    await ChatStorage.instance.deleteChat(chatKey);
    _changed.add(chatKey);
  }

  /// Telegram-style full-conversation delete: wipes the chat here and
  /// sends a signed, store-and-forward `wipechat` so the peer's copy is
  /// deleted too (arrives whenever they are next reachable).
  Future<void> deleteChatForEveryone(String chatKey) async {
    if (ChatStorage.isGroupChat(chatKey)) {
      throw StateError('Group chats are hidden or left, not wiped');
    }
    await _enqueueControl(
      act: 'wipechat',
      chatKey: chatKey,
      target: chatKey,
    );
    await deleteChatLocally(chatKey);
  }

  /// Legacy directed stories (act: 'story') from older builds land on the
  /// Network feed too, so old and new versions keep interoperating.
  Future<void> _handleRemoteStory(IncomingMessage incoming) async {
    final ttl = incoming.ttlSeconds ?? 86400;
    final storyId = incoming.targetId ?? incoming.id;
    if (_deletedPostIds.contains(storyId)) return;

    String? mediaId;
    if (incoming.kind == 'image' && incoming.mediaB64 != null) {
      try {
        final bytes = base64Decode(incoming.mediaB64!);
        if (bytes.length <= MediaStore.maxTransferBytes) {
          final item = await MediaStore.instance.saveBytes(
            Uint8List.fromList(bytes),
            name: incoming.mediaName ?? 'story.jpg',
            mime: incoming.mediaMime ?? 'image/jpeg',
            source: MediaSource.received,
            temp: true, // feed media never shows in the Storage library
          );
          mediaId = item.id;
        }
      } catch (_) {}
    }

    await NetworkService.instance.upsert(NetworkPost(
      // The story's stable id travels in targetId; the envelope id varies
      // per delivery attempt.
      id: storyId,
      author: incoming.fromAddress,
      text: incoming.text,
      tsMs: incoming.timestamp.millisecondsSinceEpoch,
      expiresMs: incoming.timestamp.millisecondsSinceEpoch + ttl * 1000,
      mediaId: mediaId,
      mediaMime: incoming.mediaMime,
    ));
  }

  Future<void> _handleGroupEvent(IncomingMessage incoming) async {
    final groupId = incoming.groupId;
    final members = incoming.groupMembers;
    if (groupId == null || members == null) return;

    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) return;

    final event = GroupEvent(
      groupId: groupId,
      actorAddress: incoming.fromAddress,
      adminAddress: incoming.groupAdmin ?? incoming.fromAddress,
      members: members,
      name: incoming.groupName,
      action: incoming.groupEvent!,
    );

    final stillMember =
        await ChatStorage.instance.applyGroupEvent(event, me);
    if (!stillMember) {
      _changed.add(ChatStorage.groupChatKey(groupId));
      return;
    }

    final chatKey = ChatStorage.groupChatKey(groupId);
    final notice = _systemNoticeForEvent(event, me);
    if (notice != null &&
        await ChatStorage.instance.getMessage(chatKey, incoming.id) == null) {
      await ChatStorage.instance.appendMessage(
        chatKey,
        ChatMessage(
          id: incoming.id,
          text: notice,
          isMe: incoming.fromAddress == me,
          timestamp: incoming.timestamp,
          status: MessageStatus.sent,
          isSystem: true,
        ),
      );
      await ChatStorage.instance.markUnread(chatKey);
    }
    _changed.add(chatKey);
  }

  String? _systemNoticeForEvent(GroupEvent event, String me) {
    switch (event.action) {
      case 'rename':
        final name = event.name?.trim();
        if (name == null || name.isEmpty) return null;
        return event.actorAddress == me
            ? 'You renamed the group to "$name"'
            : 'Group renamed to "$name"';
      case 'members':
        return event.actorAddress == me
            ? 'You updated the group members'
            : 'Group members were updated';
      case 'leave':
        return event.actorAddress == me
            ? 'You left the group'
            : 'A member left the group';
      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------
  // Outgoing: 1:1 and group chat messages (text and media)
  // ---------------------------------------------------------------------

  Future<ChatMessage> sendText(String peerAddress, String text) =>
      _sendChatMessage(peerAddress, text: text);

  Future<void> sendGroupText(String chatKey, String text) =>
      _sendGroupMessage(chatKey, text: text);

  /// Sends an image/audio/file attachment. [temp] makes images view-once
  /// (Snapchat-style). Works for both 1:1 and group chats.
  Future<void> sendMedia(
    String chatKey, {
    required Uint8List bytes,
    required String name,
    required String mime,
    required String kind,
    String text = '',
    bool temp = false,
    int? durationMs,
    bool voicemail = false,
  }) async {
    if (bytes.length > MediaStore.maxTransferBytes) {
      throw StateError(
        'File is too large for mesh transfer '
        '(max ${MediaStore.maxTransferBytes ~/ (1024 * 1024)} MB)',
      );
    }
    final item = await MediaStore.instance.saveBytes(
      bytes,
      name: name,
      mime: mime,
      source: MediaSource.sent,
      temp: temp,
      durationMs: durationMs,
    );
    final media = _MediaPayload(
      item: item,
      b64: base64Encode(bytes),
      kind: kind,
      temp: temp,
      durationMs: durationMs,
      voicemail: voicemail,
    );
    if (ChatStorage.isGroupChat(chatKey)) {
      await _sendGroupMessage(chatKey, text: text, media: media);
    } else {
      await _sendChatMessage(chatKey, text: text, media: media);
    }
  }

  Future<ChatMessage> _sendChatMessage(
    String peerAddress, {
    required String text,
    _MediaPayload? media,
  }) async {
    final ttl = await SettingsService.instance.getAutoDeleteSeconds();
    final now = DateTime.now();
    final message = ChatMessage(
      id: _uuid.v4(),
      text: text,
      isMe: true,
      timestamp: now,
      status: MessageStatus.pending,
      expiresAtMs: ttl > 0 ? now.millisecondsSinceEpoch + ttl * 1000 : null,
      kind: media?.kind,
      mediaId: media?.item.id,
      mediaName: media?.item.name,
      mediaMime: media?.item.mime,
      mediaTemp: media?.temp ?? false,
      durationMs: media?.durationMs,
      voicemail: media?.voicemail ?? false,
    );

    await ChatStorage.instance.ensureChatExists(peerAddress);
    await ChatStorage.instance.appendMessage(peerAddress, message);
    _changed.add(peerAddress);
    _armDeliveryDeadline(message.id, MessageStatus.pending);

    final handedOff = await _deliverBody(
      peerAddress,
      _bodyFor(message, media, ttl),
    );

    if (handedOff) {
      await ChatStorage.instance
          .updateMessageStatus(peerAddress, message.id, MessageStatus.sent);
      _changed.add(peerAddress);
      _armDeliveryDeadline(message.id, MessageStatus.sent);
      return message.copyWith(status: MessageStatus.sent);
    }
    return message;
  }

  Future<void> _sendGroupMessage(
    String chatKey, {
    required String text,
    _MediaPayload? media,
  }) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (info == null) return;

    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null || !info.contains(me)) return;

    final ttl = await SettingsService.instance.getAutoDeleteSeconds();
    final now = DateTime.now();
    final recipients = info.members.where((a) => a != me).toList();
    final message = ChatMessage(
      id: _uuid.v4(),
      text: text,
      isMe: true,
      timestamp: now,
      status: MessageStatus.pending,
      pendingTo: recipients,
      expiresAtMs: ttl > 0 ? now.millisecondsSinceEpoch + ttl * 1000 : null,
      kind: media?.kind,
      mediaId: media?.item.id,
      mediaName: media?.item.name,
      mediaMime: media?.item.mime,
      mediaTemp: media?.temp ?? false,
      durationMs: media?.durationMs,
      voicemail: media?.voicemail ?? false,
    );

    await ChatStorage.instance.ensureChatExists(chatKey);
    await ChatStorage.instance.appendMessage(chatKey, message);
    _changed.add(chatKey);

    for (final recipient in recipients) {
      final handedOff = await _deliverBody(
        recipient,
        _bodyFor(message, media, ttl, info: info),
      );
      if (handedOff) {
        await ChatStorage.instance
            .markGroupMessageHandedOff(chatKey, message.id, recipient);
        _changed.add(chatKey);
      }
    }
  }

  MessageBody _bodyFor(
    ChatMessage message,
    _MediaPayload? media,
    int ttl, {
    GroupInfo? info,
  }) =>
      MessageBody(
        messageId: message.id,
        text: message.text,
        timestamp: message.timestamp,
        groupId: info?.id,
        groupMembers: info?.members,
        groupAdmin: info?.adminAddress,
        groupName: info?.name,
        ttlSeconds: ttl > 0 ? ttl : null,
        kind: media?.kind,
        mediaB64: media?.b64,
        mediaName: media?.item.name,
        mediaMime: media?.item.mime,
        mediaTemp: media?.temp ?? false,
        durationMs: media?.durationMs,
        voicemail: media?.voicemail ?? false,
      );

  /// Marks a received view-once image as viewed: deletes the media file
  /// and strips it from the message.
  Future<void> markViewOnceOpened(String chatKey, ChatMessage message) async {
    final mediaId = message.mediaId;
    if (mediaId != null) {
      await MediaStore.instance.delete(mediaId);
    }
    await ChatStorage.instance.markMediaViewed(chatKey, message.id);
    _changed.add(chatKey);
  }

  // ---------------------------------------------------------------------
  // Calls (signaling, and the call's voice as push-to-talk clips)
  // ---------------------------------------------------------------------

  /// A clip that hasn't arrived by then is no use to anyone.
  static const int _callAudioLifetimeSeconds = 60;

  Future<bool> sendCallSignal(
    String peerAddress, {
    required String action, // call-invite | call-accept | ...
    required String callId,
    bool video = false,
  }) {
    return _deliverBody(
      peerAddress,
      MessageBody(
        messageId: _uuid.v4(),
        text: video ? 'video' : 'voice',
        timestamp: DateTime.now(),
        action: action,
        targetId: callId,
      ),
    );
  }

  /// One push-to-talk clip of a running call. It travels like the call's
  /// signals, so neither side stores it: the other side plays it and
  /// throws it away, and relays drop it after a minute.
  Future<bool> sendCallAudio(
    String peerAddress, {
    required String callId,
    required Uint8List bytes,
  }) {
    return _deliverBody(
      peerAddress,
      MessageBody(
        messageId: _uuid.v4(),
        text: 'voice',
        timestamp: DateTime.now(),
        action: 'call-audio',
        targetId: callId,
        ttlSeconds: _callAudioLifetimeSeconds,
        kind: 'audio',
        mediaB64: base64Encode(bytes),
        mediaName: 'call.m4a',
        mediaMime: 'audio/mp4',
      ),
    );
  }

  /// Adds a call's line to the chat with [peer]. [text] has a `{time}`
  /// placeholder that the chat fills in with [at].
  Future<void> noteCall(
    String peer, {
    required String id,
    required String text,
    required DateTime at,
    required bool video,
    bool unread = false,
  }) async {
    if (ChatStorage.isGroupChat(peer)) return;
    await ChatStorage.instance.ensureChatExists(peer);
    await ChatStorage.instance.appendMessage(
      peer,
      ChatMessage(
        id: id,
        text: text,
        isMe: false,
        timestamp: at,
        status: MessageStatus.sent,
        isSystem: true,
        kind: video
            ? ChatStorage.videoCallLineKind
            : ChatStorage.callLineKind,
      ),
    );
    if (unread) await ChatStorage.instance.markUnread(peer);
    _changed.add(peer);
  }

  /// Removes call lines from one chat ([peer]) or from every 1:1 chat;
  /// see [ChatStorage.removeCallLines] for [video] and [callId].
  Future<void> removeCallLines({
    String? peer,
    bool? video,
    String? callId,
  }) async {
    final chats = peer != null
        ? [peer]
        : (await ChatStorage.instance.listChats())
            .where((c) => !ChatStorage.isGroupChat(c));
    for (final chatKey in chats) {
      if (await ChatStorage.instance
          .removeCallLines(chatKey, video: video, callId: callId)) {
        _changed.add(chatKey);
      }
    }
  }

  // ---------------------------------------------------------------------
  // Edit / delete own messages (synced to peers)
  // ---------------------------------------------------------------------

  Future<void> sendEditMessage(
    String chatKey,
    String messageId,
    String newText,
  ) async {
    final applied =
        await ChatStorage.instance.editMessage(chatKey, messageId, newText);
    if (!applied) return;
    _changed.add(chatKey);
    await _enqueueControl(
      act: 'edit',
      chatKey: chatKey,
      target: messageId,
      text: newText,
    );
  }

  Future<void> sendDeleteMessage(String chatKey, String messageId) async {
    final existing = await ChatStorage.instance.getMessage(chatKey, messageId);
    final applied =
        await ChatStorage.instance.deleteMessage(chatKey, messageId);
    if (!applied) return;
    final mediaId = existing?.mediaId;
    if (mediaId != null) await MediaStore.instance.delete(mediaId);
    _changed.add(chatKey);
    await _enqueueControl(
      act: 'delete',
      chatKey: chatKey,
      target: messageId,
    );
  }

  // ---------------------------------------------------------------------
  // Network (mesh-local public feed)
  //
  // Posts are signed broadcasts that flood the surrounding mesh, hop by
  // hop, with no addressing: everyone in radio reach — direct or through
  // relays — sees them until they expire. Every node (and every Pi
  // gateway) carries active posts and hands them to whoever walks into
  // range, which is what makes the feed follow you between meshes.
  // ---------------------------------------------------------------------

  Future<void> _handleNetworkPost(Map<String, Object?> packet) async {
    final id = packet['id'];
    if (id is! String) return;
    final deleted = packet['del'] == true;
    final dedupKey = deleted ? 'postdel:$id' : 'post:$id';
    if (_seen.contains(dedupKey)) return;

    final verified = await EnvelopeCodec.verifyNetworkPost(packet);
    if (verified == null) return;
    _markSeen(dedupKey);

    final now = DateTime.now().millisecondsSinceEpoch;
    if (verified.expMs <= now) return;

    final me = await IdentityService.instance.getPublicAddressBase64();
    final hops = verified.hops + 1;
    final maxHops = (packet['max'] as num?)?.toInt() ?? EnvelopeCodec.postMaxHops;

    if (deleted) {
      _deletedPostIds.add(id);
      if (verified.author != me) {
        await NetworkService.instance.remove(id);
      }
      TransportLog.instance.log(
          'Network: post ${id.length <= 8 ? id : id.substring(0, 8)} deleted '
          'by its author');
      if (hops <= maxHops) {
        final forwarded = Map<String, Object?>.from(packet);
        forwarded['hops'] = hops;
        _postOfferedTo.remove(id); // tombstone supersedes the content copy
        await _addToPostSpool(forwarded);
        await _offerPostsTo(onlinePeers);
      }
      return;
    }

    if (verified.author == me) return; // own post echoed back
    if (_deletedPostIds.contains(id)) return; // tombstone won the race
    if (verified.kind == 'page' &&
        utf8.encode(verified.text).length > EnvelopeCodec.maxPageBytes) {
      return;
    }

    // The same post can arrive again after a restart: keep the media saved
    // the first time instead of storing another copy.
    final known = await NetworkService.instance.byId(id);
    var mediaId = known?.mediaId;
    var artMediaId = known?.artMediaId;
    if (mediaId == null &&
        verified.kind == 'image' &&
        verified.mediaB64 != null) {
      try {
        final bytes = base64Decode(verified.mediaB64!);
        if (bytes.length <= EnvelopeCodec.maxPostMediaBytes) {
          final item = await MediaStore.instance.saveBytes(
            Uint8List.fromList(bytes),
            name: 'post.jpg',
            mime: verified.mediaMime ?? 'image/jpeg',
            source: MediaSource.received,
            temp: true, // feed media never shows in the Storage library
          );
          mediaId = item.id;
        }
      } catch (_) {}
    }
    final attachment = verified.attachment;
    if (attachment != null) {
      final art = verified.artB64;
      if (artMediaId == null && art != null) {
        try {
          final bytes = Uint8List.fromList(base64Decode(art));
          if (bytes.length <= EnvelopeCodec.maxPostArtBytes) {
            artMediaId = (await MediaStore.instance.saveBytes(
              bytes,
              name: 'cover',
              mime: _coverMime(bytes),
              source: MediaSource.received,
              temp: true,
            ))
                .id;
          }
        } catch (_) {}
      }
      // Small files ride inside the post; kept only if they match the hash.
      final inline = verified.mediaB64;
      if (inline != null &&
          attachment.size <= EnvelopeCodec.maxInlineFileBytes) {
        try {
          await BlobService.instance.addBytes(
            Uint8List.fromList(base64Decode(inline)),
            sha: attachment.sha256,
            name: attachment.name,
          );
        } catch (_) {}
      }
    }

    await NetworkService.instance.upsert(NetworkPost(
      id: id,
      author: verified.author,
      authorNick: verified.nickname,
      text: verified.text,
      tsMs: verified.tsMs,
      expiresMs: verified.expMs,
      hops: verified.hops,
      mediaId: mediaId,
      mediaMime: verified.mediaMime,
      scope: verified.scope,
      kind: verified.kind,
      path: verified.path,
      title: verified.title,
      attachment: attachment,
      artMediaId: artMediaId,
    ));
    final what = switch (verified.kind) {
      'page' => 'page /${verified.path}',
      'file' => 'file "${attachment?.name}"',
      _ => 'post',
    };
    TransportLog.instance.log('Network: $what '
        'from ${_shortAddr(verified.author)} '
        '(${verified.hops} hop${verified.hops == 1 ? '' : 's'} away)');

    // Keep it flooding: spool a copy and hand it to everyone around.
    if (hops <= maxHops) {
      final forwarded = Map<String, Object?>.from(packet);
      forwarded['hops'] = hops;
      await _addToPostSpool(forwarded);
      await _offerPostsTo(onlinePeers);
    }
  }

  /// Publishes to everyone in the mesh (contacts or not) for [ttlSeconds]:
  /// on the global square, or on my site ([scope] =
  /// [EnvelopeCodec.scopeSite]). A private site post stays on this device.
  Future<void> postToNetwork(
    String text, {
    int ttlSeconds = 86400,
    Uint8List? imageBytes,
    String? imageMime,
    PreparedPostFile? file,
    String scope = EnvelopeCodec.scopeGlobal,
    bool isPrivate = false,
  }) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) throw StateError('Identity is locked');
    final private = isPrivate && scope == EnvelopeCodec.scopeSite;

    String? mediaId;
    String? mediaB64;
    if (imageBytes != null) {
      if (imageBytes.length > EnvelopeCodec.maxPostMediaBytes) {
        throw StateError(
            'Image is too large for a Network post (max 512 KB — every '
            'node in the mesh carries it)');
      }
      final item = await MediaStore.instance.saveBytes(
        imageBytes,
        name: 'post.jpg',
        mime: imageMime ?? 'image/jpeg',
        source: MediaSource.sent,
        temp: true, // lives with the post, not the Storage library
      );
      mediaId = item.id;
      mediaB64 = base64Encode(imageBytes);
    }

    PostAttachment? attachment;
    String? artMediaId;
    String? artB64;
    if (file != null) {
      attachment = file.attachment;
      // My own copy, so this device keeps sharing it wherever the
      // original goes.
      await BlobService.instance.addLocalFile(
        file.path,
        sha: attachment.sha256,
        name: attachment.name,
      );
      final pieceList = file.pieceList;
      if (pieceList != null) {
        await BlobService.instance.addPieceList(pieceList);
      }
      final cover = file.cover;
      if (cover != null) {
        artMediaId = (await MediaStore.instance.saveBytes(
          cover,
          name: 'cover',
          mime: _coverMime(cover),
          source: MediaSource.sent,
          temp: true,
        ))
            .id;
        artB64 = base64Encode(cover);
      }
      final inline = file.inlineBytes;
      if (inline != null) mediaB64 = base64Encode(inline);
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    final nickname = IdentityService.instance.active?.nickname;

    final post = NetworkPost(
      id: id,
      author: me,
      authorNick: nickname,
      text: text,
      tsMs: now,
      expiresMs: now + ttlSeconds * 1000,
      mediaId: mediaId,
      mediaMime: imageMime,
      scope: scope,
      attachment: attachment,
      artMediaId: artMediaId,
      isPrivate: private,
    );
    await NetworkService.instance.upsert(post);
    if (private) return;
    await _publishMyPost(post, mediaB64: mediaB64, artB64: artB64);
  }

  static String _coverMime(Uint8List bytes) =>
      bytes.length > 1 && bytes[0] == 0x89 && bytes[1] == 0x50
          ? 'image/png'
          : 'image/jpeg';

  /// Publishes (or replaces) a page of my site at [path] ('' = home page).
  /// [html] is the page source; a private page stays on this device.
  /// Returns the new version's id.
  Future<String> publishSitePage({
    required String path,
    required String title,
    required String html,
    required int ttlSeconds,
    bool isPrivate = false,
    String? replacingId,
  }) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) throw StateError('Identity is locked');
    if (!EnvelopeCodec.pagePathPattern.hasMatch(path)) {
      throw StateError('Page addresses use lowercase letters, numbers, - '
          'and _, with / between parts (like blog/day-1)');
    }
    if (utf8.encode(html).length > EnvelopeCodec.maxPageBytes) {
      throw StateError('Page is too large (max 96 KB, images included — '
          'every device in the mesh carries it)');
    }

    final previous = replacingId != null
        ? await NetworkService.instance.byId(replacingId)
        : await NetworkService.instance.page(me, path);
    if (previous != null) {
      await NetworkService.instance.remove(previous.id);
      if (!previous.isPrivate) {
        await _withdrawFromMesh(previous.id, previous.expiresMs);
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final page = NetworkPost(
      id: _uuid.v4(),
      author: me,
      authorNick: IdentityService.instance.active?.nickname,
      text: html,
      tsMs: now,
      expiresMs: now + ttlSeconds * 1000,
      scope: EnvelopeCodec.scopeSite,
      kind: 'page',
      path: path,
      title: title.trim().isEmpty ? null : title.trim(),
      isPrivate: isPrivate,
    );
    await NetworkService.instance.upsert(page);
    if (!isPrivate) await _publishMyPost(page);
    return page.id;
  }

  /// Makes one of my site posts or pages private (withdrawn from the mesh,
  /// kept here) or public again (re-published under a fresh id, since
  /// carriers already dropped the withdrawn one).
  Future<void> setNetworkPostPrivate(String id, bool makePrivate) async {
    final post = await NetworkService.instance.byId(id);
    if (post == null || post.isPrivate == makePrivate) return;
    if (makePrivate) {
      await _withdrawFromMesh(id, post.expiresMs);
      await NetworkService.instance.upsert(post.copyWith(isPrivate: true));
      return;
    }
    final fresh = post.copyWith(
      id: _uuid.v4(),
      tsMs: DateTime.now().millisecondsSinceEpoch,
      isPrivate: false,
    );
    await NetworkService.instance.rekey(id, fresh);
    final mediaId = fresh.mediaId;
    var media =
        mediaId == null ? null : await MediaStore.instance.readBytes(mediaId);
    final attachment = fresh.attachment;
    if (attachment != null &&
        attachment.size <= EnvelopeCodec.maxInlineFileBytes) {
      final path = await BlobService.instance.pathFor(attachment.sha256);
      if (path != null) media = await File(path).readAsBytes();
    }
    final artId = fresh.artMediaId;
    final art = artId == null ? null : await MediaStore.instance.readBytes(artId);
    await _publishMyPost(
      fresh,
      mediaB64: media == null ? null : base64Encode(media),
      artB64: art == null ? null : base64Encode(art),
    );
  }

  Future<void> _publishMyPost(
    NetworkPost post, {
    String? mediaB64,
    String? artB64,
  }) async {
    final packet = await EnvelopeCodec.buildNetworkPost(
      id: post.id,
      text: post.text,
      tsMs: post.tsMs,
      expMs: post.expiresMs,
      mediaB64: mediaB64,
      mediaMime: post.mediaMime,
      nickname: post.authorNick,
      scope: post.scope,
      pagePath: post.isPage ? post.path ?? '' : null,
      pageTitle: post.title,
      attachment: post.attachment,
      artB64: artB64,
    );
    _markSeen('post:${post.id}'); // never re-process our own echo
    await _addToPostSpool(packet);
    await _offerPostsTo(onlinePeers);
    TransportLog.instance.log('Network: published '
        '${post.isPage ? 'page /${post.path}' : 'a post'} to the mesh '
        '(${onlinePeers.length} in range)');
  }

  /// Deletes my post or page everywhere: locally at once, and (unless it
  /// was private) a signed tombstone floods the mesh so every carrier
  /// drops it too.
  Future<void> deleteNetworkPost(String id) async {
    final post = await NetworkService.instance.byId(id);
    await NetworkService.instance.remove(id);
    if (post?.isPrivate == true) return;
    await _withdrawFromMesh(
      id,
      post?.expiresMs ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Floods a signed tombstone for post [id] so every carrier drops it.
  Future<void> _withdrawFromMesh(String id, int contentExpMs) async {
    _deletedPostIds.add(id);
    // The tombstone must outlive every copy of the content.
    final expMs = max(
      DateTime.now().add(const Duration(hours: 48)).millisecondsSinceEpoch,
      contentExpMs,
    );
    final packet = await EnvelopeCodec.buildNetworkPost(
      id: id,
      text: '',
      tsMs: DateTime.now().millisecondsSinceEpoch,
      expMs: expMs,
      nickname: IdentityService.instance.active?.nickname,
      deleted: true,
    );
    _markSeen('postdel:$id');
    _postOfferedTo.remove(id); // the tombstone replaces the content copy
    await _addToPostSpool(packet);
    await _offerPostsTo(onlinePeers);
  }

  // ---- Post spool: active posts this node carries and re-floods -------

  Future<List<Map<String, Object?>>> _readPostSpool() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_postSpoolKey));
    if (raw == null || raw.isEmpty) return <Map<String, Object?>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, Object?>>[];
      return decoded
          .whereType<Map>()
          .map((m) => m.cast<String, Object?>())
          .toList();
    } catch (_) {
      return <Map<String, Object?>>[];
    }
  }

  Future<void> _writePostSpool(List<Map<String, Object?>> spool) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      IdentityScope.key(_postSpoolKey),
      jsonEncode(spool),
    );
  }

  Future<void> _addToPostSpool(Map<String, Object?> packet) async {
    final spool = await _readPostSpool();
    final id = packet['id'];
    spool.removeWhere((p) => p['id'] == id);
    spool.add(packet);

    // Enforce entry + size caps, oldest first — but other people's posts go
    // before mine: my posts and pages are this device's site, and it keeps
    // serving them to whoever walks into range.
    final me = await IdentityService.instance.getPublicAddressBase64();
    int sizeOf(Map<String, Object?> p) =>
        ((p['media'] as String?)?.length ?? 0) +
        ((p['art'] as String?)?.length ?? 0) +
        ((p['text'] as String?)?.length ?? 0) +
        512;
    spool.sort((a, b) {
      final mineA = a['author'] == me;
      final mineB = b['author'] == me;
      if (mineA != mineB) return mineA ? 1 : -1;
      return ((a['ts'] as num?) ?? 0).compareTo((b['ts'] as num?) ?? 0);
    });
    while (spool.length > _postSpoolMaxEntries) {
      final dropped = spool.removeAt(0);
      _postOfferedTo.remove(dropped['id']);
    }
    var totalChars = spool.fold<int>(0, (sum, p) => sum + sizeOf(p));
    while (totalChars > _postSpoolMaxChars && spool.isNotEmpty) {
      final dropped = spool.removeAt(0);
      _postOfferedTo.remove(dropped['id']);
      totalChars -= sizeOf(dropped);
    }
    await _writePostSpool(spool);
  }

  Future<void> _prunePostSpool() async {
    final spool = await _readPostSpool();
    final now = DateTime.now().millisecondsSinceEpoch;
    final before = spool.length;
    spool.removeWhere((p) {
      final exp = (p['exp'] as num?)?.toInt();
      final expired = exp != null && exp < now;
      if (expired) _postOfferedTo.remove(p['id']);
      return expired;
    });
    if (spool.length != before) await _writePostSpool(spool);
  }

  /// Remembers which posts were already deleted, so restarts don't let
  /// late copies resurrect them.
  Future<void> _seedDeletedPostIds() async {
    if (!IdentityScope.hasActive) return;
    for (final packet in await _readPostSpool()) {
      if (packet['del'] == true && packet['id'] is String) {
        _deletedPostIds.add(packet['id'] as String);
      }
    }
  }

  /// Hands every active carried post to peers that don't have it yet —
  /// this is how the feed reaches someone who just walked into the mesh.
  Future<void> _offerPostsTo(Set<String> peersNow) async {
    final transport = _transport;
    if (transport == null || peersNow.isEmpty) return;
    final spool = await _readPostSpool();
    if (spool.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final packet in spool) {
      final id = packet['id'];
      if (id is! String) continue;
      final exp = (packet['exp'] as num?)?.toInt();
      if (exp != null && exp < now) continue;
      final author = packet['author'] as String?;
      final offered =
          _postOfferedTo.putIfAbsent(id, () => <String>{});
      for (final peer in peersNow) {
        if (peer == author || offered.contains(peer)) continue;
        if (await transport.sendPacket(peer, packet)) {
          offered.add(peer);
        }
        // Failures retry naturally on the next tick/appearance.
      }
    }
  }

  String _shortAddr(String address) =>
      address.length <= 12 ? address : '${address.substring(0, 12)}…';

  // ---------------------------------------------------------------------
  // Control outbox (edits/deletes/stories with store-and-forward retry)
  // ---------------------------------------------------------------------

  /// [unique] gives the op a fresh message id per enqueue. Without it,
  /// re-sending the same act+target is deduplicated by receivers (right
  /// for edits/deletes, wrong for repeatable signals like transfer
  /// accepts, which must get through every time they are re-issued).
  Future<void> _enqueueControl({
    required String act,
    required String chatKey,
    required String target,
    String? text,
    int? ttl,
    List<String>? recipients,
    String? mediaB64,
    String? mediaMime,
    String? kind,
    bool unique = false,
  }) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    List<String> to;
    String? gid;
    if (recipients != null) {
      to = recipients;
    } else if (ChatStorage.isGroupChat(chatKey)) {
      gid = ChatStorage.groupIdOf(chatKey);
      final info = await ChatStorage.instance.getGroupInfo(gid);
      to = (info?.members ?? const <String>[])
          .where((a) => a != me)
          .toList();
    } else {
      to = [chatKey];
    }
    if (to.isEmpty) return;

    final ops = await _readControlOps();
    ops.add(<String, Object?>{
      'act': act,
      'chatKey': chatKey,
      'gid': gid,
      'target': target,
      'text': text,
      'ttl': ttl,
      'to': to,
      if (mediaB64 != null) 'media': mediaB64,
      if (mediaMime != null) 'mmime': mediaMime,
      if (kind != null) 'kind': kind,
      if (unique) 'salt': _uuid.v4(),
    });
    await _writeControlOps(ops);
    await _flushControlOutbox(onlinePeers);
  }

  Future<void> _flushControlOutbox(Set<String> onlineNow) async {
    if (_transport == null || onlineNow.isEmpty) return;
    final ops = await _readControlOps();
    if (ops.isEmpty) return;

    var changed = false;
    for (final op in ops) {
      final to = (op['to'] as List?)?.whereType<String>().toList() ?? [];
      final remaining = <String>[];
      for (final recipient in to) {
        final gid = op['gid'] as String?;
        GroupInfo? info;
        if (gid != null) {
          info = await ChatStorage.instance.getGroupInfo(gid);
        }
        final salt = op['salt'] as String?;
        final handedOff = await _deliverBody(
          recipient,
          MessageBody(
            messageId: salt == null
                ? '${op['act']}:${op['target']}:$recipient'
                : '${op['act']}:${op['target']}:$salt:$recipient',
            text: (op['text'] as String?) ?? '',
            timestamp: DateTime.now(),
            groupId: gid,
            groupMembers: info?.members,
            groupAdmin: info?.adminAddress,
            groupName: info?.name,
            action: op['act'] as String,
            targetId: op['target'] as String,
            ttlSeconds: (op['ttl'] as num?)?.toInt(),
            kind: op['kind'] as String?,
            mediaB64: op['media'] as String?,
            mediaMime: op['mmime'] as String?,
          ),
        );
        if (!handedOff) remaining.add(recipient);
      }
      if (remaining.length != to.length) {
        changed = true;
        op['to'] = remaining;
      }
    }

    if (changed) {
      ops.removeWhere(
          (op) => ((op['to'] as List?) ?? const []).isEmpty);
      await _writeControlOps(ops);
    }
  }

  Future<List<Map<String, Object?>>> _readControlOps() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(IdentityScope.key(_controlOutboxKey));
    if (raw == null || raw.isEmpty) return <Map<String, Object?>>[];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return <Map<String, Object?>>[];
    return decoded
        .whereType<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList();
  }

  Future<void> _writeControlOps(List<Map<String, Object?>> ops) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        IdentityScope.key(_controlOutboxKey), jsonEncode(ops));
  }

  // ---------------------------------------------------------------------
  // Group management
  // ---------------------------------------------------------------------

  Future<String> createGroup(
    List<String> memberAddresses, {
    String? name,
  }) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) throw StateError('Identity is locked');

    final groupId = _uuid.v4();
    final members = <String>{...memberAddresses, me}.toList();
    final trimmedName = name?.trim();
    await ChatStorage.instance.saveGroupInfo(GroupInfo(
      id: groupId,
      adminAddress: me,
      name: (trimmedName != null && trimmedName.isNotEmpty)
          ? trimmedName
          : null,
      members: members,
    ));
    final chatKey = ChatStorage.groupChatKey(groupId);
    await ChatStorage.instance.ensureChatExists(chatKey);
    _changed.add(chatKey);
    return chatKey;
  }

  Future<void> renameGroup(String chatKey, String name) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final me = await IdentityService.instance.getPublicAddressBase64();
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (me == null || info == null || !info.isAdmin(me)) {
      throw StateError('Only the group admin can rename the group');
    }

    final trimmed = name.trim();
    final updated = info.copyWith(
      name: trimmed.isEmpty ? null : trimmed,
      clearName: trimmed.isEmpty,
    );
    await ChatStorage.instance.saveGroupInfo(updated);
    await _broadcastGroupEvent(
      info: updated,
      action: 'rename',
      systemText: trimmed.isEmpty
          ? 'You cleared the group name'
          : 'You renamed the group to "$trimmed"',
    );
    _changed.add(chatKey);
  }

  Future<void> addGroupMembers(String chatKey, List<String> addresses) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final me = await IdentityService.instance.getPublicAddressBase64();
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (me == null || info == null || !info.isAdmin(me)) {
      throw StateError('Only the group admin can add members');
    }

    final merged = <String>{...info.members, ...addresses}.toList();
    final updated = info.copyWith(members: merged);
    await ChatStorage.instance.saveGroupInfo(updated);
    await _broadcastGroupEvent(
      info: updated,
      action: 'members',
      systemText: 'You added ${addresses.length} member(s)',
    );
    _changed.add(chatKey);
  }

  Future<void> removeGroupMember(String chatKey, String memberAddress) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final me = await IdentityService.instance.getPublicAddressBase64();
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (me == null || info == null || !info.isAdmin(me)) {
      throw StateError('Only the group admin can remove members');
    }
    if (memberAddress == me) {
      throw StateError('Use leave group to remove yourself');
    }

    final updatedMembers =
        info.members.where((a) => a != memberAddress).toList();
    final updated = info.copyWith(members: updatedMembers);
    await ChatStorage.instance.saveGroupInfo(updated);
    await _broadcastGroupEvent(
      info: updated,
      action: 'members',
      systemText: 'You removed a member from the group',
      alsoNotify: [memberAddress],
    );
    _changed.add(chatKey);
  }

  Future<void> leaveGroup(String chatKey) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final me = await IdentityService.instance.getPublicAddressBase64();
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (me == null || info == null) return;

    final remaining = info.members.where((a) => a != me).toList();
    if (remaining.isNotEmpty) {
      final updated = info.copyWith(members: remaining);
      await _broadcastGroupEvent(
        info: updated,
        action: 'leave',
        systemText: 'You left the group',
      );
    }

    await ChatStorage.instance.leaveGroup(groupId, me);
    _changed.add(chatKey);
  }

  Future<void> _broadcastGroupEvent({
    required GroupInfo info,
    required String action,
    required String systemText,
    List<String> alsoNotify = const <String>[],
  }) async {
    final me = await IdentityService.instance.getPublicAddressBase64();
    if (me == null) return;

    final chatKey = ChatStorage.groupChatKey(info.id);
    final eventId = _uuid.v4();
    final timestamp = DateTime.now();

    await ChatStorage.instance.appendMessage(
      chatKey,
      ChatMessage(
        id: eventId,
        text: systemText,
        isMe: true,
        timestamp: timestamp,
        status: MessageStatus.pending,
        isSystem: true,
      ),
    );

    final recipients = <String>{
      ...info.members.where((a) => a != me),
      ...alsoNotify.where((a) => a != me),
    };
    for (final recipient in recipients) {
      await _deliverBody(
        recipient,
        MessageBody(
          messageId: eventId,
          text: '',
          timestamp: timestamp,
          groupId: info.id,
          groupMembers: info.members,
          groupAdmin: info.adminAddress,
          groupName: info.name,
          groupEvent: action,
        ),
      );
    }
  }

  // ---------------------------------------------------------------------
  // Store-and-forward retries
  // ---------------------------------------------------------------------

  /// Immediately retries everything pending or failed in [chatKey].
  /// Unlimited: each manual resend re-arms the deadline, clears the
  /// per-path backoff state, and re-floods — so once someone plants a new
  /// gateway in the gap, a retry gets through.
  Future<void> retryChat(String chatKey) async {
    _lastRelayAttemptMs.clear();
    if (ChatStorage.isGroupChat(chatKey)) {
      await _flushGroupPending(chatKey, onlinePeers, force: true);
    } else {
      // Failed → pending: the full state machine runs again from scratch.
      final messages = await ChatStorage.instance.listMessages(chatKey);
      var reset = false;
      for (final message in messages) {
        if (!message.isMe || message.status != MessageStatus.failed) continue;
        await ChatStorage.instance
            .updateMessageStatus(chatKey, message.id, MessageStatus.pending);
        _armDeliveryDeadline(message.id, MessageStatus.pending);
        // Forget which carriers already have it and which paths failed, so
        // the resend genuinely re-explores the mesh.
        _spoolOfferedTo.remove(message.id);
        _offerFailureMs
            .removeWhere((key, _) => key.startsWith('${message.id}:'));
        reset = true;
      }
      if (reset) _changed.add(chatKey);
      await _flushDirectPending(chatKey, force: true);
    }
    await _flushControlOutbox(onlinePeers);
  }

  Future<void> _flushPendingFor(Set<String> onlineNow) async {
    if (onlineNow.isEmpty) return;
    final chats = await ChatStorage.instance.listChats();
    for (final chatKey in chats) {
      if (ChatStorage.isGroupChat(chatKey)) {
        await _flushGroupPending(chatKey, onlineNow);
      } else {
        await _flushDirectPending(chatKey);
      }
    }
  }

  /// Only re-attempt a relay handoff for a message every 45 seconds; a
  /// direct link to the recipient is always attempted immediately.
  bool _shouldAttempt(String messageId, String recipient, bool force) {
    if (force || onlinePeers.contains(recipient)) return true;
    if (onlinePeers.isEmpty) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastRelayAttemptMs['$messageId:$recipient'] ?? 0;
    if (now - last < 45000) return false;
    _lastRelayAttemptMs['$messageId:$recipient'] = now;
    return true;
  }

  Future<void> _flushDirectPending(
    String peerAddress, {
    bool force = false,
  }) async {
    final ttl = await SettingsService.instance.getAutoDeleteSeconds();
    final messages = await ChatStorage.instance.listMessages(peerAddress);
    for (final message in messages) {
      // Failed messages keep retrying silently in the background; only a
      // real delivery ack (or a manual resend) changes what the user sees.
      final retriable = message.status == MessageStatus.pending ||
          message.status == MessageStatus.failed;
      if (!message.isMe || !retriable) continue;
      if (message.isSystem) continue;
      if (!_shouldAttempt(message.id, peerAddress, force)) continue;

      final media = await _reloadMedia(message);
      final handedOff = await _deliverBody(
        peerAddress,
        _bodyFor(message, media, ttl),
      );
      if (handedOff && message.status == MessageStatus.pending) {
        await ChatStorage.instance
            .updateMessageStatus(peerAddress, message.id, MessageStatus.sent);
        _changed.add(peerAddress);
        _armDeliveryDeadline(message.id, MessageStatus.sent);
      }
    }
  }

  Future<void> _flushGroupPending(
    String chatKey,
    Set<String> onlineNow, {
    bool force = false,
  }) async {
    final groupId = ChatStorage.groupIdOf(chatKey);
    final info = await ChatStorage.instance.getGroupInfo(groupId);
    if (info == null) return;
    final ttl = await SettingsService.instance.getAutoDeleteSeconds();

    final messages = await ChatStorage.instance.listMessages(chatKey);
    for (final message in messages) {
      if (!message.isMe || message.pendingTo.isEmpty) continue;
      final media = await _reloadMedia(message);
      for (final recipient in message.pendingTo) {
        if (!_shouldAttempt(message.id, recipient, force)) continue;
        final handedOff = await _deliverBody(
          recipient,
          _bodyFor(message, media, ttl, info: info),
        );
        if (handedOff) {
          await ChatStorage.instance
              .markGroupMessageHandedOff(chatKey, message.id, recipient);
          _changed.add(chatKey);
        }
      }
    }
  }

  /// Rebuilds the media payload of a stored message for (re)sending.
  Future<_MediaPayload?> _reloadMedia(ChatMessage message) async {
    final mediaId = message.mediaId;
    final kind = message.kind;
    if (mediaId == null || kind == null) return null;
    final item = await MediaStore.instance.get(mediaId);
    final bytes = await MediaStore.instance.readBytes(mediaId);
    if (item == null || bytes == null) return null;
    return _MediaPayload(
      item: item,
      b64: base64Encode(bytes),
      kind: kind,
      temp: message.mediaTemp,
      durationMs: message.durationMs,
      voicemail: message.voicemail,
    );
  }
}

class _MediaPayload {
  final MediaItem item;
  final String b64;
  final String kind;
  final bool temp;
  final int? durationMs;
  final bool voicemail;

  const _MediaPayload({
    required this.item,
    required this.b64,
    required this.kind,
    required this.temp,
    this.durationMs,
    this.voicemail = false,
  });
}
