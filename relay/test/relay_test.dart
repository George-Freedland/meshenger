import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:meshenger_relay/meshenger_relay.dart';
import 'package:test/test.dart';

/// Relay behavior with two simulated phones (real Ed25519 identities) on an
/// in-memory link standing in for Bluetooth. Proves store-and-forward for
/// an offline recipient, via-path/hop bookkeeping, dedup, and gossip
/// re-flooding — all without the relay ever holding a message key.
void main() {
  late Directory tmp;
  late RelayCore core;
  late _TestLink link;
  late _Phone alice;
  late _Phone bob;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meshenger-relay-test');
    final identity =
        await RelayIdentity.loadOrCreate('${tmp.path}/identity.json');
    link = _TestLink();
    core = RelayCore(
      identity: identity,
      name: 'Test Relay',
      maxSpool: 16,
      transports: [link],
    );
    await core.start();

    alice = await _Phone.create();
    bob = await _Phone.create();
  });

  tearDown(() async {
    await core.stop();
    await alice.close();
    await bob.close();
    await tmp.delete(recursive: true);
  });

  test('spools for an offline peer, delivers on arrival, dedups', () async {
    // Alice comes into the relay's range; Bob is nowhere to be seen.
    link.bringIntoRange(alice);

    final envelope = <String, Object?>{
      't': 'msg',
      'id': 'env-1',
      'from': alice.address,
      'to': bob.address,
      'fromX': 'ciphertext-key-material',
      'cipher': base64Encode(utf8.encode('sealed-bytes-the-relay-cant-read')),
      'hops': 0,
      'max': 6,
      'via': const <String>[],
      'exp':
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    };

    // Alice hands the envelope to the relay.
    link.receive(envelope);

    // Give the relay a beat: nothing can be delivered yet.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(bob.received, isEmpty);

    // Bob walks into range.
    link.bringIntoRange(bob);
    final delivered = await bob.nextPacketWhere((p) => p['t'] == 'msg');

    expect(delivered['id'], 'env-1');
    expect(delivered['to'], bob.address);
    expect(delivered['hops'], 1);
    expect(
      (delivered['via'] as List).cast<String>(),
      contains(core.identity.address),
    );
    // The sealed content passed through untouched.
    expect(delivered['cipher'], envelope['cipher']);

    // A duplicate from Alice is dropped, not re-delivered.
    final before = bob.received.where((p) => p['t'] == 'msg').length;
    link.receive(envelope);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final after = bob.received.where((p) => p['t'] == 'msg').length;
    expect(after, before);
  });

  test('re-floods gossip so strangers learn about each other', () async {
    link.bringIntoRange(alice);
    link.bringIntoRange(bob);

    final gossip = await alice.buildGossip(nickname: 'Alice');
    link.receive(gossip);

    final heard = await bob.nextPacketWhere(
      (p) => p['t'] == 'gossip' && p['addr'] == alice.address,
    );
    expect(heard['nick'], 'Alice');
    expect(heard['hops'], 1);

    // The relay also gossips its own presence with its public name.
    final relayGossip = await bob.nextPacketWhere(
      (p) => p['t'] == 'gossip' && p['addr'] == core.identity.address,
    );
    expect(relayGossip['nick'], 'Test Relay');
  });
}

/// Packets cross a real link as JSON, so neither side can share (or
/// mutate) the other's maps.
Map<String, Object?> _overTheAir(Map<String, Object?> packet) =>
    (jsonDecode(jsonEncode(packet)) as Map).cast<String, Object?>();

/// The relay's only link in these tests: phones are "in range" once the
/// test says so, and every packet handed over is acknowledged.
class _TestLink implements RelayTransport {
  final Map<String, _Phone> _inRange = <String, _Phone>{};
  final _packets = StreamController<Map<String, Object?>>.broadcast();
  final _peersChanged = StreamController<Set<String>>.broadcast();

  @override
  String get name => 'test';

  @override
  Set<String> get onlinePeers => _inRange.keys.toSet();

  @override
  Stream<Map<String, Object?>> get onPacket => _packets.stream;

  @override
  Stream<Set<String>> get onPeersChanged => _peersChanged.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  void bringIntoRange(_Phone phone) {
    _inRange[phone.address] = phone;
    _peersChanged.add(onlinePeers);
  }

  /// A phone in range hands [packet] to the relay.
  void receive(Map<String, Object?> packet) =>
      _packets.add(_overTheAir(packet));

  @override
  Future<bool> sendPacket(
    String peerAddress,
    Map<String, Object?> packet,
  ) async {
    final phone = _inRange[peerAddress];
    if (phone == null) return false;
    phone.deliver(_overTheAir(packet));
    return true;
  }
}

/// A minimal "phone": an Ed25519 identity plus an inbox of everything the
/// relay delivered to it.
class _Phone {
  final SimpleKeyPair keyPair;
  final String address;
  final String x25519;
  final List<Map<String, Object?>> received = [];
  final StreamController<Map<String, Object?>> _incoming =
      StreamController.broadcast();

  _Phone._(this.keyPair, this.address, this.x25519);

  static Future<_Phone> create() async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final address = base64Encode(publicKey.bytes);

    final seed = await keyPair.extractPrivateKeyBytes();
    final derived = await Sha256().hash(<int>[
      ...utf8.encode('meshenger-x25519-v1'),
      ...seed,
    ]);
    final x = await X25519().newKeyPairFromSeed(derived.bytes);
    final xPub = base64Encode((await x.extractPublicKey()).bytes);

    return _Phone._(keyPair, address, xPub);
  }

  void deliver(Map<String, Object?> packet) {
    // The relay's unawaited sends can land after the test closed us.
    if (_incoming.isClosed) return;
    received.add(packet);
    _incoming.add(packet);
  }

  Future<String> _sign(String message) async {
    final sig = await Ed25519().sign(utf8.encode(message), keyPair: keyPair);
    return base64Encode(sig.bytes);
  }

  Future<Map<String, Object?>> buildGossip({required String nickname}) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final sig = await _sign('gossip|$address|$x25519|$nickname|$ts');
    return {
      't': 'gossip',
      'addr': address,
      'x25519': x25519,
      'nick': nickname,
      'ts': ts,
      'sig': sig,
      'hops': 0,
      'max': 6,
    };
  }

  Future<Map<String, Object?>> nextPacketWhere(
    bool Function(Map<String, Object?>) predicate, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    for (final packet in received) {
      if (predicate(packet)) return packet;
    }
    return _incoming.stream.firstWhere(predicate).timeout(timeout);
  }

  Future<void> close() => _incoming.close();
}
