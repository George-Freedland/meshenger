import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:meshenger/core/services/route_log.dart';
import 'package:meshenger/features/apps/mesh_globe.dart';

void main() {
  group('projection', () {
    const size = Size(400, 400);

    test('the point the camera looks at is in the middle', () {
      final p =
          GlobeProjection(const GlobeCamera(lat: 37.77, lon: -122.42), size);
      final at = p.projectLatLon(37.77, -122.42)!;
      expect(at.dx, closeTo(200, 1e-6));
      expect(at.dy, closeTo(200, 1e-6));
    });

    test('east is right, north is up, the far side is hidden', () {
      final p = GlobeProjection(const GlobeCamera(lat: 0, lon: 0), size);
      expect(p.projectLatLon(0, 45)!.dx, greaterThan(200));
      expect(p.projectLatLon(45, 0)!.dy, lessThan(200));
      expect(p.projectLatLon(0, 180), isNull);
      // Raised high enough, a point just behind the horizon shows.
      expect(p.projectLatLon(0, 100, 1.5), isNotNull);
    });

    test('unproject finds the spot under the finger', () {
      final p =
          GlobeProjection(const GlobeCamera(lat: 40, lon: -100, zoom: 3), size);
      final screen = p.projectLatLon(41.5, -97.25)!;
      final (lat, lon) = p.unproject(screen)!;
      expect(lat, closeTo(41.5, 1e-6));
      expect(lon, closeTo(-97.25, 1e-6));
      expect(p.unproject(const Offset(-5000, 0)), isNull);
    });

    test('dragging spins the globe and stays in range', () {
      const camera = GlobeCamera(lat: 79, lon: 179);
      final turned = camera.rotatedBy(const Offset(-50, 300), 100);
      expect(turned.lon, inInclusiveRange(-180, 180));
      expect(turned.lat, GlobeCamera.maxLat);
      expect(camera.withZoom(1e9).zoom, GlobeCamera.maxZoom);
    });
  });

  for (final (name, zoom) in [
    ('planet', 1.0),
    ('default', null),
    ('states', 5.0)
  ]) {
    testWidgets('renders the world with devices and a route ($name)',
        (tester) async {
      await _renderGlobe(tester, name, zoom);
    });
  }
}

Future<void> _renderGlobe(
    WidgetTester tester, String name, double? zoom) async {
  await tester.binding.setSurfaceSize(const Size(900, 900));
  final key = GlobalKey();
  final now = DateTime.now().millisecondsSinceEpoch;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: RepaintBoundary(
        key: key,
        child: MeshGlobe(
          focus: (37, -96),
          initialZoom: zoom,
          nodes: const [
            GlobeNode(
                id: 'me',
                label: 'You',
                lat: 37.77,
                lon: -122.42,
                kind: GlobeNodeKind.me),
            GlobeNode(
                id: 'den',
                label: 'Denver Pi',
                lat: 39.74,
                lon: -104.99,
                kind: GlobeNodeKind.direct),
            GlobeNode(
                id: 'chi',
                label: 'Chicago',
                lat: 41.88,
                lon: -87.63,
                kind: GlobeNodeKind.mesh),
            GlobeNode(
                id: 'nyc',
                label: 'New York',
                lat: 40.71,
                lon: -74.01,
                kind: GlobeNodeKind.mesh,
                accuracyM: 1000),
          ],
          links: const [
            GlobeLink('me', 'den'),
            GlobeLink('den', 'chi', inferred: true),
          ],
          routes: [
            MessageRoute(
                messageId: 'm1',
                path: const ['me', 'den', 'chi', 'nyc'],
                delivered: true,
                tsMs: now),
            MessageRoute(
                messageId: 'm1',
                path: const ['me', 'unknown', 'nyc'],
                delivered: true,
                alternate: true,
                tsMs: now),
          ],
          selected: 'den',
          onSelect: (_) {},
        ),
      ),
    ),
  ));
  // The world loads from the asset bundle.
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
  await tester.pump(const Duration(milliseconds: 1200));

  // GLOBE_SNAPSHOT=<folder> saves what it drew, to look at.
  final out = Platform.environment['GLOBE_SNAPSHOT'];
  if (out != null) {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    File('$out/globe_$name.png').writeAsBytesSync(bytes!);
  }
  expect(tester.takeException(), isNull);
  await tester.binding.setSurfaceSize(null);
}
