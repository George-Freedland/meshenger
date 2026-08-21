import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';

import 'identity.dart';
import 'transport.dart';

/// Bluetooth LE link via BlueZ (Linux / Raspberry Pi).
///
/// Speaks the exact GATT protocol of the Meshenger app:
/// - advertises the Meshenger service and serves a signed announce
///   characteristic (read) plus an inbox characteristic (chunked writes,
///   1-byte flag prefix, bit 0 = final chunk; the final write's response
///   is the transport-level ack),
/// - serves an outbox characteristic (notify): phones subscribe to it and
///   the relay *pushes* packets to them as chunked notifications — this is
///   how a gateway initiates delivery to a phone it cannot scan (e.g. a
///   backgrounded iPhone). Subscribers identify themselves by writing a
///   signed announce ("hello") into the inbox,
/// - scans for other Meshenger devices, verifies their announcements, and
///   delivers packets as chunked writes into *their* inbox.
///
/// Runs as central and peripheral simultaneously, which the Pi's chipset
/// (and any modern BlueZ stack) supports.
class BleTransport implements RelayTransport {
  static const String serviceUuid = '4d455348-454e-4745-5242-4c4530303031';
  static const String announceCharUuid =
      '4d455348-454e-4745-5242-4c4530303032';
  static const String inboxCharUuid = '4d455348-454e-4745-5242-4c4530303033';
  static const String outboxCharUuid = '4d455348-454e-4745-5242-4c4530303034';

  static const Duration peerTimeout = Duration(seconds: 40);

  /// Subscribers are dropped after this long without a write (the app
  /// hellos every 20 s over open channels).
  static const Duration inboundTimeout = Duration(seconds: 65);

  static const Duration gattTimeout = Duration(seconds: 15);
  static const int _finalChunkFlag = 0x01;

  /// Notification payload budget. BlueZ truncates notifications to the
  /// link's MTU-3; phones negotiate ≥185 automatically, so 180 is safe on
  /// anything modern.
  static const int _notifyChunkSize = 180;

  final RelayIdentity identity;
  final String localName;
  final int adapterIndex;
  final void Function(String) log;

  BleTransport({
    required this.identity,
    required this.localName,
    required this.log,
    this.adapterIndex = 0,
  });

  DBusClient? _bus;
  BlueZClient? _client;
  BlueZAdapter? _adapter;
  BlueZAdvertisement? _advertisement;
  _GattApplication? _application;
  _OutboxCharacteristic? _outbox;
  DBusObjectPath? _adapterPath;
  Uint8List _announcementBytes = Uint8List(0);

  final Map<String, _BlePeer> _peersByAddress = <String, _BlePeer>{};
  final Map<String, String> _addressByDevicePath = <String, String>{};
  final Set<String> _resolving = <String>{};
  final Set<String> _watchedDevicePaths = <String>{};

  /// Push subscribers: devices that subscribed to our outbox and identified
  /// themselves with a signed hello (device path → peer).
  final Map<String, _InboundBlePeer> _inboundPeers =
      <String, _InboundBlePeer>{};

  /// Fan-out dedup: notifications reach every subscriber, so pushing the
  /// same packet once per addressed peer would duplicate it on air.
  final Map<String, int> _recentPushes = <String, int>{};

  final _packets = StreamController<Map<String, Object?>>.broadcast();
  final _peersChanged = StreamController<Set<String>>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _reapTimer;

  /// BLE stacks misbehave when several GATT operations run concurrently;
  /// serialize connect/resolve/write sequences.
  Future<void> _gattQueue = Future<void>.value();

  @override
  String get name => 'ble';

  @override
  Set<String> get onlinePeers {
    final now = DateTime.now();
    final result = <String>{};
    for (final entry in _peersByAddress.entries) {
      if (now.difference(entry.value.lastSeen) < peerTimeout) {
        result.add(entry.key);
      }
    }
    // Subscribers we can push to count as reachable even when they can't
    // be scanned (backgrounded iPhones connected to this gateway).
    if (_outbox?.notifying ?? false) {
      for (final peer in _inboundPeers.values) {
        if (now.difference(peer.lastSeen) < inboundTimeout) {
          result.add(peer.address);
        }
      }
    }
    return result;
  }

