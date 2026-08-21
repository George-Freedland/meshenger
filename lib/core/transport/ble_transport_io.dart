import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../services/identity_service.dart';
import '../services/transport_log.dart';
import 'envelope_codec.dart';
import 'mesh_transport.dart';

/// Bluetooth LE transport (desktop/mobile).
///
/// GATT layout (every device is simultaneously central and peripheral):
/// - Announce characteristic (read): a signed announcement proving which
///   Ed25519 address + X25519 key this device belongs to.
/// - Inbox characteristic (write): receives opaque JSON packets as chunked
///   writes. Each chunk is prefixed with a 1-byte flag; bit 0 marks the
///   final chunk. The GATT write response of the final chunk doubles as
///   the transport-level ack: it only succeeds after the packet parsed.
/// - Outbox characteristic (notify): the push channel. A peer that
///   subscribes gets packets *pushed* to it as chunked notifications (same
///   framing). This is what lets a relay/router initiate delivery to a
///   phone whose app is backgrounded — iOS keeps subscriptions alive and
///   wakes the app when a notification arrives.
///
/// After subscribing, a central writes its signed announcement into the
/// peer's inbox (a "hello") so the peripheral knows which mesh address the
/// push channel leads to. Hellos repeat every [helloInterval] as a
/// keepalive.
class _IoBleTransport implements MeshTransport {
  static final UUID serviceUuid =
      UUID.fromString('4d455348-454e-4745-5242-4c4530303031');
  static final UUID announceCharUuid =
      UUID.fromString('4d455348-454e-4745-5242-4c4530303032');
  static final UUID inboxCharUuid =
      UUID.fromString('4d455348-454e-4745-5242-4c4530303033');
  static final UUID outboxCharUuid =
      UUID.fromString('4d455348-454e-4745-5242-4c4530303034');

  static const Duration rescanInterval = Duration(seconds: 12);
  static const Duration peerTimeout = Duration(seconds: 40);

  /// How often we re-send our hello over open push channels (keepalive) —
  /// also refreshes our lastSeen on the peer's side.
  static const Duration helloInterval = Duration(seconds: 20);

  /// Inbound push subscribers are dropped after this long without a write
  /// (3 missed hellos plus slack).
  static const Duration inboundTimeout = Duration(seconds: 65);

  /// Concurrent outbox subscriptions we hold as a central. Keeps the BLE
  /// connection budget sane in a crowd; epidemic routing needs only a few.
  static const int maxSubscriptions = 4;

  /// Per-chunk GATT timeout; large media envelopes are many chunks, each
  /// with its own window, so big transfers still complete.
  static const Duration gattTimeout = Duration(seconds: 15);
  static const int _finalChunkFlag = 0x01;

  CentralManager? _central;
  PeripheralManager? _peripheral;

  bool _running = false;
  String? _myAddress;
  Uint8List? _announcementBytes;

  final Map<String, _BlePeer> _peersByAddress = <String, _BlePeer>{};
  final Map<String, String> _addressByDeviceUuid = <String, String>{};
  final Map<String, int> _rssiByDeviceUuid = <String, int>{};
  final Set<String> _resolving = <String>{};
  final Map<String, int> _lastResolveAttemptMs = <String, int>{};

  /// Outbox subscriptions we hold as a central (device uuid → subscription).
  final Map<String, _OutboxSubscription> _outSubs =
      <String, _OutboxSubscription>{};

  /// Push subscribers connected to our peripheral (central uuid → peer).
  final Map<String, _InboundPeer> _inboundPeers = <String, _InboundPeer>{};
  final Map<String, String> _inboundByAddress = <String, String>{};
  final Set<String> _notifySubscribed = <String>{};

  /// The mutable outbox characteristic instance (needed to notify).
  GATTCharacteristic? _outboxChar;

  /// Inbound chunk reassembly buffers, keyed by the writing central's UUID.
  final Map<String, BytesBuilder> _inboxBuffers = <String, BytesBuilder>{};

  /// Notification reassembly buffers, keyed by the notifying device's UUID.
  final Map<String, BytesBuilder> _notifyBuffers = <String, BytesBuilder>{};

  final _packets = StreamController<Map<String, Object?>>.broadcast();
  final _peersChanged = StreamController<Set<String>>.broadcast();
  Set<String> _lastEmittedPeers = const <String>{};

  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  Timer? _rescanTimer;
  Timer? _reapTimer;
  Timer? _helloTimer;

  /// Serializes central-side GATT operations (connect/discover/write); BLE
  /// stacks misbehave when multiple operations run concurrently.
  Future<void> _gattQueue = Future<void>.value();

