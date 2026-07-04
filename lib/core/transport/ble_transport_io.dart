import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../models/incoming_message.dart';
import '../services/identity_service.dart';
import 'envelope_codec.dart';
import 'mesh_transport.dart';

/// Bluetooth LE transport (desktop/mobile).
///
/// GATT layout (every device is simultaneously central and peripheral):
/// - Announce characteristic (read): a signed announcement proving which
///   Ed25519 address + X25519 key this device belongs to.
/// - Inbox characteristic (write): receives end-to-end encrypted message
///   envelopes as chunked writes. Each chunk is prefixed with a 1-byte
///   flag; bit 0 marks the final chunk. The GATT write response of the
///   final chunk doubles as the delivery ack: it only succeeds after the
///   signature verified and decryption succeeded.
class _IoBleTransport implements MeshTransport {
  static final UUID serviceUuid =
      UUID.fromString('4d455348-454e-4745-5242-4c4530303031');
  static final UUID announceCharUuid =
      UUID.fromString('4d455348-454e-4745-5242-4c4530303032');
  static final UUID inboxCharUuid =
      UUID.fromString('4d455348-454e-4745-5242-4c4530303033');

  static const Duration rescanInterval = Duration(seconds: 12);
  static const Duration peerTimeout = Duration(seconds: 40);
  static const Duration gattTimeout = Duration(seconds: 15);
  static const int _finalChunkFlag = 0x01;

  CentralManager? _central;
  PeripheralManager? _peripheral;

  bool _running = false;
  String? _myAddress;
  Uint8List? _announcementBytes;

  final Map<String, _BlePeer> _peersByAddress = <String, _BlePeer>{};
  final Map<String, String> _addressByDeviceUuid = <String, String>{};
  final Set<String> _resolving = <String>{};

  /// Inbound chunk reassembly buffers, keyed by the writing central's UUID.
  final Map<String, BytesBuilder> _inboxBuffers = <String, BytesBuilder>{};