  @override
  Stream<Map<String, Object?>> get onPacket => _packets.stream;

  @override
  Stream<Set<String>> get onPeersChanged => _peersChanged.stream;

  // ---------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------

  @override
  Future<void> start() async {
    _announcementBytes = await identity.bleAnnouncementBytes();

    final bus = _bus = DBusClient.system();
    final client = _client = BlueZClient(bus: bus);
    await client.connect();

    if (client.adapters.isEmpty) {
      throw StateError(
        'No Bluetooth adapter found. Is the bluetooth service running? '
        '(systemctl status bluetooth)',
      );
    }
    if (adapterIndex >= client.adapters.length) {
      throw StateError(
        'Adapter index $adapterIndex not found '
        '(${client.adapters.length} adapter(s) present).',
      );
    }
    final adapter = _adapter = client.adapters[adapterIndex];

    try {
      if (!adapter.powered) {
        await adapter.setPowered(true);
      }
    } catch (e) {
      throw StateError(
        'Could not power on Bluetooth adapter: $e\n'
        'Try: sudo rfkill unblock bluetooth',
      );
    }

    _adapterPath = await _findAdapterPath(bus, adapter.address);

    // --- Peripheral role: GATT server + advertising ---
    await _registerGattApplication(bus);
    _advertisement = await adapter.advertisingManager.registerAdvertisement(
      type: BlueZAdvertisementType.peripheral,
      serviceUuids: [serviceUuid],
      localName: localName,
    );
    log('BLE: advertising Meshenger service as "$localName"');

    // --- Central role: discovery ---
    for (final device in client.devices) {
      _watchDevice(device);
    }
    _subs.add(client.deviceAdded.listen(_onDeviceAdded));
    _subs.add(client.deviceRemoved.listen(_onDeviceRemoved));

    try {
      await adapter.setDiscoveryFilter(
        uuids: [serviceUuid],
        transport: 'le',
        duplicateData: true,
      );
    } catch (_) {
      // Filter is an optimization; broad discovery still works.
    }
    try {
      await adapter.startDiscovery();
    } on BlueZException catch (e) {
      // "InProgress" just means another process already scans; fine.
      if (!e.toString().contains('InProgress')) rethrow;
    }
    log('BLE: scanning for Meshenger devices');

    _reapTimer = Timer.periodic(peerTimeout, (_) => _reapStalePeers());
  }

  @override
  Future<void> stop() async {
    _reapTimer?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    try {
      await _adapter?.stopDiscovery();
    } catch (_) {}
    final advertisement = _advertisement;
    if (advertisement != null) {
      try {
        await _adapter?.advertisingManager
            .unregisterAdvertisement(advertisement);
      } catch (_) {}
    }
    await _unregisterGattApplication();
    await _client?.close();
    _peersByAddress.clear();
    _addressByDevicePath.clear();
  }

  // ---------------------------------------------------------------------
  // GATT server (peripheral role)
  // ---------------------------------------------------------------------

