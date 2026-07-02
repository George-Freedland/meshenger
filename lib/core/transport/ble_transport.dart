import 'mesh_transport.dart';

import 'ble_transport_stub.dart'
    if (dart.library.io) 'ble_transport_io.dart' as impl;

/// Bluetooth LE transport: works with no network infrastructure at all.
///
/// Every device runs both BLE roles simultaneously:
/// - Peripheral: advertises the Meshenger GATT service and accepts inbound
///   encrypted message writes.
/// - Central: scans for other Meshenger devices, verifies their signed
///   announcements, and delivers messages via chunked GATT writes.
MeshTransport createBleTransport() => impl.createTransport();