  @override
  bool get isRunning => _running;

  @override
  Set<String> get onlinePeers {
    final now = DateTime.now();
    final result = <String>{};
    for (final entry in _peersByAddress.entries) {
      if (now.difference(entry.value.lastSeen) < peerTimeout) {
        result.add(entry.key);
      }
    }
    // Peers holding an open push channel to us are reachable even if we
    // can't scan them (e.g. a backgrounded iPhone connected to this relay
    // node).
    for (final entry in _inboundPeers.entries) {
      if (_notifySubscribed.contains(entry.key) &&
          now.difference(entry.value.lastSeen) < inboundTimeout) {
        result.add(entry.value.address);
      }
    }
    return result;
  }

  @override
  String? x25519For(String peerAddress) {
    final scanned = _peersByAddress[peerAddress]?.x25519Base64;
    if (scanned != null) return scanned;
    final inboundUuid = _inboundByAddress[peerAddress];
    if (inboundUuid != null) {
      return _inboundPeers[inboundUuid]?.x25519Base64;
    }
    return null;
  }

  @override
  Stream<Map<String, Object?>> get onPacket => _packets.stream;

  @override
  Stream<Set<String>> get onPeersChanged => _peersChanged.stream;

  @override
  Future<void> start() async {
    if (_running) return;

    final identity = IdentityService.instance;
    final address = await identity.getPublicAddressBase64();
    if (address == null || !identity.isUnlocked) {
      throw StateError('Identity must be unlocked before starting transport');
    }
    _myAddress = address;
    _announcementBytes = await EnvelopeCodec.buildBleAnnouncementBytes();

    final central = _central ??= CentralManager();

    // Desktop Linux ships central-only BLE (no peripheral channel); the
    // relay daemon covers the peripheral role there.
    PeripheralManager? peripheral;
    try {
      peripheral = _peripheral ??= PeripheralManager();
    } catch (_) {
      peripheral = null;
    }

    if (Platform.isAndroid) {
      try {
        await central.authorize();
        await peripheral?.authorize();
      } catch (_) {
        // Permission dialogs are best-effort; state check below is decisive.
      }
    }

    final log = TransportLog.instance;
    log.log('BLE: starting (my address ${address.substring(0, 8)}…)');

    await _waitPoweredOn(central);

    // --- Peripheral role: advertise + accept inbound packets ---
    var advertising = false;
    if (peripheral != null) {
      try {
        await _waitPoweredOn(peripheral);
        _subscriptions.add(
          peripheral.characteristicReadRequested.listen(_scheduleReadRequest),
        );
        _subscriptions.add(
          peripheral.characteristicWriteRequested
              .listen(_scheduleWriteRequest),
        );
        _subscriptions.add(
          peripheral.characteristicNotifyStateChanged
              .listen(_handleNotifyStateChanged),
        );

        final outboxChar = GATTCharacteristic.mutable(
          uuid: outboxCharUuid,
          properties: [GATTCharacteristicProperty.notify],
          permissions: [GATTCharacteristicPermission.read],
          descriptors: [],
        );

        await peripheral.removeAllServices();
        await peripheral.addService(
          GATTService(
            uuid: serviceUuid,
            isPrimary: true,
            includedServices: [],
            characteristics: [
              GATTCharacteristic.mutable(
                uuid: announceCharUuid,
                properties: [GATTCharacteristicProperty.read],
                permissions: [GATTCharacteristicPermission.read],
                descriptors: [],
              ),
              GATTCharacteristic.mutable(
                uuid: inboxCharUuid,
                properties: [
                  GATTCharacteristicProperty.write,
                  GATTCharacteristicProperty.writeWithoutResponse,
                ],
                permissions: [GATTCharacteristicPermission.write],
                descriptors: [],
              ),
              outboxChar,
            ],
          ),
        );
        _outboxChar = outboxChar;

        // Windows: addService() already calls
        // GattServiceProvider.StartAdvertising, which makes the Meshenger
        // service discoverable. Calling BluetoothLEAdvertisementPublisher
        // with ServiceUuids on top of that throws winrt "The parameter is
        // incorrect." (see plugin example).
        if (!Platform.isWindows) {
          await peripheral.startAdvertising(
            Advertisement(serviceUUIDs: [serviceUuid]),
          );
        }
        advertising = true;
      } catch (e) {
        log.log('BLE: peripheral role unavailable ($e)');
      }
    }
    if (advertising) {
      log.log('BLE: advertising Meshenger service (announce+inbox+outbox)');
    } else {
      _peripheral = null;
      _outboxChar = null;
      log.log('BLE: running central-only — this device can discover and '
          'send, but is not discoverable. Run the meshenger relay daemon '
          'alongside for full mesh participation.');
    }

    // --- Central role: discover peers, subscribe to push channels ---
    _subscriptions.add(central.discovered.listen(_handleDiscovered));
    _subscriptions.add(
      central.characteristicNotified.listen(_handleNotified),
    );
    _subscriptions.add(
      central.connectionStateChanged.listen(_handleConnectionStateChanged),
    );
    await _startDiscovery(central);

    // macOS/iOS coalesce repeated advertisements from the same device, so
    // periodically restart discovery to re-observe devices that are still
    // present, keeping lastSeen fresh.
    _rescanTimer = Timer.periodic(rescanInterval, (_) => _restartDiscovery());
    _reapTimer = Timer.periodic(peerTimeout, (_) => _reapStalePeers());
    _helloTimer = Timer.periodic(helloInterval, (_) => _sendHellos());

    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _reapTimer?.cancel();
    _reapTimer = null;
    _helloTimer?.cancel();
    _helloTimer = null;

    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    // Close push channels we hold as a central.
    final central = _central;
    if (central != null) {
      for (final sub in _outSubs.values.toList()) {
        try {
          await central.disconnect(sub.peripheral);
        } catch (_) {}
      }
    }
    _outSubs.clear();

    try {
      await _central?.stopDiscovery();
    } catch (_) {}
    try {
      if (!Platform.isWindows) {
        await _peripheral?.stopAdvertising();
      }
    } catch (_) {}
    try {
      await _peripheral?.removeAllServices();
    } catch (_) {}

    _peersByAddress.clear();
    _addressByDeviceUuid.clear();
    _rssiByDeviceUuid.clear();
    _resolving.clear();
    _lastResolveAttemptMs.clear();
    _inboxBuffers.clear();
    _notifyBuffers.clear();
    _inboundPeers.clear();
    _inboundByAddress.clear();
    _notifySubscribed.clear();
    _outboxChar = null;
    _emitPeersIfChanged();
  }