  Future<void> _registerGattApplication(DBusClient bus) async {
    final appPath = DBusObjectPath('/com/meshenger/gatt');
    final servicePath = DBusObjectPath('/com/meshenger/gatt/service0');

    final application = _application = _GattApplication(appPath);
    final service = _GattService(servicePath, serviceUuid);
    final announce = _AnnounceCharacteristic(
      DBusObjectPath('/com/meshenger/gatt/service0/char0'),
      servicePath: servicePath,
      uuid: announceCharUuid,
      bytes: () => _announcementBytes,
    );
    final inbox = _InboxCharacteristic(
      DBusObjectPath('/com/meshenger/gatt/service0/char1'),
      servicePath: servicePath,
      uuid: inboxCharUuid,
      onInboundPacket: _handleInboundPacket,
      log: log,
    );
    final outbox = _outbox = _OutboxCharacteristic(
      DBusObjectPath('/com/meshenger/gatt/service0/char2'),
      servicePath: servicePath,
      uuid: outboxCharUuid,
      onNotifyingChanged: (notifying) {
        log(notifying
            ? 'BLE: a device subscribed to our outbox (push channel live)'
            : 'BLE: last outbox subscriber left');
        _peersChanged.add(onlinePeers);
      },
    );
    application.children.addAll([service, announce, inbox, outbox]);

    await bus.registerObject(application);
    await bus.registerObject(service);
    await bus.registerObject(announce);
    await bus.registerObject(inbox);
    await bus.registerObject(outbox);

    final gattManager = DBusRemoteObject(
      bus,
      name: 'org.bluez',
      path: _adapterPath!,
    );
    await gattManager.callMethod(
      'org.bluez.GattManager1',
      'RegisterApplication',
      [appPath, DBusDict.stringVariant({})],
      replySignature: DBusSignature(''),
    );
    log('BLE: GATT inbox registered (announce + inbox characteristics)');
  }

  Future<void> _unregisterGattApplication() async {
    final bus = _bus;
    final application = _application;
    final adapterPath = _adapterPath;
    if (bus == null || application == null || adapterPath == null) return;
    try {
      final gattManager =
          DBusRemoteObject(bus, name: 'org.bluez', path: adapterPath);
      await gattManager.callMethod(
        'org.bluez.GattManager1',
        'UnregisterApplication',
        [application.path],
        replySignature: DBusSignature(''),
      );
    } catch (_) {}
  }

  static Future<DBusObjectPath> _findAdapterPath(
    DBusClient bus,
    String adapterAddress,
  ) async {
    final root = DBusRemoteObject(
      bus,
      name: 'org.bluez',
      path: DBusObjectPath('/'),
    );
    final result = await root.callMethod(
      'org.freedesktop.DBus.ObjectManager',
      'GetManagedObjects',
      [],
      replySignature: DBusSignature('a{oa{sa{sv}}}'),
    );
    final objects = result.returnValues[0].asDict();
    for (final entry in objects.entries) {
      final interfaces = entry.value.asDict();
      for (final ifaceEntry in interfaces.entries) {
        if (ifaceEntry.key.asString() != 'org.bluez.Adapter1') continue;
        final props = ifaceEntry.value.asDict();
        final address = props.entries
            .where((p) => p.key.asString() == 'Address')
            .map((p) => p.value.asVariant().asString())
            .firstOrNull;
        if (address == adapterAddress) {
          return entry.key as DBusObjectPath;
        }
      }
    }
    throw StateError('BlueZ adapter $adapterAddress not found on D-Bus');
  }

  // ---------------------------------------------------------------------
  // Discovery (central role)
  // ---------------------------------------------------------------------

  void _onDeviceAdded(BlueZDevice device) {
    _watchDevice(device);
  }

  void _onDeviceRemoved(BlueZDevice device) {
    final address = _addressByDevicePath.remove(device.path.value);
    if (address != null) {
      _peersByAddress.remove(address);
      log('BLE: peer offline ${_short(address)} (device removed)');
      _peersChanged.add(onlinePeers);
    }
  }

  void _watchDevice(BlueZDevice device) {
    if (!_watchedDevicePaths.add(device.path.value)) return;
    if (_isMeshengerDevice(device)) {
      _maybeResolve(device);
    }
    _subs.add(device.propertiesChanged.listen((props) {
      if (props.contains('RSSI') || props.contains('UUIDs')) {
        final known = _addressByDevicePath[device.path.value];
        if (known != null) {
          final peer = _peersByAddress[known];
          if (peer != null) {
            final wasOnline = onlinePeers.contains(known);
            _peersByAddress[known] = peer.touch();
            if (!wasOnline) _peersChanged.add(onlinePeers);
          }
        } else if (_isMeshengerDevice(device)) {
          _maybeResolve(device);
        }
      }
      // A subscriber's link dropped: it is no longer pushable.
      if (props.contains('Connected') && !device.connected) {
        final inbound = _inboundPeers.remove(device.path.value);
        if (inbound != null) {
          log('BLE: subscriber ${_short(inbound.address)} disconnected');
          _peersChanged.add(onlinePeers);
        }
      }
    }));
  }

