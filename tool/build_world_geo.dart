// Builds assets/geo/world.bin, the offline world the Mesh Map globe draws,
// from Natural Earth GeoJSON (public domain, naturalearthdata.com), as
// published at https://github.com/nvkelso/natural-earth-vector/tree/master/geojson:
//
//   ne_110m_land.geojson                           land, for the dotted surface
//   ne_50m_coastline.geojson                       coastlines
//   ne_50m_admin_0_boundary_lines_land.geojson     country borders
//   ne_50m_admin_1_states_provinces_lines.geojson  state and province lines
//
// Run it from outside the app's folder (inside it, `dart` first builds the
// app's native hooks):
//
//   cd /tmp && dart ~/Code/meshenger/tool/build_world_geo.dart \
//       <folder with those files> ~/Code/meshenger/assets/geo/world.bin
//
// Format, little-endian: "MGEO", version byte, 3 padding bytes; land dots
// (u32 count, then f32 lat/lon pairs); then coastlines, borders and state
// lines, each as u32 line count and per line u32 point count plus f32
// lat/lon pairs.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const _dotsOnSphere = 42000; // about 1.1 degrees apart
const _tolerance = 0.02; // degrees, about 2 km

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: build_world_geo.dart <geojson folder> <out.bin>');
    exit(64);
  }
  final source = args[0];
  final land = _polygons(_read('$source/ne_110m_land.geojson'));
  final dots = _landDots(land);
  final coast = _simplified(_lines(_read('$source/ne_50m_coastline.geojson')));
  final borders = _simplified(
      _lines(_read('$source/ne_50m_admin_0_boundary_lines_land.geojson')));
  final states = _simplified(
      _lines(_read('$source/ne_50m_admin_1_states_provinces_lines.geojson')));

  final out = BytesBuilder();
  out.add(ascii.encode('MGEO'));
  out.add([1, 0, 0, 0]);
  out.add(_u32(dots.length));
  for (final dot in dots) {
    out.add(_f32(dot.y));
    out.add(_f32(dot.x));
  }
  var points = dots.length;
  for (final lines in [coast, borders, states]) {
    out.add(_u32(lines.length));
    for (final line in lines) {
      out.add(_u32(line.length));
      for (final p in line) {
        out.add(_f32(p.y));
        out.add(_f32(p.x));
      }
      points += line.length;
    }
  }
  final bytes = out.takeBytes();
  File(args[1])
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  stdout.writeln('${dots.length} land dots, ${coast.length} coastlines, '
      '${borders.length} borders, ${states.length} state lines; '
      '$points points, ${bytes.length} bytes');
}

Map<String, Object?> _read(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

/// Points are (lon, lat).
typedef _Line = List<Point<double>>;

List<_Line> _lines(Map<String, Object?> collection) {
  final result = <_Line>[];
  for (final feature in collection['features'] as List) {
    final geometry = (feature as Map)['geometry'] as Map?;
    if (geometry == null) continue;
    final coordinates = geometry['coordinates'] as List;
    switch (geometry['type']) {
      case 'LineString':
        result.add(_line(coordinates));
      case 'MultiLineString':
        result.addAll(coordinates.map((c) => _line(c as List)));
      case 'Polygon':
        result.addAll(coordinates.map((c) => _line(c as List)));
      case 'MultiPolygon':
        for (final polygon in coordinates) {
          result.addAll((polygon as List).map((c) => _line(c as List)));
        }
    }
  }
  return result;
}

/// Polygons as rings (outer first, then holes).
List<List<_Line>> _polygons(Map<String, Object?> collection) {
  final result = <List<_Line>>[];
  for (final feature in collection['features'] as List) {
    final geometry = (feature as Map)['geometry'] as Map?;
    if (geometry == null) continue;
    final coordinates = geometry['coordinates'] as List;
    switch (geometry['type']) {
      case 'Polygon':
        result.add(coordinates.map((c) => _line(c as List)).toList());
      case 'MultiPolygon':
        for (final polygon in coordinates) {
          result.add(
              (polygon as List).map((c) => _line(c as List)).toList());
        }
    }
  }
  return result;
}

_Line _line(List coordinates) => [
      for (final c in coordinates)
        Point<double>(
            ((c as List)[0] as num).toDouble(), (c[1] as num).toDouble()),
    ];

/// Evenly spread points (a Fibonacci lattice) that fall on land.
List<Point<double>> _landDots(List<List<_Line>> land) {
  final boxes = [for (final polygon in land) _box(polygon.first)];
  final golden = pi * (3 - sqrt(5));
  final dots = <Point<double>>[];
  for (var i = 0; i < _dotsOnSphere; i++) {
    final y = 1 - (i + 0.5) * 2 / _dotsOnSphere;
    final lat = asin(y) * 180 / pi;
    var lon = (i * golden) * 180 / pi % 360;
    if (lon > 180) lon -= 360;
    final p = Point<double>(lon, lat);
    for (var k = 0; k < land.length; k++) {
      if (!boxes[k].containsPoint(p)) continue;
      if (_inPolygon(land[k], p)) {
        dots.add(p);
        break;
      }
    }
  }
  return dots;
}

Rectangle<double> _box(_Line ring) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in ring) {
    minX = min(minX, p.x);
    maxX = max(maxX, p.x);
    minY = min(minY, p.y);
    maxY = max(maxY, p.y);
  }
  return Rectangle<double>(minX, minY, maxX - minX, maxY - minY);
}

bool _inPolygon(List<_Line> rings, Point<double> p) {
  if (!_inRing(rings.first, p)) return false;
  for (final hole in rings.skip(1)) {
    if (_inRing(hole, p)) return false;
  }
  return true;
}

bool _inRing(_Line ring, Point<double> p) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a.y > p.y) != (b.y > p.y) &&
        p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

List<_Line> _simplified(List<_Line> lines) => [
      for (final line in lines)
        if (_douglasPeucker(line) case final simple when simple.length >= 2)
          simple,
    ];

_Line _douglasPeucker(_Line line) {
  if (line.length < 3) return line;
  final keep = List<bool>.filled(line.length, false);
  keep[0] = keep[line.length - 1] = true;
  final stack = <(int, int)>[(0, line.length - 1)];
  while (stack.isNotEmpty) {
    final (start, end) = stack.removeLast();
    var farthest = -1;
    var distance = _tolerance;
    for (var i = start + 1; i < end; i++) {
      final d = _segmentDistance(line[i], line[start], line[end]);
      if (d > distance) {
        distance = d;
        farthest = i;
      }
    }
    if (farthest >= 0) {
      keep[farthest] = true;
      stack.add((start, farthest));
      stack.add((farthest, end));
    }
  }
  return [
    for (var i = 0; i < line.length; i++)
      if (keep[i]) line[i],
  ];
}

double _segmentDistance(Point<double> p, Point<double> a, Point<double> b) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final length = dx * dx + dy * dy;
  if (length == 0) return p.distanceTo(a);
  final t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / length).clamp(0.0, 1.0);
  return p.distanceTo(Point<double>(a.x + t * dx, a.y + t * dy));
}

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

Uint8List _f32(double value) =>
    (ByteData(4)..setFloat32(0, value, Endian.little)).buffer.asUint8List();