  final _messages = StreamController<IncomingMessage>.broadcast();
  final _peersChanged = StreamController<Set<String>>.broadcast();
  Set<String> _lastEmittedPeers = const <String>{};

  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];
  Timer? _rescanTimer;
  Timer? _reapTimer;

  /// Serializes central-side GATT operations (connect/discover/write); BLE
  /// stacks misbehave when multiple operations run concurrently.
  Future<void> _gattQueue = Future<void>.value();

  @override
  bool get isRunning => _running;

  @override
  Set<String> get onlinePeers {
    final now = DateTime.now();
    return _peersByAddress.entries
        .where((e) => now.difference(e.value.lastSeen) < peerTimeout)
        .map((e) => e.key)
        .toSet();
  }

  @override
  Stream<IncomingMessage> get onMessage => _messages.stream;

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
    final peripheral = _peripheral ??= PeripheralManager();

    if (Platform.isAndroid) {
      try {
        await central.authorize();
        await peripheral.authorize();
      } catch (_) {
        // Permission dialogs are best-effort; state check below is decisive.
      }
    }

    await _waitPoweredOn(central);
    await _waitPoweredOn(peripheral);

    // --- Peripheral role: advertise + accept inbound messages ---
    _subscriptions.add(
      peripheral.characteristicReadRequested.listen(_scheduleReadRequest),
    );
    _subscriptions.add(
      peripheral.characteristicWriteRequested.listen(_scheduleWriteRequest),
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
        ],
      ),
    );

    // Windows: addService() already calls GattServiceProvider.StartAdvertising,
    // which makes the Meshenger service discoverable. Calling
    // BluetoothLEAdvertisementPublisher with ServiceUuids on top of that
    // throws winrt "The parameter is incorrect." (see plugin example).
    if (!Platform.isWindows) {
      await peripheral.startAdvertising(
        Advertisement(serviceUUIDs: [serviceUuid]),
      );
    }

    // --- Central role: discover peers ---
    _subscriptions.add(central.discovered.listen(_handleDiscovered));
    await _startDiscovery(central);

    // macOS/iOS coalesce repeated advertisements from the same device, so
    // periodically restart discovery to re-observe devices that are still
    // present, keeping lastSeen fresh.
    _rescanTimer = Timer.periodic(rescanInterval, (_) => _restartDiscovery());
    _reapTimer = Timer.periodic(peerTimeout, (_) => _reapStalePeers());

    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _reapTimer?.cancel();
    _reapTimer = null;

    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

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
    _resolving.clear();
    _inboxBuffers.clear();
    _emitPeersIfChanged();
  }

  // -----------------------------------------------------------------------
  // Discovery (central role)
  // -----------------------------------------------------------------------

  Future<void> _startDiscovery(CentralManager central) async {
    try {
      await central.startDiscovery(serviceUUIDs: [serviceUuid]);
    } on Object {
      // Some Windows builds reject a strict service-UUID filter even though
      // the peer is advertising via GattServiceProvider; fall back to a
      // broad scan and resolve Meshenger peers in _resolvePeer.
      if (Platform.isWindows) {
        await central.startDiscovery();
      } else {
        rethrow;
      }
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

  void _handleDiscovered(DiscoveredEventArgs event) {
    final deviceUuid = event.peripheral.uuid.toString();

    final knownAddress = _addressByDeviceUuid[deviceUuid];
    if (knownAddress != null) {
      final peer = _peersByAddress[knownAddress];
      if (peer != null) {
        _peersByAddress[knownAddress] =
            peer.copyWith(peripheral: event.peripheral, lastSeen: DateTime.now());
        _emitPeersIfChanged();
        return;
      }
    }

    if (_resolving.contains(deviceUuid)) return;
    _resolving.add(deviceUuid);
    _enqueueGatt(() => _resolvePeer(event.peripheral)).whenComplete(() {
      _resolving.remove(deviceUuid);
    });
  }

  /// Connects to an unknown Meshenger device, reads and verifies its signed
  /// announcement, and records the peer.
  Future<void> _resolvePeer(Peripheral device) async {
    final central = _central;
    if (central == null || !_running) return;
    try {
      await central.connect(device).timeout(gattTimeout);
      final services = await central.discoverGATT(device).timeout(gattTimeout);
      final announceChar = _findCharacteristic(services, announceCharUuid);
      if (announceChar == null) {
        // Not a Meshenger device (expected during broad scans on Windows).
        return;
      }

      final bytes =
          await central.readCharacteristic(device, announceChar).timeout(gattTimeout);
      final peerIdentity = await EnvelopeCodec.verifyBleAnnouncementBytes(bytes);
      if (peerIdentity == null) return;
      if (peerIdentity.address == _myAddress) return;

      _addressByDeviceUuid[device.uuid.toString()] = peerIdentity.address;
      _peersByAddress[peerIdentity.address] = _BlePeer(
        peripheral: device,
        x25519Base64: peerIdentity.x25519Base64,
        lastSeen: DateTime.now(),
      );
      debugPrint('BLE: resolved peer ${peerIdentity.address} '
          '(device ${device.uuid})');
      _emitPeersIfChanged();
    } catch (e) {
      // Device went away or isn't a functioning Meshenger node.
      debugPrint('BLE: resolve ${device.uuid} failed: $e');
    } finally {
      try {
        await central.disconnect(device);
      } catch (_) {}
    }
  }

  Future<void> _restartDiscovery() async {
    final central = _central;
    if (central == null || !_running) return;
    try {
      await central.stopDiscovery();
      await _startDiscovery(central);
    } catch (e) {
      // Bluetooth may have turned off; the reap timer will clear peers.
      debugPrint('BLE: restart discovery failed: $e');
    }
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
        _addressByDeviceUuid.remove(peer.peripheral.uuid.toString());
      }
    }
    if (stale.isNotEmpty) {
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

  // -----------------------------------------------------------------------
  // Sending (central role)
  // -----------------------------------------------------------------------

  @override
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
  }) async {
    final peer = _peersByAddress[peerAddress];
    final from = _myAddress;
    if (peer == null || from == null || !_running) return false;

    final envelope = await EnvelopeCodec.encryptEnvelope(
      from: from,
      to: peerAddress,
      toX25519Base64: peer.x25519Base64,
      messageId: messageId,
      text: text,
      timestamp: timestamp,
      groupId: groupId,
      groupMembers: groupMembers,
      groupAdmin: groupAdmin,
      groupName: groupName,
      groupEvent: groupEvent,
    );
    final payload = utf8.encode(jsonEncode(envelope));

    var delivered = false;
    await _enqueueGatt(() async {
      delivered = await _deliverPayload(peer.peripheral, payload);
    });
    return delivered;
  }

  Future<bool> _deliverPayload(Peripheral device, List<int> payload) async {
    final central = _central;
    if (central == null) return false;
    try {
      await central.connect(device).timeout(gattTimeout);
      final services = await central.discoverGATT(device).timeout(gattTimeout);
      final inboxChar = _findCharacteristic(services, inboxCharUuid);
      if (inboxChar == null) return false;

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

        // The final chunk's write response is the app-level ack: the
        // peripheral only responds successfully after verifying and
        // decrypting the complete envelope.
        await central
            .writeCharacteristic(
              device,
              inboxChar,
              value: chunk,
              type: GATTCharacteristicWriteType.withResponse,
            )
            .timeout(gattTimeout);
      }
      return true;
    } catch (e) {
      debugPrint('BLE: deliver to ${device.uuid} failed: $e');
      return false;
    } finally {
      try {
        await central.disconnect(device);
      } catch (_) {}
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

    IncomingMessage? incoming;
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is Map) {
        incoming = await EnvelopeCodec.decryptEnvelope(
          decoded,
          myAddress: _myAddress ?? '',
        );
      }
    } catch (_) {
      incoming = null;
    }

    if (incoming == null) {
      await peripheral.respondWriteRequestWithError(
        event.request,
        error: GATTError.unlikelyError,
      );
      return;
    }

    // Ack first (success response to the final write), then surface the
    // message to the app.
    await peripheral.respondWriteRequest(event.request);
    _messages.add(incoming);
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

MeshTransport createTransport() => _IoBleTransport();