  /// Every packet written into our inbox lands here. Hellos (signed
  /// announces) bind the writing device to a mesh address and are consumed;
  /// everything else flows to the relay core. Returns false to reject the
  /// write (the writer sees a failed final chunk).
  Future<bool> _handleInboundPacket(
    Map<String, Object?> packet,
    List<int> payload,
    String devicePath,
  ) async {
    if (packet['t'] == 'announce') {
      final addr = packet['addr'] as String?;
      final x25519 = packet['x25519'] as String?;
      final sig = packet['sig'] as String?;
      if (addr == null || x25519 == null || sig == null) return false;
      if (addr == identity.address) return false;
      final valid =
          await RelayIdentity.verify('announce|$addr|$x25519|ble', sig, addr);
      if (!valid) {
        log('BLE: rejected hello with bad signature');
        return false;
      }
      final isNew = _inboundPeers[devicePath]?.address != addr;
      _inboundPeers[devicePath] = _InboundBlePeer(
        address: addr,
        x25519: x25519,
        lastSeen: DateTime.now(),
      );
      if (isNew) {
        log('BLE: hello from ${_short(addr)} — push delivery available');
      }
      _peersChanged.add(onlinePeers);
      return true;
    }

    final inbound = _inboundPeers[devicePath];
    if (inbound != null) {
      _inboundPeers[devicePath] = inbound.touch();
    }
    log('BLE: received ${packet['t']} packet (${payload.length} bytes)');
    _packets.add(packet);
    return true;
  }

  bool _isMeshengerDevice(BlueZDevice device) =>
      device.uuids.any((u) => u.toString().toLowerCase() == serviceUuid);

  void _maybeResolve(BlueZDevice device) {
    final path = device.path.value;
    if (_resolving.contains(path)) return;
    _resolving.add(path);
    _enqueueGatt(() => _resolvePeer(device)).whenComplete(() {
      _resolving.remove(path);
    });
  }