  // -----------------------------------------------------------------------
  // Discovery (central role)
  // -----------------------------------------------------------------------

  bool _loggedDiscoveryMode = false;

  Future<void> _startDiscovery(CentralManager central) async {
    // Windows: the advertisement watcher's service-UUID filter silently
    // matches nothing when the peer carries its 128-bit UUID in the scan
    // response (macOS/iOS peripherals do). Scan broadly and filter by the
    // advertised UUIDs in _handleDiscovered instead.
    if (Platform.isWindows) {
      await central.startDiscovery();
      if (!_loggedDiscoveryMode) {
        _loggedDiscoveryMode = true;
        TransportLog.instance
            .log('BLE: scanning (broad, filtering in app)');
      }
      return;
    }
    await central.startDiscovery(serviceUUIDs: [serviceUuid]);
    if (!_loggedDiscoveryMode) {
      _loggedDiscoveryMode = true;
      TransportLog.instance.log('BLE: scanning (service filter)');
    }
  }

  Future<void> _waitPoweredOn(BluetoothLowEnergyManager manager) async {
    if (manager.state == BluetoothLowEnergyState.poweredOn) return;
    if (manager.state == BluetoothLowEnergyState.unsupported) {
      throw StateError('Bluetooth LE is not supported on this device');
    }
    try {
      await manager.stateChanged
          .firstWhere((e) => e.state == BluetoothLowEnergyState.poweredOn)
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw StateError(
        'Bluetooth is not available (state: ${manager.state.name}). '
        'Make sure Bluetooth is turned on.',
      );
    }
  }

  final Set<String> _loggedDevices = <String>{};

  @override
  Map<String, int> get peerRssi {
    final result = <String, int>{};
    for (final entry in _addressByDeviceUuid.entries) {
      final rssi = _rssiByDeviceUuid[entry.key];
      if (rssi != null) result[entry.value] = rssi;
    }
    return result;
  }

