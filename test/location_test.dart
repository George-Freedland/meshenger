import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/models/incoming_message.dart';
import 'package:meshenger/core/services/identity_scope.dart';
import 'package:meshenger/core/services/identity_service.dart';
import 'package:meshenger/core/services/location_service.dart';
import 'package:meshenger/core/services/messenger_service.dart';
import 'package:meshenger/core/services/peer_directory.dart';
import 'package:meshenger/core/services/route_log.dart';
import 'package:meshenger/core/transport/envelope_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String me;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final keys = await Ed25519().newKeyPair();
    await IdentityService.instance.debugUnlockWithKeyPair(keys, nickname: 'Me');
    me = base64Encode((await keys.extractPublicKey()).bytes);
    IdentityScope.setActive(me);
    PeerDirectory.instance.resetCache();
    LocationService.instance.reset();
    RouteLog.instance.clear();
  });

  group('GeoPoint', () {
    test('approximate puts nearby spots in the same ~1 km cell', () {
      const a = GeoPoint(lat: 37.77493, lon: -122.41942, accuracyM: 8, tsMs: 1);
      const b = GeoPoint(lat: 37.77210, lon: -122.41700, accuracyM: 8, tsMs: 2);
      expect(a.approximate().lat, b.approximate().lat);
      expect(a.approximate().lon, b.approximate().lon);
      expect(a.approximate().lat, 37.77);
      expect(a.approximate().accuracyM, LocationService.approximateAccuracyM);
    });

    test('round-trips its signed form and refuses nonsense', () {
      const point =
          GeoPoint(lat: -33.86882, lon: 151.20929, accuracyM: 12, tsMs: 99);
      final back = GeoPoint.decode(point.encode())!;
      expect(back.lat, point.lat);
      expect(back.lon, point.lon);
      expect(back.accuracyM, 12);
      expect(GeoPoint.decode('91,0,1,1'), isNull);
      expect(GeoPoint.decode('1,2,3'), isNull);
      expect(GeoPoint.decode('a,b,c,d'), isNull);
    });
  });

  group('location in gossip', () {
    const spot = GeoPoint(lat: 40.71280, lon: -74.00600, accuracyM: 5, tsMs: 1);

    test('rides along signed, and the record verifies as before', () async {
      final gossip = await EnvelopeCodec.buildGossip(
          nickname: 'Me', location: spot);
      final record = (await EnvelopeCodec.verifyGossip(gossip))!;
      expect(record.address, me);
      expect(record.location!.lat, spot.lat);
      expect(record.location!.lon, spot.lon);

      final plain = await EnvelopeCodec.buildGossip(nickname: 'Me');
      expect(plain.containsKey('loc'), isFalse);
      expect((await EnvelopeCodec.verifyGossip(plain))!.location, isNull);
    });

    test("a relay can't move someone on the map", () async {
      final gossip = await EnvelopeCodec.buildGossip(location: spot);
      final loc = Map<String, Object?>.from(gossip['loc']! as Map);
      loc['v'] = const GeoPoint(lat: 1, lon: 2, accuracyM: 5, tsMs: 1).encode();
      final tampered = {...gossip, 'loc': loc};
      final record = (await EnvelopeCodec.verifyGossip(tampered))!;
      expect(record.location, isNull,
          reason: 'the record survives; the forged location does not');
    });

    test('stopping sharing removes the location everywhere', () async {
      final directory = PeerDirectory.instance;
      await directory.recordGossip('peer', 'key',
          hops: 2, tsMs: 100, location: spot);
      expect((await directory.get('peer'))!.recentLocation, isNull,
          reason: 'its timestamp (1970) is far too old to show');
      final fresh = GeoPoint(
          lat: spot.lat,
          lon: spot.lon,
          accuracyM: 5,
          tsMs: DateTime.now().millisecondsSinceEpoch);
      await directory.recordGossip('peer', 'key',
          hops: 2, tsMs: 200, location: fresh);
      expect((await directory.get('peer'))!.recentLocation!.lat, spot.lat);

      await directory.recordDirect('peer', 'key');
      expect((await directory.get('peer'))!.location, isNotNull,
          reason: 'seeing it nearby says nothing about its sharing');

      final later = DateTime.now().millisecondsSinceEpoch + 1000;
      await directory.recordGossip('peer', 'key', hops: 2, tsMs: later);
      expect((await directory.get('peer'))!.location, isNull);
    });
  });

  group('sharing settings', () {
    final location = LocationService.instance;

    test('a Mac waits out its Wi-Fi scan instead of the 20 second limit', () {
      final mac = LocationService.readSettings(macOS: true);
      final other = LocationService.readSettings(macOS: false);
      expect(mac.timeLimit, isNull);
      expect(mac.accuracy, LocationAccuracy.low);
      expect(other.timeLimit, const Duration(seconds: 20));
      expect(other.accuracy, LocationAccuracy.high);
    });

    test('with no fix of its own, a device stands next to one it can hear',
        () async {
      await location.setShareExact(true);
      location.nearbyPosition = () async => const GeoPoint(
            lat: 40.71280, lon: -74.00600, accuracyM: 12, tsMs: 1);
      final exact = (await location.sharedPosition())!;
      expect(exact.lat, 40.71280);
      expect(exact.lon, -74.00600);
      expect(exact.accuracyM, 12 + LocationService.nearbyRadioM);
      expect(location.origin, LocationOrigin.nearby);
    });

    test('a position it measured earlier is used with the radios off',
        () async {
      final point = GeoPoint(
        lat: 40.71280,
        lon: -74.00600,
        accuracyM: 30,
        tsMs: DateTime.now().millisecondsSinceEpoch,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          IdentityScope.key(LocationService.ownFixKey), point.encode());
      location.nearbyPosition = () async => const GeoPoint(
            lat: 1, lon: 2, accuracyM: 5, tsMs: 1);
      await location.setShareExact(true);
      final exact = (await location.sharedPosition())!;
      expect(exact.lat, point.lat);
      expect(exact.accuracyM, 30);
      expect(location.origin, LocationOrigin.remembered);
    });

    test('both are off until turned on, and nothing is shared', () async {
      expect(await location.getShareApproximate(), isFalse);
      expect(await location.getShareExact(), isFalse);
      await location.setPin(
          const GeoPoint(lat: 37.77493, lon: -122.41942, accuracyM: 30, tsMs: 1));
      expect(await location.sharedPosition(), isNull);
    });

    test('approximate shares the cell, exact shares the spot', () async {
      await location.setPin(
          const GeoPoint(lat: 37.77493, lon: -122.41942, accuracyM: 30, tsMs: 1));
      await location.setShareApproximate(true);
      final rough = (await location.sharedPosition())!;
      expect(rough.lat, 37.77);
      expect(rough.lon, -122.42);
      expect(rough.accuracyM, 1000);

      await location.setShareExact(true);
      final exact = (await location.sharedPosition())!;
      expect(exact.lat, 37.77493);
      expect(exact.accuracyM, 30);
    });
  });

  group('message routes', () {
    test('a copy arriving the long way is an alternate route', () {
      final log = RouteLog.instance;
      log.note(messageId: 'm', path: ['a', 'b', 'me'], delivered: true);
      log.note(messageId: 'm', path: ['a', 'b', 'me'], delivered: true);
      log.note(messageId: 'm', path: ['a', 'c', 'd', 'me'], delivered: true);
      final routes = log.recent();
      expect(routes, hasLength(2));
      expect(routes.first.alternate, isTrue);
      expect(routes.last.alternate, isFalse);
    });

    test('envelopes and receipts both put their route on the map', () async {
      await MessengerService.instance.debugHandlePacket(<String, Object?>{
        't': 'msg',
        'id': 'envelope-1',
        'from': 'alice',
        'to': me,
        'via': ['pi-denver', 'bob'],
        'hops': 3,
        'nonce': '',
        'cipher': '',
        'mac': '',
        'sig': '',
      });
      final arrived = RouteLog.instance.recent().single;
      expect(arrived.path, ['alice', 'pi-denver', 'bob', me]);
      expect(arrived.delivered, isTrue);
      expect(arrived.truncated, isTrue, reason: '3 hops, 2 relays named');

      RouteLog.instance.clear();
      await MessengerService.instance.debugHandleIncoming(IncomingMessage(
        fromAddress: 'carol',
        id: 'receipt-1',
        text: jsonEncode({
          'route': [me, 'pi-denver', 'carol'],
          'hops': 1,
        }),
        timestamp: DateTime.now(),
        action: 'ack',
        targetId: 'my-message',
      ));
      final delivered = RouteLog.instance.recent().single;
      expect(delivered.messageId, 'my-message');
      expect(delivered.path, [me, 'pi-denver', 'carol']);
    });
  });
}