  /// Connects to an unknown Meshenger device, reads + verifies its signed
  /// announcement, and records the peer.
  Future<void> _resolvePeer(BlueZDevice device) async {
    var step = 'connect';
    try {
      await device.connect().timeout(gattTimeout);
      step = 'resolve services';
      await _awaitServicesResolved(device);

      step = 'read announce';
      final announceChar = _findCharacteristic(device, announceCharUuid);
      if (announceChar == null) return;
      final bytes = await announceChar.readValue().timeout(gattTimeout);

      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map || decoded['t'] != 'announce') return;
      final addr = decoded['addr'] as String?;
      final x25519 = decoded['x25519'] as String?;
      final sig = decoded['sig'] as String?;
      if (addr == null || x25519 == null || sig == null) return;
      if (addr == identity.address) return;

      final valid = await RelayIdentity.verify(
        'announce|$addr|$x25519|ble',
        sig,
        addr,
      );
      if (!valid) {
        log('BLE: ${device.address} announce failed verification');
        return;
      }

      _addressByDevicePath[device.path.value] = addr;
      _peersByAddress[addr] = _BlePeer(
        device: device,
        x25519: x25519,
        lastSeen: DateTime.now(),
      );
      log('BLE: peer online ${_short(addr)} (${device.address})');
      _peersChanged.add(onlinePeers);
    } catch (e) {
      log('BLE: resolve ${device.address} failed at $step: $e');
    } finally {
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _awaitServicesResolved(BlueZDevice device) async {
    if (device.servicesResolved) return;
    await device.propertiesChanged
        .firstWhere(
          (props) =>
              props.contains('ServicesResolved') && device.servicesResolved,
        )
        .timeout(gattTimeout);
  }

  BlueZGattCharacteristic? _findCharacteristic(
    BlueZDevice device,
    String uuid,
  ) {
    for (final service in device.gattServices) {
      if (service.uuid.toString().toLowerCase() != serviceUuid) continue;
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid.toString().toLowerCase() == uuid) {
          return characteristic;
        }
      }
    }
    return null;
  }

  void _reapStalePeers() {
    final now = DateTime.now();
    final stale = _peersByAddress.entries
        .where((e) => now.difference(e.value.lastSeen) > peerTimeout)
        .map((e) => e.key)
        .toList();
    for (final address in stale) {
      final peer = _peersByAddress.remove(address);
      if (peer != null) {
        _addressByDevicePath.remove(peer.device.path.value);
      }
      log('BLE: peer offline ${_short(address)} (silent too long)');
    }

    final staleInbound = _inboundPeers.entries
        .where((e) => now.difference(e.value.lastSeen) > inboundTimeout)
        .map((e) => e.key)
        .toList();
    for (final devicePath in staleInbound) {
      final inbound = _inboundPeers.remove(devicePath);
      if (inbound != null) {
        log('BLE: subscriber ${_short(inbound.address)} timed out');
      }
    }

    if (stale.isNotEmpty || staleInbound.isNotEmpty) {
      _peersChanged.add(onlinePeers);
    }
  }

  static String _short(String address) =>
      address.length <= 12 ? address : '${address.substring(0, 12)}…';

  // ---------------------------------------------------------------------
  // Sending (central role)
  // ---------------------------------------------------------------------

  @override
  Future<bool> sendPacket(
    String peerAddress,
    Map<String, Object?> packet,
  ) async {
    final payload = utf8.encode(jsonEncode(packet));

    // 1. Scan-resolved peer: connect and write into its inbox (real ack).
    final peer = _peersByAddress[peerAddress];
    if (peer != null) {
      var delivered = false;
      await _enqueueGatt(() async {
        delivered = await _deliverPayload(peer.device, payload);
      });
      if (delivered) {
        _peersByAddress[peerAddress] = peer.touch();
        return true;
      }
    }

    // 2. Push: the peer subscribed to our outbox — notify it. This is how
    //    the gateway initiates delivery to devices it cannot scan.
    return _pushToSubscriber(peerAddress, payload, packet);
  }

  Future<bool> _pushToSubscriber(
    String peerAddress,
    List<int> payload,
    Map<String, Object?> packet,
  ) async {
    final outbox = _outbox;
    if (outbox == null || !outbox.notifying) return false;
    final now = DateTime.now();
    final reachable = _inboundPeers.values.any((p) =>
        p.address == peerAddress &&
        now.difference(p.lastSeen) < inboundTimeout);
    if (!reachable) return false;

    // Notifications fan out to every subscriber, so a flood pass that
    // targets several subscribed peers needs the packet on air only once.
    final key = '${packet['t']}|${packet['id'] ?? ''}|${packet['ts'] ?? ''}';
    final nowMs = now.millisecondsSinceEpoch;
    _recentPushes.removeWhere((_, ts) => nowMs - ts > 3000);
    if (_recentPushes.containsKey(key)) return true;
    _recentPushes[key] = nowMs;

    await outbox.push(payload,
        chunkSize: _notifyChunkSize, finalFlag: _finalChunkFlag);
    log('BLE: pushed ${payload.length} bytes toward ${_short(peerAddress)} '
        '(outbox notify)');
    return true;
  }

  Future<bool> _deliverPayload(BlueZDevice device, List<int> payload) async {
    var step = 'connect';
    try {
      await device.connect().timeout(gattTimeout);
      step = 'resolve services';
      await _awaitServicesResolved(device);

      final inboxChar = _findCharacteristic(device, inboxCharUuid);
      if (inboxChar == null) return false;
      step = 'write';

      // MTU minus 3 bytes ATT header, minus 1 byte chunk flag.
      final mtu = inboxChar.mtu ?? 184;
      final chunkSize = (mtu - 4).clamp(19, 511);

      for (var offset = 0; offset < payload.length; offset += chunkSize) {
        final end = (offset + chunkSize < payload.length)
            ? offset + chunkSize
            : payload.length;
        final isLast = end == payload.length;
        final chunk = Uint8List(end - offset + 1);
        chunk[0] = isLast ? _finalChunkFlag : 0x00;
        chunk.setRange(1, chunk.length, payload, offset);

        // The final chunk's write response is the transport-level ack.
        await inboxChar
            .writeValue(
              chunk,
              type: BlueZGattCharacteristicWriteType.request,
            )
            .timeout(gattTimeout);
      }
      return true;
    } catch (e) {
      log('BLE: deliver to ${device.address} failed at $step: $e');
      return false;
    } finally {
      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  Future<void> _enqueueGatt(Future<void> Function() operation) {
    final next = _gattQueue.then((_) => operation());
    _gattQueue = next.catchError((_) {});
    return next;
  }
}

class _BlePeer {
  final BlueZDevice device;
  final String x25519;
  final DateTime lastSeen;

  const _BlePeer({
    required this.device,
    required this.x25519,
    required this.lastSeen,
  });

  _BlePeer touch() =>
      _BlePeer(device: device, x25519: x25519, lastSeen: DateTime.now());
}

/// A device that subscribed to our outbox and identified itself with a
/// signed hello — pushable until it disconnects or goes silent.
class _InboundBlePeer {
  final String address;
  final String x25519;
  final DateTime lastSeen;

  const _InboundBlePeer({
    required this.address,
    required this.x25519,
    required this.lastSeen,
  });

  _InboundBlePeer touch() => _InboundBlePeer(
      address: address, x25519: x25519, lastSeen: DateTime.now());
}

// -------------------------------------------------------------------------
// GATT server objects (org.bluez.GattApplication over D-Bus)
// -------------------------------------------------------------------------

class _GattApplication extends DBusObject {
  final List<DBusObject> children = [];

  _GattApplication(super.path) : super(isObjectManager: true);
}

class _GattService extends DBusObject {
  static const _interface = 'org.bluez.GattService1';
  final String uuid;

  _GattService(super.path, this.uuid);

  Map<String, DBusValue> get _properties => {
        'UUID': DBusString(uuid),
        'Primary': const DBusBoolean(true),
      };

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
        _interface: _properties,
      };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == _interface ? _properties[name] : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    return DBusGetAllPropertiesResponse(
        interface == _interface ? _properties : {});
  }
}