  void _handleDiscovered(DiscoveredEventArgs event) {
    final deviceUuid = event.peripheral.uuid.toString();
    _rssiByDeviceUuid[deviceUuid] = event.rssi;
    // On non-Windows platforms the native scan filter already guarantees
    // this is a Meshenger device (and the callback may omit the UUID list).
    final advertisesMeshenger = !Platform.isWindows ||
        event.advertisement.serviceUUIDs.contains(serviceUuid);

    if (advertisesMeshenger && _loggedDevices.add(deviceUuid)) {
      final name = event.advertisement.name;
      TransportLog.instance.log(
        'BLE: discovered Meshenger device $deviceUuid'
        '${name != null && name.isNotEmpty ? ' "$name"' : ''}',
      );
    }

    final knownAddress = _addressByDeviceUuid[deviceUuid];
    if (knownAddress != null) {
      final peer = _peersByAddress[knownAddress];
      if (peer != null) {
        _peersByAddress[knownAddress] =
            peer.copyWith(peripheral: event.peripheral, lastSeen: DateTime.now());
        _emitPeersIfChanged();
        // Known peer without a push channel: retry subscribing now and then
        // (it may have gained an outbox, or a previous attempt failed).
        if (!_outSubs.containsKey(deviceUuid) &&
            _outSubs.length < maxSubscriptions) {
          _scheduleResolve(event.peripheral);
        }
        return;
      }
    }

    // On the broad Windows scan every nearby BLE device shows up here; only
    // probe the ones that advertise the Meshenger service.
    if (!advertisesMeshenger) return;

    _scheduleResolve(event.peripheral);
  }

