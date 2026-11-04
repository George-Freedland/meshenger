import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import '../services/identity_service.dart';
import '../services/transport_log.dart';
import 'envelope_codec.dart';
import 'mesh_transport.dart';
import 'packet_frame.dart';

/// Bluetooth LE transport (desktop/mobile).
///
/// GATT layout (every device is simultaneously central and peripheral):
/// - Announce characteristic (read): a signed announcement proving which
///   Ed25519 address + X25519 key this device belongs to.
/// - Inbox characteristic (write): receives packets as chunked writes, each
///   chunk sized to fit one radio packet and prefixed with a 1-byte flag;
///   bit 0 marks the final chunk. Chunks go out as writes without response
///   (many per connection event); only the final chunk waits for a write
///   response, which doubles as the transport-level ack: it only succeeds
///   after the packet parsed. Bulk packets skip even that.
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

  /// How often the scan is checked. While no peer is connected, the first
  /// few checks log what the scan heard, to make discovery diagnosable.
  static const Duration scanCheckInterval = Duration(seconds: 30);

  /// Windows' advertisement watcher can stop without telling the app. A
  /// broad scan hears something within seconds almost anywhere, so one that
  /// has heard nothing for this long is restarted.
  static const Duration silentScanRestartAfter = Duration(seconds: 45);

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

  /// An unacknowledged write normally finishes within a connection event
  /// or two; one stuck this long means the link is gone.
  static const Duration unackedWriteTimeout = Duration(seconds: 8);

  /// Local name advertised by stacks whose GATT server reliably accepts
  /// incoming connections (Apple). Peers dial those right away, and give
  /// unnamed advertisers (Windows, Android) a few seconds to dial them
  /// first: when both sides of a pair dial at once, Windows wedges the
  /// link it is serving.
  static const String reliablePeripheralName = 'MSH';

  /// Wait after a failed connect/identify attempt, doubled per consecutive
  /// failure up to [resolveBackoffMax].
  static const Duration resolveBackoffBase = Duration(seconds: 10);
  static const Duration resolveBackoffMax = Duration(minutes: 2);

  CentralManager? _central;
  PeripheralManager? _peripheral;

  @override
  bool invisible = false;

  bool _running = false;
  String? _myAddress;
  Uint8List? _announcementBytes;

  /// What we write into a peer's inbox to identify ourselves: the signed
  /// announcement, flagged when this device wants to stay hidden.
  Uint8List? _helloBytes;
  String? _startupWarning;

  final Random _random = Random();

  final Map<String, int> _resolveNotBeforeMs = <String, int>{};
  final Map<String, int> _resolveFailures = <String, int>{};
  final Map<String, Timer> _pendingResolves = <String, Timer>{};

  /// When each Meshenger advertiser was last heard (device uuid → ms).
  final Map<String, int> _lastAdvertMs = <String, int>{};
  final Set<String> _reliableAdvertisers = <String>{};

  /// An unidentified central is reading our announce: hold off dialing
  /// unknown devices until it finishes its hello, so the pair doesn't end
  /// up with two links at once.
  int _inboundHandshakeUntilMs = 0;

  @override
  String? get startupWarning => _startupWarning ?? _healthWarning;

  /// Set while the scan hears nothing at all (Windows' broad scan always
  /// hears something when the radio works).
  String? _healthWarning;
  int _silentChecks = 0;

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

  /// Inbound chunk reassembly, keyed by the writing central's UUID.
  final ChunkAssembler _inboxBuffers =
      ChunkAssembler(onDropped: _logDroppedPartial);

  /// Notification reassembly, keyed by the notifying device's UUID.
  final ChunkAssembler _notifyBuffers =
      ChunkAssembler(onDropped: _logDroppedPartial);

  static void _logDroppedPartial(String sender, int bytes) =>
      TransportLog.instance.log('BLE: dropped $bytes bytes of a packet from '
          '$sender that broke off mid-way');

  /// Addresses whose app reads binary frames, from the capabilities in
  /// their announcement or hello.
  final Set<String> _binaryPeers = <String>{};

  /// Pushes to one subscriber run one after another: interleaved
  /// notifications from two packets would corrupt both.
  final Map<String, Future<void>> _pushQueues = <String, Future<void>>{};

  /// File chunks and their bookkeeping; logging each would flush the
  /// connection log within seconds.
  static const Set<String> _quietTypes = {'ftc', 'fta', 'bdat', 'bget'};

  /// Links whose packet size is already in the log ("write:…", "push:…").
  final Set<String> _loggedLinkSizes = <String>{};

  void _logLinkSize(String key, String what, int bytes) {
    if (_loggedLinkSizes.add(key)) {
      TransportLog.instance.log('BLE: $what in $bytes-byte packets');
    }
  }

  final _packets = StreamController<Map<String, Object?>>.broadcast();
  final _peersChanged = StreamController<Set<String>>.broadcast();
  Set<String> _lastEmittedPeers = const <String>{};

  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  Timer? _rescanTimer;
  Timer? _reapTimer;
  Timer? _helloTimer;
  Timer? _scanCheckTimer;
  int _advertsHeard = 0;
  int _meshengerAdvertsHeard = 0;
  int _lastAdvertHeardMs = 0;
  int _scanReportsLeft = 0;

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
  Set<String> get hiddenPeers {
    final now = DateTime.now();
    return <String>{
      for (final entry in _inboundPeers.entries)
        if (entry.value.hidden &&
            _notifySubscribed.contains(entry.key) &&
            now.difference(entry.value.lastSeen) < inboundTimeout &&
            !_peersByAddress.containsKey(entry.value.address))
          entry.value.address,
    };
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
    final announcement =
        _withCapabilities(await EnvelopeCodec.buildBleAnnouncementBytes());
    _announcementBytes = announcement;
    _helloBytes = invisible ? _flagHidden(announcement) : announcement;

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
    if (peripheral != null && !invisible) {
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
          final apple = Platform.isMacOS || Platform.isIOS;
          await peripheral.startAdvertising(
            Advertisement(
              name: apple ? reliablePeripheralName : null,
              serviceUUIDs: [serviceUuid],
            ),
          );
        }
        advertising = true;
      } catch (e) {
        log.log('BLE: peripheral role unavailable ($e)');
      }
    }
    if (invisible) {
      _outboxChar = null;
      _startupWarning = null;
      log.log('BLE: invisible — not advertising; this device can still '
          'discover, send, and receive over channels it opens');
    } else if (advertising) {
      _startupWarning = null;
      log.log('BLE: advertising Meshenger service (announce+inbox+outbox)');
    } else {
      _peripheral = null;
      _outboxChar = null;
      _startupWarning =
          'This device can discover others but is not discoverable itself '
          '(Bluetooth adapter cannot advertise). Nearby devices will still '
          'appear here once this device finds them; for full two-way mesh '
          'participation run the meshenger relay daemon alongside.';
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
    // present, keeping lastSeen fresh. Windows reports every advertisement
    // anyway, and stopping/starting its watcher this often can leave it
    // stopped.
    if (!Platform.isWindows) {
      _rescanTimer = Timer.periodic(rescanInterval, (_) => _restartDiscovery());
    }
    _reapTimer = Timer.periodic(peerTimeout, (_) => _reapStalePeers());
    _helloTimer = Timer.periodic(helloInterval, (_) => _sendHellos());
    _lastAdvertHeardMs = DateTime.now().millisecondsSinceEpoch;
    _scanReportsLeft = 10;
    _scanCheckTimer = Timer.periodic(scanCheckInterval, (_) => _checkScan());

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
    _scanCheckTimer?.cancel();
    _scanCheckTimer = null;
    for (final timer in _pendingResolves.values) {
      timer.cancel();
    }
    _pendingResolves.clear();

    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    // Close push channels we hold as a central.
    final central = _central;
    if (central != null) {
      for (final sub in _outSubs.values.toList()) {
        await _safeDisconnect(central, sub.peripheral);
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
    _resolveNotBeforeMs.clear();
    _resolveFailures.clear();
    _lastAdvertMs.clear();
    _reliableAdvertisers.clear();
    _inboundHandshakeUntilMs = 0;
    _inboxBuffers.clear();
    _notifyBuffers.clear();
    _binaryPeers.clear();
    _pushQueues.clear();
    _healthWarning = null;
    _silentChecks = 0;
    _loggedLinkSizes.clear();
    _inboundPeers.clear();
    _inboundByAddress.clear();
    _notifySubscribed.clear();
    _outboxChar = null;
    _startupWarning = null;
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
      throw StateError('This device does not support Bluetooth LE.');
    }
    try {
      await manager.stateChanged
          .firstWhere((e) => e.state == BluetoothLowEnergyState.poweredOn)
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      throw StateError(_unavailableMessage(manager.state));
    }
  }

  /// Turns a stuck Bluetooth state into instructions the user can act on.
  static String _unavailableMessage(BluetoothLowEnergyState state) {
    switch (state) {
      case BluetoothLowEnergyState.unauthorized:
        if (Platform.isMacOS) {
          return 'Bluetooth permission denied. Open System Settings → '
              'Privacy & Security → Bluetooth, allow Meshenger, then retry.';
        }
        if (Platform.isIOS) {
          return 'Bluetooth permission denied. Open Settings → Privacy & '
              'Security → Bluetooth, allow Meshenger, then retry.';
        }
        if (Platform.isAndroid) {
          return 'Bluetooth permission denied. Grant the "Nearby devices" '
              'permission in system settings, then retry.';
        }
        return 'Bluetooth permission denied. Grant Bluetooth access to '
            'this app, then retry.';
      case BluetoothLowEnergyState.poweredOff:
        return 'Bluetooth is turned off. Turn it on and retry.';
      default:
        return 'Bluetooth is not available (state: ${state.name}). '
            'Make sure Bluetooth is turned on, then retry.';
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
    _advertsHeard++;
    _lastAdvertHeardMs = DateTime.now().millisecondsSinceEpoch;
    final name = event.advertisement.name;
    // On non-Windows platforms the native scan filter already guarantees
    // this is a Meshenger device (and the callback may omit the UUID list).
    // Windows reports a Mac's advertisement and scan response as separate
    // events, and the name and service UUID may be split across them.
    final advertisesMeshenger = !Platform.isWindows ||
        event.advertisement.serviceUUIDs.contains(serviceUuid) ||
        name == reliablePeripheralName;

    if (advertisesMeshenger) {
      _meshengerAdvertsHeard++;
      _lastAdvertMs[deviceUuid] = DateTime.now().millisecondsSinceEpoch;
      if (name == reliablePeripheralName) _reliableAdvertisers.add(deviceUuid);
      if (_loggedDevices.add(deviceUuid)) {
        TransportLog.instance.log(
          'BLE: discovered Meshenger device $deviceUuid'
          '${name != null && name.isNotEmpty ? ' "$name"' : ''}',
        );
      }
    }

    final knownAddress = _addressByDeviceUuid[deviceUuid];
    if (knownAddress != null) {
      final peer = _peersByAddress[knownAddress];
      if (peer != null) {
        _peersByAddress[knownAddress] =
            peer.copyWith(peripheral: event.peripheral, lastSeen: DateTime.now());
        _emitPeersIfChanged();
        // Known peer without a push channel either way: retry subscribing
        // now and then (it may have gained an outbox, or a previous attempt
        // failed). If it holds a channel to us, one link is enough.
        if (!_outSubs.containsKey(deviceUuid) &&
            _outSubs.length < maxSubscriptions &&
            !_hasInboundChannel(knownAddress)) {
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

  /// Queues a resolve (connect + announce + subscribe) for a device: first
  /// dials are jittered, failures back off exponentially, and identified
  /// devices are re-dialed at most every 30 seconds.
  void _scheduleResolve(Peripheral device) {
    final deviceUuid = device.uuid.toString();
    if (_resolving.contains(deviceUuid) ||
        _pendingResolves.containsKey(deviceUuid)) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < (_resolveNotBeforeMs[deviceUuid] ?? 0)) return;
    final known = _addressByDeviceUuid.containsKey(deviceUuid);
    final last = _lastResolveAttemptMs[deviceUuid];
    if (known && last != null && now - last < 30000) return;
    if (!known && now < _inboundHandshakeUntilMs) return;

    if (last != null) {
      _startResolve(device);
      return;
    }
    _pendingResolves[deviceUuid] = Timer(_firstDialDelay(deviceUuid), () {
      _pendingResolves.remove(deviceUuid);
      if (!_running) return;
      final unknown = !_addressByDeviceUuid.containsKey(deviceUuid);
      // Someone is mid-handshake with us; the next sighting retries.
      if (unknown &&
          DateTime.now().millisecondsSinceEpoch < _inboundHandshakeUntilMs) {
        return;
      }
      if (unknown && _unidentifiedAdvertisersAreInbound()) {
        // Whoever we'd be dialing most likely just dialed us and is already
        // connected; a second link to the same peer only destabilizes it.
        _resolveNotBeforeMs[deviceUuid] =
            DateTime.now().millisecondsSinceEpoch + 45000;
        TransportLog.instance.log('BLE: $deviceUuid is likely a peer already '
            'connected to us — not opening a second link');
        return;
      }
      _startResolve(device);
    });
  }

  void _startResolve(Peripheral device) {
    final deviceUuid = device.uuid.toString();
    _lastResolveAttemptMs[deviceUuid] = DateTime.now().millisecondsSinceEpoch;
    _resolving.add(deviceUuid);
    _enqueueGatt(() => _resolvePeer(device)).whenComplete(() {
      _resolving.remove(deviceUuid);
    });
  }

  Duration _firstDialDelay(String deviceUuid) {
    final waitForThem =
        _outboxChar != null && !_reliableAdvertisers.contains(deviceUuid);
    // Windows needs several seconds to finish dialing a Mac (uncached
    // service discovery, announce, subscribe, hello).
    return waitForThem
        ? Duration(milliseconds: 6000 + _random.nextInt(4000))
        : Duration(milliseconds: 250 + _random.nextInt(1250));
  }

  /// True when every Meshenger advertiser we hear but haven't identified
  /// can be matched to a peer that connected to us and said hello.
  bool _unidentifiedAdvertisersAreInbound() {
    final now = DateTime.now();
    final unidentified = _lastAdvertMs.entries
        .where((e) =>
            now.millisecondsSinceEpoch - e.value < peerTimeout.inMilliseconds &&
            !_addressByDeviceUuid.containsKey(e.key))
        .length;
    if (unidentified == 0) return false;
    final inboundOnly = _inboundPeers.entries
        .where((e) =>
            _notifySubscribed.contains(e.key) &&
            now.difference(e.value.lastSeen) < inboundTimeout &&
            !_peersByAddress.containsKey(e.value.address))
        .length;
    return inboundOnly >= unidentified;
  }

  bool _hasInboundChannel(String address) {
    final centralUuid = _inboundByAddress[address];
    if (centralUuid == null || !_notifySubscribed.contains(centralUuid)) {
      return false;
    }
    final inbound = _inboundPeers[centralUuid];
    return inbound != null &&
        DateTime.now().difference(inbound.lastSeen) < inboundTimeout;
  }

  void _noteResolveResult(String deviceUuid, {required bool identified}) {
    if (identified) {
      _resolveFailures.remove(deviceUuid);
      _resolveNotBeforeMs.remove(deviceUuid);
      return;
    }
    final failures = (_resolveFailures[deviceUuid] ?? 0) + 1;
    _resolveFailures[deviceUuid] = failures;
    final backoffMs = min(
      resolveBackoffBase.inMilliseconds * (1 << min(failures - 1, 5)),
      resolveBackoffMax.inMilliseconds,
    );
    _resolveNotBeforeMs[deviceUuid] = DateTime.now().millisecondsSinceEpoch +
        backoffMs +
        _random.nextInt(2000);
  }

  Future<void> _safeDisconnect(
      CentralManager central, Peripheral device) async {
    try {
      await central.disconnect(device).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// A copy of [announcement] carrying the "keep me off your map" flag.
  /// The flag sits outside the signed fields, so anyone could set it — it
  /// only ever hides the sender.
  static Uint8List _flagHidden(Uint8List announcement) {
    final decoded = jsonDecode(utf8.decode(announcement)) as Map;
    return Uint8List.fromList(
      utf8.encode(jsonEncode(<String, Object?>{
        ...decoded.cast<String, Object?>(),
        'inv': true,
      })),
    );
  }

  /// [announcement] plus what this app understands on the wire. Unsigned
  /// like `inv`: a forged capability only garbles packets sent to the forger.
  static Uint8List _withCapabilities(Uint8List announcement) {
    final decoded = jsonDecode(utf8.decode(announcement)) as Map;
    return Uint8List.fromList(
      utf8.encode(jsonEncode(<String, Object?>{
        ...decoded.cast<String, Object?>(),
        'caps': const [PacketFrame.binaryCapability],
      })),
    );
  }

  void _noteCapabilities(String address, Object? announcement) {
    final caps = announcement is Map ? announcement['caps'] : null;
    if (caps is List && caps.contains(PacketFrame.binaryCapability)) {
      _binaryPeers.add(address);
    } else {
      _binaryPeers.remove(address);
    }
  }

  Uint8List _encodeFor(String peerAddress, Map<String, Object?> packet) =>
      _binaryPeers.contains(peerAddress)
          ? PacketFrame.encodeBinary(packet)
          : PacketFrame.encodeJson(packet);

  /// Android starts every link at 23 bytes per packet (20 of payload) and
  /// only goes bigger when asked; the other platforms negotiate on their own.
  Future<void> _requestLargePackets(
      CentralManager central, Peripheral device) async {
    if (!Platform.isAndroid) return;
    try {
      await central
          .requestMTU(device, mtu: 517)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Older stacks refuse; the link just stays slower.
    }
  }

  /// Connects to a Meshenger device, reads and verifies its signed
  /// announcement, records the peer, and — when the device serves an
  /// outbox — subscribes to it and keeps the connection open as a push
  /// channel.
  Future<void> _resolvePeer(Peripheral device) async {
    final central = _central;
    final log = TransportLog.instance;
    if (central == null || !_running) return;
    final deviceUuid = device.uuid.toString();
    var step = 'connect';
    var keepOpen = false;
    var identified = false;
    try {
      await central.connect(device).timeout(gattTimeout);
      await _requestLargePackets(central, device);
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
      identified = true;
      try {
        _noteCapabilities(peerIdentity.address, jsonDecode(utf8.decode(bytes)));
      } catch (_) {}

      _addressByDeviceUuid[deviceUuid] = peerIdentity.address;
      _peersByAddress[peerIdentity.address] = _BlePeer(
        peripheral: device,
        x25519Base64: peerIdentity.x25519Base64,
        lastSeen: DateTime.now(),
      );
      log.log('BLE: peer online ${_shortAddr(peerIdentity.address)} '
          '(device ${device.uuid})');
      _emitPeersIfChanged();

      if (_hasInboundChannel(peerIdentity.address)) {
        log.log('BLE: ${_shortAddr(peerIdentity.address)} already holds a '
            'channel to us — not opening a second one');
        return;
      }

      // Push channel: subscribe to the peer's outbox and identify ourselves
      // so it can push packets to us — even while our app is backgrounded.
      final outboxChar = _findCharacteristic(services, outboxCharUuid);
      final inboxChar = _findCharacteristic(services, inboxCharUuid);
      final hello = _helloBytes;
      if (outboxChar != null &&
          inboxChar != null &&
          hello != null &&
          !_outSubs.containsKey(deviceUuid) &&
          _outSubs.length < maxSubscriptions) {
        step = 'subscribe outbox';
        var subscribed = false;
        try {
          await central
              .setCharacteristicNotifyState(device, outboxChar, state: true)
              .timeout(gattTimeout);
          subscribed = true;
        } catch (e) {
          log.log('BLE: subscribing to ${_shortAddr(peerIdentity.address)}\'s '
              'outbox failed: $e');
        }
        // Say hello either way: it is how the peer learns who we are.
        step = 'hello';
        await _writeChunks(central, device, inboxChar, hello);
        if (subscribed) {
          _outSubs[deviceUuid] = _OutboxSubscription(
            peripheral: device,
            address: peerIdentity.address,
            inboxChar: inboxChar,
          );
          keepOpen = true;
          log.log('BLE: push channel open with '
              '${_shortAddr(peerIdentity.address)} (subscribed to outbox)');
        }
      }
    } catch (e) {
      // Device went away or isn't a functioning Meshenger node.
      log.log('BLE: resolve ${device.uuid} failed at $step: $e');
    } finally {
      _noteResolveResult(deviceUuid, identified: identified);
      if (!keepOpen) await _safeDisconnect(central, device);
    }
  }

  static String _shortAddr(String address) =>
      address.length <= 12 ? address : '${address.substring(0, 12)}…';

  void _checkScan() {
    if (!_running) return;
    final heard = _advertsHeard;
    final meshenger = _meshengerAdvertsHeard;
    _advertsHeard = 0;
    _meshengerAdvertsHeard = 0;
    if (_lastEmittedPeers.isEmpty && _scanReportsLeft > 0) {
      _scanReportsLeft--;
      final window = '${scanCheckInterval.inSeconds} s';
      TransportLog.instance.log(Platform.isWindows
          ? 'BLE: scan heard $heard advertisement${heard == 1 ? '' : 's'} '
              'in $window, $meshenger from Meshenger devices'
          : 'BLE: scan heard $meshenger Meshenger '
              'advertisement${meshenger == 1 ? '' : 's'} in $window');
    }
    // Only Windows scans broadly; a filtered scan is silent whenever no
    // Meshenger device is around.
    if (!Platform.isWindows) return;
    _silentChecks = heard == 0 ? _silentChecks + 1 : 0;
    if (_silentChecks >= 3 && _healthWarning == null) {
      _healthWarning = "This PC's Bluetooth isn't hearing any devices. "
          'Meshenger keeps restarting the scan; if this lasts, tap Retry, '
          'then quit and reopen Meshenger, and if that fails restart the PC.';
      TransportLog.instance.log('BLE: nothing heard for '
          '${_silentChecks * scanCheckInterval.inSeconds} s despite restarts '
          '— showing the user how to recover');
    } else if (_silentChecks == 0 && _healthWarning != null) {
      _healthWarning = null;
      TransportLog.instance.log('BLE: hearing devices again');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final silentMs = now - _lastAdvertHeardMs;
    if (silentMs < silentScanRestartAfter.inMilliseconds) return;
    TransportLog.instance.log(
        'BLE: scan has heard nothing for ${silentMs ~/ 1000} s, restarting it');
    _lastAdvertHeardMs = now;
    unawaited(_restartDiscovery());
  }

  Future<void> _restartDiscovery() async {
    final central = _central;
    if (central == null || !_running) return;
    try {
      await central.stopDiscovery();
      // The Windows watcher stops asynchronously; starting it again before
      // it has settled fails.
      if (Platform.isWindows) {
        await Future<void>.delayed(const Duration(milliseconds: 750));
      }
      await _startDiscovery(central);
    } catch (e) {
      // Bluetooth may have turned off; the reap timer will clear peers.
      TransportLog.instance.log('BLE: restart discovery failed: $e');
    }
  }

  @override
  Future<void> rescan() async {
    if (!_running) return;
    TransportLog.instance.log('BLE: rescanning surroundings');
    _scanReportsLeft = 10;
    for (final timer in _pendingResolves.values) {
      timer.cancel();
    }
    _pendingResolves.clear();
    _resolveNotBeforeMs.clear();
    _resolveFailures.clear();
    _lastResolveAttemptMs.clear();
    _loggedDevices.clear();
    _inboundHandshakeUntilMs = 0;
    await _restartDiscovery();
    unawaited(_sendHellos());
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

    // Advertisers rotate their addresses; forget the ones gone quiet.
    final nowMs = now.millisecondsSinceEpoch;
    final silent = _lastAdvertMs.entries
        .where(
            (e) => nowMs - e.value > const Duration(minutes: 10).inMilliseconds)
        .map((e) => e.key)
        .toList();
    for (final deviceUuid in silent) {
      _lastAdvertMs.remove(deviceUuid);
      _reliableAdvertisers.remove(deviceUuid);
      _resolveFailures.remove(deviceUuid);
      _resolveNotBeforeMs.remove(deviceUuid);
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
    _notifyBuffers.forget(deviceUuid);
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
    _notifyBuffers.forget(deviceUuid);
    TransportLog.instance
        .log('BLE: push channel to ${_shortAddr(sub.address)} closed');
    final central = _central;
    if (central != null) {
      // Queued, so the next connect to this device finds it torn down
      // rather than half-way through.
      unawaited(_enqueueGatt(() => _safeDisconnect(central, sub.peripheral)));
    }
  }

  /// Periodic hello over every open push channel: keeps our entry fresh on
  /// the peer's side and doubles as a liveness probe.
  Future<void> _sendHellos() async {
    final central = _central;
    final hello = _helloBytes;
    if (central == null || hello == null || !_running) return;
    for (final entry in _outSubs.entries.toList()) {
      await _enqueueGatt(() async {
        final sub = _outSubs[entry.key];
        if (sub == null) return;
        try {
          await _writeChunks(central, sub.peripheral, sub.inboxChar, hello);
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

    final payload = _notifyBuffers.add(deviceUuid, event.value);
    if (payload == null) return;

    // A dropped chunk corrupts the reassembly (decode gives null); the
    // mesh's retry loops re-deliver.
    final packet = PacketFrame.decode(payload);
    if (packet == null) return;
    if (!_quietTypes.contains(packet['t'])) {
      TransportLog.instance.log('BLE: received ${packet['t']} pushed over '
          'outbox (${payload.length} bytes)');
    }
    final address = _addressByDeviceUuid[deviceUuid];
    if (address != null) _touchPeer(address);
    _packets.add(packet);
  }

  // -----------------------------------------------------------------------
  // Sending
  // -----------------------------------------------------------------------

  @override
  Future<bool> sendPacket(
    String peerAddress,
    Map<String, Object?> packet, {
    bool bulk = false,
  }) async {
    if (!_running) return false;
    final central = _central;
    final payload = _encodeFor(peerAddress, packet);
    final quiet = bulk || _quietTypes.contains(packet['t']);
    // Older builds get every chunk acknowledged, as before: their Windows
    // plugin could reorder a burst of unacknowledged writes.
    final current = _binaryPeers.contains(peerAddress);

    // 1. A push channel to this peer is open: write over the live
    //    connection, no connect/discover round trips.
    // 2. Otherwise a scan-resolved peer: connect, write, disconnect.
    // Decided once the GATT queue gets to this packet: a channel that
    // opened while it waited (the peer was just being resolved) is used,
    // rather than discovering the same device again under it.
    if (central != null &&
        (_subByAddress(peerAddress) != null ||
            _peersByAddress.containsKey(peerAddress))) {
      var delivered = false;
      await _enqueueGatt(() async {
        final sub = _subByAddress(peerAddress);
        if (sub != null) {
          try {
            await _writeChunks(central, sub.peripheral, sub.inboxChar, payload,
                unacked: current, confirmLast: !bulk);
            delivered = true;
            if (!quiet) {
              TransportLog.instance.log(
                  'BLE: delivered ${payload.length} bytes to '
                  '${_shortAddr(peerAddress)} (live channel)');
            }
          } catch (e) {
            TransportLog.instance.log(
                'BLE: live-channel write to ${_shortAddr(peerAddress)} '
                'failed: $e');
            _dropSubscription(sub.peripheral.uuid.toString());
          }
          // Right after a failure the link is still being torn down;
          // dialing it again now would race that.
          return;
        }
        final peer = _peersByAddress[peerAddress];
        if (peer == null) return;
        delivered = await _deliverPayload(peer.peripheral, payload,
            unacked: current, confirmLast: !bulk);
      });
      if (delivered) {
        _touchPeer(peerAddress);
        return true;
      }
    }

    // 3. Push: the peer holds a channel to us (it subscribed to our
    //    outbox) — notify it, chunk by chunk. This is how a router
    //    initiates delivery to a device it cannot scan.
    return _pushToInbound(peerAddress, payload, quiet: quiet);
  }

  Future<bool> _deliverPayload(
    Peripheral device,
    List<int> payload, {
    bool unacked = false,
    bool confirmLast = true,
  }) async {
    final central = _central;
    final log = TransportLog.instance;
    if (central == null) return false;
    var step = 'connect';
    try {
      await central.connect(device).timeout(gattTimeout);
      await _requestLargePackets(central, device);
      step = 'discoverGATT';
      final services = await central.discoverGATT(device).timeout(gattTimeout);
      final inboxChar = _findCharacteristic(services, inboxCharUuid);
      if (inboxChar == null) {
        log.log('BLE: deliver to ${device.uuid}: inbox characteristic missing');
        return false;
      }
      step = 'write';
      await _writeChunks(central, device, inboxChar, payload,
          unacked: unacked, confirmLast: confirmLast);
      log.log('BLE: delivered ${payload.length} bytes to ${device.uuid}');
      return true;
    } catch (e) {
      log.log('BLE: deliver to ${device.uuid} failed at $step: $e');
      return false;
    } finally {
      // Never tear down a live push channel.
      if (!_outSubs.containsKey(device.uuid.toString())) {
        await _safeDisconnect(central, device);
      }
    }
  }

  /// Writes [payload] into [characteristic] as flag-framed chunks, each
  /// sized to one radio packet (bigger writes make the OS split them into
  /// several acknowledged long-write steps). [unacked] chunks go out
  /// without response, so the stack packs many into each connection event
  /// and only slows us down when its queue is full; the final chunk's
  /// write response is the transport-level ack unless [confirmLast] is off.
  Future<void> _writeChunks(
    CentralManager central,
    Peripheral device,
    GATTCharacteristic characteristic,
    List<int> payload, {
    bool unacked = false,
    bool confirmLast = true,
  }) async {
    unacked = unacked &&
        characteristic.properties
            .contains(GATTCharacteristicProperty.writeWithoutResponse);
    final maxWriteLength = await central
        .getMaximumWriteLength(
          device,
          type: GATTCharacteristicWriteType.withoutResponse,
        )
        .timeout(gattTimeout);
    // 1 byte reserved for the chunk flag.
    final chunkSize = (maxWriteLength - 1).clamp(19, 511);
    if (payload.length > chunkSize) {
      final who = _addressByDeviceUuid[device.uuid.toString()];
      _logLinkSize(
        'write:${device.uuid}',
        'writing to ${who == null ? device.uuid : _shortAddr(who)}'
            '${unacked ? '' : ' (acknowledged, older app)'}',
        chunkSize + 1,
      );
    }

    for (var offset = 0; offset < payload.length; offset += chunkSize) {
      final end = (offset + chunkSize < payload.length)
          ? offset + chunkSize
          : payload.length;
      final chunk = Uint8List(end - offset + 1);
      chunk[0] = ChunkFlags.of(offset, end, payload.length);
      chunk.setRange(1, chunk.length, payload, offset);
      final withoutResponse =
          unacked && !(end == payload.length && confirmLast);

      await central
          .writeCharacteristic(
            device,
            characteristic,
            value: chunk,
            type: withoutResponse
                ? GATTCharacteristicWriteType.withoutResponse
                : GATTCharacteristicWriteType.withResponse,
          )
          .timeout(withoutResponse ? unackedWriteTimeout : gattTimeout);
    }
  }


  /// Pushes a packet to a peer that subscribed to our outbox, as chunked
  /// notifications. No per-chunk ack exists at this layer — end-to-end
  /// encrypted acks confirm real delivery.
  Future<bool> _pushToInbound(
    String peerAddress,
    List<int> payload, {
    bool quiet = false,
  }) {
    final centralUuid = _inboundByAddress[peerAddress];
    if (centralUuid == null) return Future<bool>.value(false);
    final previous = _pushQueues[centralUuid] ?? Future<void>.value();
    final result = previous.then(
        (_) => _pushNow(peerAddress, centralUuid, payload, quiet: quiet));
    _pushQueues[centralUuid] = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _pushNow(
    String peerAddress,
    String centralUuid,
    List<int> payload, {
    required bool quiet,
  }) async {
    final peripheral = _peripheral;
    final outbox = _outboxChar;
    if (peripheral == null || outbox == null) return false;
    if (!_notifySubscribed.contains(centralUuid)) return false;
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
      if (payload.length > chunkSize) {
        _logLinkSize('push:$centralUuid', 'pushing to ${_shortAddr(peerAddress)}',
            chunkSize + 1);
      }

      for (var offset = 0; offset < payload.length; offset += chunkSize) {
        final end = (offset + chunkSize < payload.length)
            ? offset + chunkSize
            : payload.length;
        final chunk = Uint8List(end - offset + 1);
        chunk[0] = ChunkFlags.of(offset, end, payload.length);
        chunk.setRange(1, chunk.length, payload, offset);
        await peripheral
            .notifyCharacteristic(inbound.central, outbox, value: chunk)
            .timeout(gattTimeout);
      }
      if (!quiet) {
        TransportLog.instance.log(
            'BLE: pushed ${payload.length} bytes to '
            '${_shortAddr(peerAddress)} over our outbox');
      }
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
  ///
  /// A request that goes unanswered holds the asking device's whole link
  /// until it times out, so a failure still gets an (error) answer.
  void _scheduleReadRequest(GATTCharacteristicReadRequestedEventArgs event) {
    unawaited(Future<void>(() async {
      try {
        await _handleReadRequest(event);
      } catch (e) {
        TransportLog.instance
            .log('BLE: read from ${event.central.uuid} failed: $e');
        try {
          await _peripheral?.respondReadRequestWithError(event.request,
              error: GATTError.unlikelyError);
        } catch (_) {}
      }
    }));
  }

  void _scheduleWriteRequest(GATTCharacteristicWriteRequestedEventArgs event) {
    unawaited(Future<void>(() async {
      try {
        await _handleWriteRequest(event);
      } catch (e) {
        TransportLog.instance
            .log('BLE: write from ${event.central.uuid} failed: $e');
        try {
          await _peripheral?.respondWriteRequestWithError(event.request,
              error: GATTError.unlikelyError);
        } catch (_) {}
      }
    }));
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
      _inboxBuffers.forget(centralUuid);
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
      if (!_inboundPeers.containsKey(event.central.uuid.toString())) {
        _inboundHandshakeUntilMs = DateTime.now().millisecondsSinceEpoch + 8000;
      }
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
    final payload =
        _inboxBuffers.add(centralUuid, event.request.value);
    if (payload == null) {
      await _acceptWrite(peripheral, event.request);
      return;
    }

    final packet = PacketFrame.decode(payload);
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
      final hidden = packet['inv'] == true;
      _inboundPeers[centralUuid] = _InboundPeer(
        central: event.central,
        address: peerIdentity.address,
        x25519Base64: peerIdentity.x25519Base64,
        lastSeen: DateTime.now(),
        hidden: hidden,
      );
      _inboundByAddress[peerIdentity.address] = centralUuid;
      _noteCapabilities(peerIdentity.address, packet);
      _inboundHandshakeUntilMs = 0;
      await _acceptWrite(peripheral, event.request);
      if (isNew) {
        TransportLog.instance
            .log('BLE: hello from ${_shortAddr(peerIdentity.address)}'
                '${hidden ? ' (invisible)' : ''} — push channel to it is live');
      }
      _emitPeersIfChanged();
      return;
    }

    // Any authenticated traffic from a known inbound peer keeps it fresh.
    final inbound = _inboundPeers[centralUuid];
    if (inbound != null) {
      _inboundPeers[centralUuid] = inbound.touch();
    }

    if (!_quietTypes.contains(packet['t'])) {
      TransportLog.instance.log(
          'BLE: received ${packet['t']} packet (${payload.length} bytes)');
    }
    // Ack first (success response to the final write), then surface the
    // packet to the router.
    await _acceptWrite(peripheral, event.request);
    _packets.add(packet);
  }

  /// Answers a write. The plugins can't say whether one came without
  /// response (nothing to answer), so this answers every write and lets a
  /// stack that has nothing to answer refuse quietly.
  Future<void> _acceptWrite(
    PeripheralManager peripheral,
    GATTWriteRequest request,
  ) async {
    try {
      await peripheral.respondWriteRequest(request);
    } catch (_) {}
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

  /// The peer is in invisible mode: deliver to it, but don't show it.
  final bool hidden;

  const _InboundPeer({
    required this.central,
    required this.address,
    required this.x25519Base64,
    required this.lastSeen,
    this.hidden = false,
  });

  _InboundPeer touch() => _InboundPeer(
        central: central,
        address: address,
        x25519Base64: x25519Base64,
        lastSeen: DateTime.now(),
        hidden: hidden,
      );
}

MeshTransport createTransport() => _IoBleTransport();