abstract class _GattCharacteristic extends DBusObject {
  static const interfaceName = 'org.bluez.GattCharacteristic1';
  final DBusObjectPath servicePath;
  final String uuid;
  final List<String> flags;

  _GattCharacteristic(
    super.path, {
    required this.servicePath,
    required this.uuid,
    required this.flags,
  });

  Map<String, DBusValue> get _properties => {
        'UUID': DBusString(uuid),
        'Service': servicePath,
        'Flags': DBusArray.string(flags),
      };

  @override
  Map<String, Map<String, DBusValue>> get interfacesAndProperties => {
        interfaceName: _properties,
      };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = interface == interfaceName ? _properties[name] : null;
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    return DBusGetAllPropertiesResponse(
        interface == interfaceName ? _properties : {});
  }
}

/// Serves the relay's signed announcement (supports offset/long reads).
class _AnnounceCharacteristic extends _GattCharacteristic {
  final Uint8List Function() bytes;

  _AnnounceCharacteristic(
    super.path, {
    required super.servicePath,
    required super.uuid,
    required this.bytes,
  }) : super(flags: const ['read']);

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _GattCharacteristic.interfaceName ||
        methodCall.name != 'ReadValue') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    var offset = 0;
    if (methodCall.values.isNotEmpty) {
      final options = methodCall.values[0].asStringVariantDict();
      final rawOffset = options['offset'];
      if (rawOffset is DBusUint16) offset = rawOffset.value;
    }
    final value = bytes();
    final slice = offset >= value.length
        ? Uint8List(0)
        : Uint8List.sublistView(value, offset);
    return DBusMethodSuccessResponse([DBusArray.byte(slice)]);
  }
}