  /// Queues a resolve (connect + announce + subscribe) for a device, with a
  /// throttle so re-discoveries don't hammer the same device.
  void _scheduleResolve(Peripheral device) {
    final deviceUuid = device.uuid.toString();
    if (_resolving.contains(deviceUuid)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastResolveAttemptMs[deviceUuid] ?? 0;
    if (now - last < 30000 && _addressByDeviceUuid.containsKey(deviceUuid)) {
      return;
    }
    _lastResolveAttemptMs[deviceUuid] = now;
    _resolving.add(deviceUuid);
    _enqueueGatt(() => _resolvePeer(device)).whenComplete(() {
      _resolving.remove(deviceUuid);
    });
  }

  /// Connects to a Meshenger device, reads and verifies its signed
  /// announcement, records the peer, and — when the device serves an
  /// outbox — subscribes to it and keeps the connection open as a push
  /// channel.
  Future<void> _resolvePeer(Peripheral device) async {
    final central = _central;
    final log = TransportLog.instance;
    if (central == null || !_running) return;
    var step = 'connect';
    var keepOpen = false;
    try {
      await central.connect(device).timeout(gattTimeout);
      step = 'discoverGATT';
      final services = await central.discoverGATT(device).timeout(gattTimeout);
      final announceChar = _findCharacteristic(services, announceCharUuid);
      if (announceChar == null) {
        // Not a Meshenger device (expected during broad scans on Windows).
        log.log('BLE: ${device.uuid} has no Meshenger service '
            '(${services.length} services), skipping');
        return;
      }

      step = 'read announce';
      final bytes =
          await central.readCharacteristic(device, announceChar).timeout(gattTimeout);
      final peerIdentity = await EnvelopeCodec.verifyBleAnnouncementBytes(bytes);
      if (peerIdentity == null) {
        log.log('BLE: ${device.uuid} announce failed verification '
            '(${bytes.length} bytes)');
        return;
      }
      if (peerIdentity.address == _myAddress) return;

      _addressByDeviceUuid[device.uuid.toString()] = peerIdentity.address;
      _peersByAddress[peerIdentity.address] = _BlePeer(
        peripheral: device,
        x25519Base64: peerIdentity.x25519Base64,
        lastSeen: DateTime.now(),
      );
      log.log('BLE: peer online ${_shortAddr(peerIdentity.address)} '
          '(device ${device.uuid})');
      _emitPeersIfChanged();

      // Push channel: subscribe to the peer's outbox and identify ourselves
      // so it can push packets to us — even while our app is backgrounded.
      final outboxChar = _findCharacteristic(services, outboxCharUuid);
      final inboxChar = _findCharacteristic(services, inboxCharUuid);
      final announcement = _announcementBytes;
      if (outboxChar != null &&
          inboxChar != null &&
          announcement != null &&
          !_outSubs.containsKey(device.uuid.toString()) &&
          _outSubs.length < maxSubscriptions) {
        step = 'subscribe outbox';
        await central
            .setCharacteristicNotifyState(device, outboxChar, state: true)
            .timeout(gattTimeout);
        step = 'hello';
        await _writeChunks(central, device, inboxChar, announcement);
        _outSubs[device.uuid.toString()] = _OutboxSubscription(
          peripheral: device,
          address: peerIdentity.address,
          inboxChar: inboxChar,
        );
        keepOpen = true;
        log.log('BLE: push channel open with '
            '${_shortAddr(peerIdentity.address)} (subscribed to outbox)');
      }
    } catch (e) {
      // Device went away or isn't a functioning Meshenger node.
      log.log('BLE: resolve ${device.uuid} failed at $step: $e');
    } finally {
      if (!keepOpen) {
        try {
          await central.disconnect(device);
        } catch (_) {}
      }
    }
  }

  static String _shortAddr(String address) =>
      address.length <= 12 ? address : '${address.substring(0, 12)}…';

  Future<void> _restartDiscovery() async {
    final central = _central;
    if (central == null || !_running) return;
    try {
      await central.stopDiscovery();
      await _startDiscovery(central);
    } catch (e) {
      // Bluetooth may have turned off; the reap timer will clear peers.
      TransportLog.instance.log('BLE: restart discovery failed: $e');
    }
  }

  void _reapStalePeers() {
    final now = DateTime.now();
    final stale = _peersByAddress.entries
        .where((e) =>
            now.difference(e.value.lastSeen) > peerTimeout &&
            // Peers with a live push channel are online regardless of scans
            // (advertising stops on some stacks while connected).
            !_outSubs.values.any((s) => s.address == e.key))
        .map((e) => e.key)
        .toList();
    for (final address in stale) {
      final peer = _peersByAddress.remove(address);
      if (peer != null) {
        _addressByDeviceUuid.remove(peer.peripheral.uuid.toString());
      }
    }

    final staleInbound = _inboundPeers.entries
        .where((e) => now.difference(e.value.lastSeen) > inboundTimeout)
        .map((e) => e.key)
        .toList();
    for (final centralUuid in staleInbound) {
      final inbound = _inboundPeers.remove(centralUuid);
      if (inbound != null) {
        _inboundByAddress.remove(inbound.address);
      }
    }

    if (stale.isNotEmpty || staleInbound.isNotEmpty) {
      _emitPeersIfChanged();
    }
  }

  void _emitPeersIfChanged() {
    final current = onlinePeers;
    if (current.length == _lastEmittedPeers.length &&
        current.containsAll(_lastEmittedPeers)) {
      return;
    }
    _lastEmittedPeers = current;
    _peersChanged.add(current);
  }

  void _touchPeer(String address) {
    final peer = _peersByAddress[address];
    if (peer != null) {
      _peersByAddress[address] = peer.copyWith(lastSeen: DateTime.now());
    }
    _emitPeersIfChanged();
  }

  // -----------------------------------------------------------------------
  // Push channels (central side): subscriptions + keepalive
  // -----------------------------------------------------------------------

  _OutboxSubscription? _subByAddress(String address) {
    for (final sub in _outSubs.values) {
      if (sub.address == address) return sub;
    }
    return null;
  }

  void _handleConnectionStateChanged(
    PeripheralConnectionStateChangedEventArgs event,
  ) {
    if (event.state != ConnectionState.disconnected) return;
    final deviceUuid = event.peripheral.uuid.toString();
    _notifyBuffers.remove(deviceUuid);
    final sub = _outSubs.remove(deviceUuid);
    if (sub != null) {
      TransportLog.instance.log(
          'BLE: push channel to ${_shortAddr(sub.address)} dropped '
          '(link lost); rescanning will reopen it');
    }
  }

  void _dropSubscription(String deviceUuid) {
    final sub = _outSubs.remove(deviceUuid);
    if (sub == null) return;
    TransportLog.instance
        .log('BLE: push channel to ${_shortAddr(sub.address)} closed');
    final central = _central;
    if (central != null) {
      unawaited(() async {
        try {
          await central.disconnect(sub.peripheral);
        } catch (_) {}
      }());
    }
  }

  /// Periodic hello over every open push channel: keeps our entry fresh on
  /// the peer's side and doubles as a liveness probe.
  Future<void> _sendHellos() async {
    final central = _central;
    final announcement = _announcementBytes;
    if (central == null || announcement == null || !_running) return;
    for (final entry in _outSubs.entries.toList()) {
      await _enqueueGatt(() async {
        final sub = _outSubs[entry.key];
        if (sub == null) return;
        try {
          await _writeChunks(central, sub.peripheral, sub.inboxChar,
              announcement);
          _touchPeer(sub.address);
        } catch (e) {
          TransportLog.instance.log(
              'BLE: keepalive to ${_shortAddr(sub.address)} failed: $e');
          _dropSubscription(entry.key);
        }
      });
    }
  }

  /// Reassembles chunked notifications pushed to us over a subscribed
  /// outbox and surfaces the packets to the router.
  void _handleNotified(GATTCharacteristicNotifiedEventArgs event) {
    if (event.characteristic.uuid != outboxCharUuid) return;
    if (event.value.isEmpty) return;
    final deviceUuid = event.peripheral.uuid.toString();

    final flags = event.value[0];
    final buffer = _notifyBuffers.putIfAbsent(deviceUuid, BytesBuilder.new);
    buffer.add(event.value.sublist(1));
    if ((flags & _finalChunkFlag) == 0) return;

    final payload = buffer.takeBytes();
    _notifyBuffers.remove(deviceUuid);

    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is Map && decoded['t'] is String) {
        final packet = decoded.cast<String, Object?>();
        TransportLog.instance.log(
            'BLE: received ${packet['t']} pushed over outbox '
            '(${payload.length} bytes)');
        final address = _addressByDeviceUuid[deviceUuid];
        if (address != null) _touchPeer(address);
        _packets.add(packet);
      }
    } catch (_) {
      // A dropped chunk corrupts the reassembly; the mesh's retry loops
      // re-deliver.
    }
  }

  // -----------------------------------------------------------------------
  // Sending
  // -----------------------------------------------------------------------

  @override
  Future<bool> sendPacket(
    String peerAddress,
    Map<String, Object?> packet,
  ) async {
    if (!_running) return false;
    final central = _central;
    final payload = utf8.encode(jsonEncode(packet));

    // 1. Fast path: a push channel to this peer is already open — write
    //    over the live connection, no connect/discover round trips.
    if (central != null) {
      final sub = _subByAddress(peerAddress);
      if (sub != null) {
        var ok = false;
        await _enqueueGatt(() async {
          if (_subByAddress(peerAddress) == null) return;
          try {
            await _writeChunks(central, sub.peripheral, sub.inboxChar, payload);
            ok = true;
          } catch (e) {
            TransportLog.instance.log(
                'BLE: live-channel write to ${_shortAddr(peerAddress)} '
                'failed: $e');
            _dropSubscription(sub.peripheral.uuid.toString());
          }
        });
        if (ok) {
          TransportLog.instance.log(
              'BLE: delivered ${payload.length} bytes to '
              '${_shortAddr(peerAddress)} (live channel)');
          _touchPeer(peerAddress);
          return true;
        }
      }
    }

    // 2. Scan-resolved peer: connect, write, disconnect.
    final peer = _peersByAddress[peerAddress];
    if (peer != null && central != null) {
      var delivered = false;
      await _enqueueGatt(() async {
        delivered = await _deliverPayload(peer.peripheral, payload);
      });
      if (delivered) return true;
    }

    // 3. Push: the peer holds a channel to us (it subscribed to our
    //    outbox) — notify it, chunk by chunk. This is how a router
    //    initiates delivery to a device it cannot scan.
    return _pushToInbound(peerAddress, payload);
  }

  Future<bool> _deliverPayload(Peripheral device, List<int> payload) async {
    final central = _central;
    final log = TransportLog.instance;
    if (central == null) return false;
    var step = 'connect';
    try {
      await central.connect(device).timeout(gattTimeout);
      step = 'discoverGATT';
      final services = await central.discoverGATT(device).timeout(gattTimeout);
      final inboxChar = _findCharacteristic(services, inboxCharUuid);
      if (inboxChar == null) {
        log.log('BLE: deliver to ${device.uuid}: inbox characteristic missing');
        return false;
      }
      step = 'write';
      await _writeChunks(central, device, inboxChar, payload);
      log.log('BLE: delivered ${payload.length} bytes to ${device.uuid}');
      return true;
    } catch (e) {
      log.log('BLE: deliver to ${device.uuid} failed at $step: $e');
      return false;
    } finally {
      // Never tear down a live push channel.
      if (!_outSubs.containsKey(device.uuid.toString())) {
        try {
          await central.disconnect(device);
        } catch (_) {}
      }
    }
  }

  /// Writes [payload] into [characteristic] as flag-framed chunks. The
  /// final chunk's write response is the transport-level ack.
  Future<void> _writeChunks(
    CentralManager central,
    Peripheral device,
    GATTCharacteristic characteristic,
    List<int> payload,
  ) async {
    final maxWriteLength = await central.getMaximumWriteLength(
      device,
      type: GATTCharacteristicWriteType.withResponse,
    );
    // 1 byte reserved for the chunk flag.
    final chunkSize = (maxWriteLength - 1).clamp(19, 511);

    for (var offset = 0; offset < payload.length; offset += chunkSize) {
      final end = (offset + chunkSize < payload.length)
          ? offset + chunkSize
          : payload.length;
      final isLast = end == payload.length;
      final chunk = Uint8List(end - offset + 1);
      chunk[0] = isLast ? _finalChunkFlag : 0x00;
      chunk.setRange(1, chunk.length, payload, offset);

      await central
          .writeCharacteristic(
            device,
            characteristic,
            value: chunk,
            type: GATTCharacteristicWriteType.withResponse,
          )
          .timeout(gattTimeout);
    }
  }

  /// Pushes a packet to a peer that subscribed to our outbox, as chunked
  /// notifications. No per-chunk ack exists at this layer — end-to-end
  /// encrypted acks confirm real delivery.
  Future<bool> _pushToInbound(String peerAddress, List<int> payload) async {
    final peripheral = _peripheral;
    final outbox = _outboxChar;
    if (peripheral == null || outbox == null) return false;
    final centralUuid = _inboundByAddress[peerAddress];
    if (centralUuid == null || !_notifySubscribed.contains(centralUuid)) {
      return false;
    }
    final inbound = _inboundPeers[centralUuid];
    if (inbound == null) return false;

    try {
      int maxLen;
      try {
        maxLen = await peripheral.getMaximumNotifyLength(inbound.central);
      } catch (_) {
        maxLen = 181;
      }
      final chunkSize = (maxLen - 1).clamp(19, 511);

      for (var offset = 0; offset < payload.length; offset += chunkSize) {
        final end = (offset + chunkSize < payload.length)
            ? offset + chunkSize
            : payload.length;
        final isLast = end == payload.length;
        final chunk = Uint8List(end - offset + 1);
        chunk[0] = isLast ? _finalChunkFlag : 0x00;
        chunk.setRange(1, chunk.length, payload, offset);
        await peripheral
            .notifyCharacteristic(inbound.central, outbox, value: chunk)
            .timeout(gattTimeout);
      }
      TransportLog.instance.log(
          'BLE: pushed ${payload.length} bytes to '
          '${_shortAddr(peerAddress)} over our outbox');
      return true;
    } catch (e) {
      TransportLog.instance
          .log('BLE: push to ${_shortAddr(peerAddress)} failed: $e');
      return false;
    }
  }

  Future<void> _enqueueGatt(Future<void> Function() operation) {
    final next = _gattQueue.then((_) => operation());
    _gattQueue = next.catchError((_) {});
    return next;
  }

  static GATTCharacteristic? _findCharacteristic(
    List<GATTService> services,
    UUID uuid,
  ) {
    for (final service in services) {
      if (service.uuid != serviceUuid) continue;
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == uuid) return characteristic;
      }
    }
    return null;
  }

  // -----------------------------------------------------------------------
  // Receiving (peripheral role)
  // -----------------------------------------------------------------------

  /// The Windows plugin fires GATT callbacks on a native thread; hop to the
  /// Dart event loop before touching platform channels again.
  void _scheduleReadRequest(GATTCharacteristicReadRequestedEventArgs event) {
    unawaited(Future<void>(() => _handleReadRequest(event)));
  }

  void _scheduleWriteRequest(GATTCharacteristicWriteRequestedEventArgs event) {
    unawaited(Future<void>(() => _handleWriteRequest(event)));
  }

  void _handleNotifyStateChanged(
    GATTCharacteristicNotifyStateChangedEventArgs event,
  ) {
    if (event.characteristic.uuid != outboxCharUuid) return;
    final centralUuid = event.central.uuid.toString();
    if (event.state) {
      _notifySubscribed.add(centralUuid);
      TransportLog.instance
          .log('BLE: device $centralUuid subscribed to our outbox');
    } else {
      _notifySubscribed.remove(centralUuid);
      final inbound = _inboundPeers.remove(centralUuid);
      if (inbound != null) {
        _inboundByAddress.remove(inbound.address);
        TransportLog.instance.log(
            'BLE: ${_shortAddr(inbound.address)} closed its channel to us');
      }
    }
    _emitPeersIfChanged();
  }

  Future<void> _handleReadRequest(
    GATTCharacteristicReadRequestedEventArgs event,
  ) async {
    final peripheral = _peripheral;
    if (peripheral == null) return;

    if (event.characteristic.uuid != announceCharUuid) {
      await peripheral.respondReadRequestWithError(
        event.request,
        error: GATTError.readNotPermitted,
      );
      return;
    }

    final bytes = _announcementBytes ?? Uint8List(0);
    final offset = event.request.offset;
    if (offset == 0) {
      TransportLog.instance
          .log('BLE: peer ${event.central.uuid} read our announce');
    }
    final value = offset >= bytes.length
        ? Uint8List(0)
        : Uint8List.sublistView(bytes, offset);
    await peripheral.respondReadRequestWithValue(event.request, value: value);
  }

  Future<void> _handleWriteRequest(
    GATTCharacteristicWriteRequestedEventArgs event,
  ) async {
    final peripheral = _peripheral;
    if (peripheral == null) return;

    if (event.characteristic.uuid != inboxCharUuid ||
        event.request.value.isEmpty) {
      await peripheral.respondWriteRequestWithError(
        event.request,
        error: GATTError.writeNotPermitted,
      );
      return;
    }

    final centralUuid = event.central.uuid.toString();
    final flags = event.request.value[0];
    final body = event.request.value.sublist(1);

    final buffer = _inboxBuffers.putIfAbsent(centralUuid, BytesBuilder.new);
    buffer.add(body);

    final isLast = (flags & _finalChunkFlag) != 0;
    if (!isLast) {
      await peripheral.respondWriteRequest(event.request);
      return;
    }

    final payload = buffer.takeBytes();
    _inboxBuffers.remove(centralUuid);

    Map<String, Object?>? packet;
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is Map && decoded['t'] is String) {
        packet = decoded.cast<String, Object?>();
      }
    } catch (_) {
      packet = null;
    }

    if (packet == null) {
      TransportLog.instance.log(
          'BLE: rejected packet from ${event.central.uuid} '
          '(${payload.length} bytes)');
      await peripheral.respondWriteRequestWithError(
        event.request,
        error: GATTError.unlikelyError,
      );
      return;
    }

    // Hello: a signed announce written into our inbox binds this
    // connection to a mesh address, turning the writer into a pushable
    // peer. Consumed at the transport layer — the router never sees it.
    if (packet['t'] == 'announce') {
      final peerIdentity =
          await EnvelopeCodec.verifyBleAnnouncementBytes(payload);
      if (peerIdentity == null || peerIdentity.address == _myAddress) {
        await peripheral.respondWriteRequestWithError(
          event.request,
          error: GATTError.unlikelyError,
        );
        return;
      }
      final isNew = _inboundPeers[centralUuid]?.address != peerIdentity.address;
      _inboundPeers[centralUuid] = _InboundPeer(
        central: event.central,
        address: peerIdentity.address,
        x25519Base64: peerIdentity.x25519Base64,
        lastSeen: DateTime.now(),
      );
      _inboundByAddress[peerIdentity.address] = centralUuid;
      await peripheral.respondWriteRequest(event.request);
      if (isNew) {
        TransportLog.instance.log(
            'BLE: hello from ${_shortAddr(peerIdentity.address)} — '
            'push channel to it is live');
      }
      _emitPeersIfChanged();
      return;
    }

    // Any authenticated traffic from a known inbound peer keeps it fresh.
    final inbound = _inboundPeers[centralUuid];
    if (inbound != null) {
      _inboundPeers[centralUuid] = inbound.touch();
    }

    TransportLog.instance.log(
        'BLE: received ${packet['t']} packet (${payload.length} bytes)');
    // Ack first (success response to the final write), then surface the
    // packet to the router.
    await peripheral.respondWriteRequest(event.request);
    _packets.add(packet);
  }
}

