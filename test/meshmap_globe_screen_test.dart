import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:meshenger/core/services/identity_scope.dart';
import 'package:meshenger/core/services/identity_service.dart';
import 'package:meshenger/core/services/location_service.dart';
import 'package:meshenger/core/services/peer_directory.dart';
import 'package:meshenger/core/services/settings_service.dart';
import 'package:meshenger/features/apps/mesh_globe.dart';
import 'package:meshenger/features/apps/meshmap_screen.dart';

void main() {
  testWidgets('the Mesh Map switches to the globe and places devices',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.runAsync(() async {
      final keys = await Ed25519().newKeyPair();
      await IdentityService.instance
          .debugUnlockWithKeyPair(keys, nickname: 'George');
      IdentityScope.setActive(
          base64Encode((await keys.extractPublicKey()).bytes));
      PeerDirectory.instance.resetCache();
      await SettingsService.instance.setMeshMapGlobe(true);
      await LocationService.instance.setPin(const GeoPoint(
          lat: 37.77, lon: -122.42, accuracyM: 25, tsMs: 1));
      await LocationService.instance.setShareApproximate(true);
      await PeerDirectory.instance.recordGossip('denver-pi', 'key',
          nickname: 'Denver Pi',
          hops: 3,
          tsMs: DateTime.now().millisecondsSinceEpoch,
          location: GeoPoint(
              lat: 39.74,
              lon: -104.99,
              accuracyM: 1000,
              tsMs: DateTime.now().millisecondsSinceEpoch));
      await PeerDirectory.instance.recordGossip('no-location', 'key2',
          hops: 1, tsMs: DateTime.now().millisecondsSinceEpoch);
    });

    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: RepaintBoundary(key: key, child: const MeshMapScreen()),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(MeshGlobe), findsOneWidget);
    expect(find.byTooltip('Radar view'), findsOneWidget);
    expect(find.textContaining("doesn't share a location"), findsOneWidget);
    expect(find.byTooltip('Show me'), findsOneWidget);

    final out = Platform.environment['GLOBE_SNAPSHOT'];
    if (out != null) {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await boundary.toImage();
        return (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
      });
      File('$out/meshmap_globe.png').writeAsBytesSync(bytes!);
    }

    await tester.tap(find.byTooltip('Radar view'));
    await tester.pump();
    expect(find.byType(MeshGlobe), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