/// Accepts chunked packet writes from phones (and other relays). The final
/// chunk's write response only succeeds after the packet parses and is
/// accepted, matching the app's ack semantics.
class _InboxCharacteristic extends _GattCharacteristic {
  final Future<bool> Function(
    Map<String, Object?> packet,
    List<int> payload,
    String devicePath,
  ) onInboundPacket;
  final void Function(String) log;

  /// Reassembly buffers keyed by the writing device's D-Bus path.
  final Map<String, BytesBuilder> _buffers = <String, BytesBuilder>{};

  _InboxCharacteristic(
    super.path, {
    required super.servicePath,
    required super.uuid,
    required this.onInboundPacket,
    required this.log,
  }) : super(flags: const ['write', 'write-without-response']);

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _GattCharacteristic.interfaceName ||
        methodCall.name != 'WriteValue') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    if (methodCall.values.isEmpty) {
      return DBusMethodErrorResponse.invalidArgs();
    }

    final value = Uint8List.fromList(
      methodCall.values[0].asByteArray().toList(),
    );
    if (value.isEmpty) {
      return DBusMethodErrorResponse('org.bluez.Error.InvalidValueLength');
    }

    var writer = 'unknown';
    if (methodCall.values.length > 1) {
      final options = methodCall.values[1].asStringVariantDict();
      final device = options['device'];
      if (device is DBusObjectPath) writer = device.value;
    }

    final flags = value[0];
    final body = value.sublist(1);
    final buffer = _buffers.putIfAbsent(writer, BytesBuilder.new);
    buffer.add(body);

    if ((flags & 0x01) == 0) {
      return DBusMethodSuccessResponse();
    }

    final payload = buffer.takeBytes();
    _buffers.remove(writer);

    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is Map && decoded['t'] is String) {
        final packet = decoded.cast<String, Object?>();
        final accepted = await onInboundPacket(packet, payload, writer);
        return accepted
            ? DBusMethodSuccessResponse()
            : DBusMethodErrorResponse('org.bluez.Error.Failed');
      }
    } catch (_) {}
    log('BLE: rejected malformed packet (${payload.length} bytes)');
    return DBusMethodErrorResponse('org.bluez.Error.Failed');
  }
}

/// The push channel. Phones subscribe (StartNotify) and the relay delivers
/// packets to them as flag-framed chunk notifications: each Value change
/// BlueZ fans out to every subscribed central.
class _OutboxCharacteristic extends _GattCharacteristic {
  final void Function(bool) onNotifyingChanged;
  bool notifying = false;

  _OutboxCharacteristic(
    super.path, {
    required super.servicePath,
    required super.uuid,
    required this.onNotifyingChanged,
  }) : super(flags: const ['notify']);

  @override
  Map<String, DBusValue> get _properties => {
        ...super._properties,
        'Notifying': DBusBoolean(notifying),
      };

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _GattCharacteristic.interfaceName) {
      return DBusMethodErrorResponse.unknownMethod();
    }
    switch (methodCall.name) {
      case 'StartNotify':
        notifying = true;
        onNotifyingChanged(true);
        return DBusMethodSuccessResponse();
      case 'StopNotify':
        notifying = false;
        onNotifyingChanged(false);
        return DBusMethodSuccessResponse();
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }

  /// Emits [payload] as chunked Value notifications. A short pause between
  /// chunks keeps bluetoothd's TX queue from overflowing on large payloads.
  Future<void> push(
    List<int> payload, {
    required int chunkSize,
    required int finalFlag,
  }) async {
    for (var offset = 0; offset < payload.length; offset += chunkSize) {
      final end = (offset + chunkSize < payload.length)
          ? offset + chunkSize
          : payload.length;
      final isLast = end == payload.length;
      final chunk = Uint8List(end - offset + 1);
      chunk[0] = isLast ? finalFlag : 0x00;
      chunk.setRange(1, chunk.length, payload, offset);
      await emitPropertiesChanged(
        _GattCharacteristic.interfaceName,
        changedProperties: {'Value': DBusArray.byte(chunk)},
      );
      if (!isLast) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
  }
}