class _BlePeer {
  final Peripheral peripheral;
  final String x25519Base64;
  final DateTime lastSeen;

  const _BlePeer({
    required this.peripheral,
    required this.x25519Base64,
    required this.lastSeen,
  });

  _BlePeer copyWith({Peripheral? peripheral, DateTime? lastSeen}) => _BlePeer(
        peripheral: peripheral ?? this.peripheral,
        x25519Base64: x25519Base64,
        lastSeen: lastSeen ?? this.lastSeen,
      );
}

/// An open push channel we hold as a central: subscribed to the peer's
/// outbox, connection kept alive, inbox characteristic cached for writes.
class _OutboxSubscription {
  final Peripheral peripheral;
  final String address;
  final GATTCharacteristic inboxChar;

  const _OutboxSubscription({
    required this.peripheral,
    required this.address,
    required this.inboxChar,
  });
}

/// A peer that connected to us, subscribed to our outbox, and identified
/// itself with a signed hello — we can push packets to it any time.
class _InboundPeer {
  final Central central;
  final String address;
  final String x25519Base64;
  final DateTime lastSeen;

  const _InboundPeer({
    required this.central,
    required this.address,
    required this.x25519Base64,
    required this.lastSeen,
  });

  _InboundPeer touch() => _InboundPeer(
        central: central,
        address: address,
        x25519Base64: x25519Base64,
        lastSeen: DateTime.now(),
      );
}

MeshTransport createTransport() => _IoBleTransport();
