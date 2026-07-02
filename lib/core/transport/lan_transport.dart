import 'mesh_transport.dart';

import 'lan_transport_stub.dart'
    if (dart.library.io) 'lan_transport_io.dart' as impl;

/// LAN transport: discovers peers on the local network (signed UDP
/// broadcast) and delivers end-to-end encrypted messages over TCP.
///
/// Requires no internet: two devices on the same Wi-Fi network or hotspot
/// can exchange messages directly.
MeshTransport createLanTransport() => impl.createTransport();
