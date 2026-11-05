import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/services/route_log.dart';

/// The offline world the globe draws (see tool/build_world_geo.dart), as
/// unit vectors: x toward 0°E on the equator, y toward 90°E, z toward the
/// North Pole.
class WorldGeo {
  WorldGeo._(this.dots, this.coast, this.borders, this.states);

  final Float32List dots;
  final List<Float32List> coast;
  final List<Float32List> borders;
  final List<Float32List> states;

  static Future<WorldGeo>? _loading;

  static Future<WorldGeo> load() =>
      _loading ??= rootBundle.load('assets/geo/world.bin').then(WorldGeo.parse);

  static WorldGeo parse(ByteData data) {
    if (data.lengthInBytes < 12 ||
        String.fromCharCodes([
              data.getUint8(0),
              data.getUint8(1),
              data.getUint8(2),
              data.getUint8(3),
            ]) !=
            'MGEO') {
      throw const FormatException('Not a world.bin');
    }
    var offset = 8;
    int u32() {
      final value = data.getUint32(offset, Endian.little);
      offset += 4;
      return value;
    }

    Float32List points(int count) {
      final out = Float32List(count * 3);
      for (var i = 0; i < count; i++) {
        final lat = data.getFloat32(offset, Endian.little);
        final lon = data.getFloat32(offset + 4, Endian.little);
        offset += 8;
        unitVector(lat, lon, out, i * 3);
      }
      return out;
    }

    List<Float32List> lines() {
      final count = u32();
      return [for (var i = 0; i < count; i++) points(u32())];
    }

    final dots = points(u32());
    return WorldGeo._(dots, lines(), lines(), lines());
  }
}

void unitVector(double latDeg, double lonDeg, List<double> out, int at) {
  final lat = latDeg * pi / 180;
  final lon = lonDeg * pi / 180;
  out[at] = cos(lat) * cos(lon);
  out[at + 1] = cos(lat) * sin(lon);
  out[at + 2] = sin(lat);
}

/// Which point of the globe faces the viewer, and how close it is.
@immutable
class GlobeCamera {
  const GlobeCamera({required this.lat, required this.lon, this.zoom = 1});

  /// Degrees.
  final double lat;
  final double lon;
  final double zoom;

  static const double minZoom = 0.8;

  /// About 50 px per kilometer on a phone: neighbourhood scale.
  static const double maxZoom = 2000;

  static const double maxLat = 80;

  GlobeCamera rotatedBy(Offset delta, double radius) {
    if (radius <= 0) return this;
    var newLon = lon - delta.dx / radius * 180 / pi;
    newLon = (newLon + 540) % 360 - 180;
    final newLat = (lat + delta.dy / radius * 180 / pi).clamp(-maxLat, maxLat);
    return GlobeCamera(lat: newLat.toDouble(), lon: newLon, zoom: zoom);
  }

  GlobeCamera withZoom(double value) => GlobeCamera(
      lat: lat, lon: lon, zoom: value.clamp(minZoom, maxZoom).toDouble());
}

/// Orthographic projection of the unit sphere for one camera and size.
class GlobeProjection {
  GlobeProjection(GlobeCamera camera, Size size)
      : center = Offset(size.width / 2, size.height / 2),
        radius = baseRadius(size) * camera.zoom {
    final lat = camera.lat * pi / 180;
    final lon = camera.lon * pi / 180;
    final sinLat = sin(lat), cosLat = cos(lat);
    final sinLon = sin(lon), cosLon = cos(lon);
    // Rows: east (screen x), north (screen y), toward the viewer.
    ex = -sinLon;
    ey = cosLon;
    nx = -sinLat * cosLon;
    ny = -sinLat * sinLon;
    nz = cosLat;
    vx = cosLat * cosLon;
    vy = cosLat * sinLon;
    vz = sinLat;
  }

  static double baseRadius(Size size) => min(size.width, size.height) * 0.42;

  final Offset center;
  final double radius;
  late final double ex, ey, nx, ny, nz, vx, vy, vz;

  /// How much a unit vector faces the viewer (1 at the center, 0 at the
  /// edge, negative behind).
  double facing(double x, double y, double z) => vx * x + vy * y + vz * z;

  /// Screen position of a unit vector, raised [altitude] times its length,
  /// or null when the globe hides it.
  Offset? project(double x, double y, double z, [double altitude = 1]) {
    final sx = (ex * x + ey * y) * altitude;
    final sy = (nx * x + ny * y + nz * z) * altitude;
    if (facing(x, y, z) <= 0 && sx * sx + sy * sy <= 1) return null;
    return Offset(center.dx + radius * sx, center.dy - radius * sy);
  }

  Offset? projectLatLon(double latDeg, double lonDeg, [double altitude = 1]) {
    final v = <double>[0, 0, 0];
    unitVector(latDeg, lonDeg, v, 0);
    return project(v[0], v[1], v[2], altitude);
  }

  /// The (lat, lon) in degrees under a screen position, or null off the
  /// globe.
  (double, double)? unproject(Offset position) {
    final sx = (position.dx - center.dx) / radius;
    final sy = -(position.dy - center.dy) / radius;
    final r2 = sx * sx + sy * sy;
    if (r2 > 1) return null;
    final d = sqrt(1 - r2);
    final x = ex * sx + nx * sy + vx * d;
    final y = ey * sx + ny * sy + vy * d;
    final z = nz * sy + vz * d;
    return (asin(z.clamp(-1.0, 1.0)) * 180 / pi, atan2(y, x) * 180 / pi);
  }
}

enum GlobeNodeKind { me, direct, mesh }

/// A device on the globe.
class GlobeNode {
  const GlobeNode({
    required this.id,
    required this.label,
    required this.lat,
    required this.lon,
    required this.kind,
    this.accuracyM = 0,
  });

  final String id;
  final String label;
  final double lat;
  final double lon;
  final GlobeNodeKind kind;

  /// Drawn as a halo once zoomed in far enough to see it.
  final int accuracyM;
}

/// Two devices that can reach each other: a direct radio link, or one
/// inferred from what the mesh learned about routes.
class GlobeLink {
  const GlobeLink(this.from, this.to, {this.inferred = false});

  final String from;
  final String to;
  final bool inferred;
}

/// An interactive 3D globe of the mesh: drag to spin it (it keeps
/// spinning a little when let go), pinch or scroll to zoom from the whole
/// planet down to a neighbourhood, tap a device to select it, long-press
/// to pick a spot. Recent message routes arc between devices, with a pulse
/// travelling along each.
class MeshGlobe extends StatefulWidget {
  const MeshGlobe({
    super.key,
    required this.nodes,
    this.links = const <GlobeLink>[],
    this.routes = const <MessageRoute>[],
    this.selected,
    required this.onSelect,
    this.onLongPress,
    this.focus,
    this.initialZoom,
  });

  final List<GlobeNode> nodes;
  final List<GlobeLink> links;
  final List<MessageRoute> routes;
  final String? selected;
  final ValueChanged<String?> onSelect;

  /// The spot under a long press, and how many meters one screen pixel
  /// spans there (how precisely it was picked).
  final void Function(double lat, double lon, double metersPerPixel)?
      onLongPress;

  /// Where to look first (lat, lon); otherwise the devices, or the US.
  final (double, double)? focus;
  final double? initialZoom;

  @override
  State<MeshGlobe> createState() => MeshGlobeState();
}

class MeshGlobeState extends State<MeshGlobe> with TickerProviderStateMixin {
  WorldGeo? _world;
  late GlobeCamera _camera;
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(seconds: 4))
        ..repeat();
  late final Ticker _flingTicker = createTicker(_onFlingTick);
  Offset _flingVelocity = Offset.zero;
  Duration _lastFlingTick = Duration.zero;
  AnimationController? _flight;

  double _scaleStartZoom = 1;
  Offset? _lastFocal;
  Size _size = Size.zero;
  final Map<String, Offset> _hits = <String, Offset>{};

  @override
  void initState() {
    super.initState();
    _camera = _initialCamera();
    WorldGeo.load().then((world) {
      if (mounted) setState(() => _world = world);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    _flingTicker.dispose();
    _flight?.dispose();
    _pulse.dispose();
    super.dispose();
  }

  GlobeCamera _initialCamera() {
    final zoom = widget.initialZoom;
    final focus = widget.focus;
    if (focus != null) {
      return GlobeCamera(lat: focus.$1, lon: focus.$2, zoom: zoom ?? 1.5)
          .withZoom(zoom ?? 1.5);
    }
    if (widget.nodes.isNotEmpty) {
      final lat = widget.nodes.map((n) => n.lat).reduce((a, b) => a + b) /
          widget.nodes.length;
      final lon = widget.nodes.map((n) => n.lon).reduce((a, b) => a + b) /
          widget.nodes.length;
      return GlobeCamera(lat: lat, lon: lon, zoom: zoom ?? 1.3)
          .withZoom(zoom ?? 1.3);
    }
    return GlobeCamera(lat: 39, lon: -98, zoom: zoom ?? 1.2)
        .withZoom(zoom ?? 1.2);
  }

  double get _radius => GlobeProjection.baseRadius(_size) * _camera.zoom;

  void zoomBy(double factor) => _flyTo(_camera.withZoom(_camera.zoom * factor));

  /// Turns the globe to [lat], [lon], zooming in when [zoom] is given.
  void lookAt(double lat, double lon, {double? zoom}) => _flyTo(GlobeCamera(
      lat: lat.clamp(-GlobeCamera.maxLat, GlobeCamera.maxLat).toDouble(),
      lon: lon,
      zoom: zoom ?? _camera.zoom));

  void _flyTo(GlobeCamera target) {
    _stopMotion();
    final from = _camera;
    // The short way round.
    var dLon = target.lon - from.lon;
    if (dLon > 180) dLon -= 360;
    if (dLon < -180) dLon += 360;
    final flight = _flight = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 650));
    final curve = CurvedAnimation(parent: flight, curve: Curves.easeInOutCubic);
    flight.addListener(() {
      final t = curve.value;
      setState(() {
        _camera = GlobeCamera(
          lat: from.lat + (target.lat - from.lat) * t,
          lon: ((from.lon + dLon * t) + 540) % 360 - 180,
          zoom: exp(log(from.zoom) + (log(target.zoom) - log(from.zoom)) * t),
        );
      });
    });
    flight.forward().whenComplete(() {
      flight.dispose();
      if (identical(_flight, flight)) _flight = null;
    });
  }

  void _stopMotion() {
    if (_flingTicker.isActive) _flingTicker.stop();
    _flingVelocity = Offset.zero;
    _flight?.stop();
  }

  void _onFlingTick(Duration elapsed) {
    final dt = (elapsed - _lastFlingTick).inMicroseconds / 1e6;
    _lastFlingTick = elapsed;
    if (dt <= 0) return;
    _flingVelocity *= pow(0.04, dt).toDouble(); // most of it gone in a second
    if (_flingVelocity.distance < 15) {
      _flingTicker.stop();
      return;
    }
    setState(() => _camera = _camera.rotatedBy(_flingVelocity * dt, _radius));
  }

  void _onTap(Offset position) {
    String? nearest;
    var best = 24.0;
    for (final entry in _hits.entries) {
      final distance = (entry.value - position).distance;
      if (distance < best) {
        best = distance;
        nearest = entry.key;
      }
    }
    widget.onSelect(nearest);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _size = Size(constraints.maxWidth, constraints.maxHeight);
      return Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            _stopMotion();
            setState(() => _camera = _camera
                .withZoom(_camera.zoom * exp(-event.scrollDelta.dy / 400)));
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (details) {
            _stopMotion();
            _scaleStartZoom = _camera.zoom;
            _lastFocal = details.localFocalPoint;
          },
          onScaleUpdate: (details) {
            final last = _lastFocal;
            _lastFocal = details.localFocalPoint;
            setState(() {
              var camera = _camera;
              if (last != null) {
                camera =
                    camera.rotatedBy(details.localFocalPoint - last, _radius);
              }
              if (details.scale != 1) {
                camera = camera.withZoom(_scaleStartZoom * details.scale);
              }
              _camera = camera;
            });
          },
          onScaleEnd: (details) {
            _lastFocal = null;
            final velocity = details.velocity.pixelsPerSecond;
            if (details.pointerCount <= 1 && velocity.distance > 120) {
              _flingVelocity = velocity;
              _lastFlingTick = Duration.zero;
              _flingTicker.start();
            }
          },
          onTapUp: (details) => _onTap(details.localPosition),
          onLongPressStart: widget.onLongPress == null
              ? null
              : (details) {
                  final projection = GlobeProjection(_camera, _size);
                  final spot = projection.unproject(details.localPosition);
                  if (spot != null) {
                    widget.onLongPress!(spot.$1, spot.$2,
                        _GlobePainter._earthRadiusM / projection.radius);
                  }
                },
          child: CustomPaint(
            size: _size,
            painter: _GlobePainter(
              world: _world,
              camera: _camera,
              nodes: widget.nodes,
              links: widget.links,
              routes: widget.routes,
              selected: widget.selected,
              pulse: _pulse,
              hits: _hits,
            ),
          ),
        ),
      );
    });
  }
}

class _GlobePainter extends CustomPainter {
  _GlobePainter({
    required this.world,
    required this.camera,
    required this.nodes,
    required this.links,
    required this.routes,
    required this.selected,
    required this.pulse,
    required this.hits,
  }) : super(repaint: pulse);

  final WorldGeo? world;
  final GlobeCamera camera;
  final List<GlobeNode> nodes;
  final List<GlobeLink> links;
  final List<MessageRoute> routes;
  final String? selected;
  final Animation<double> pulse;
  final Map<String, Offset> hits;

  static const _land = Color(0xFF4DD0E1);
  static const _me = Color(0xFFFFD54F);
  static const _direct = Color(0xFF69F0AE);
  static const _mesh = Color(0xFF80D8FF);
  static const _route = Color(0xFFFFAB40);
  static const _transit = Color(0xFFEA80FC);
  static const _earthRadiusM = 6371000.0;

  static final List<Offset> _stars = () {
    final random = Random(7);
    return List<Offset>.generate(
        160, (_) => Offset(random.nextDouble(), random.nextDouble()));
  }();

  static final List<Float32List> _graticule = () {
    final lines = <Float32List>[];
    for (var lon = -180; lon < 180; lon += 15) {
      final line = Float32List(61 * 3);
      for (var i = 0; i <= 60; i++) {
        unitVector(-90 + i * 3.0, lon.toDouble(), line, i * 3);
      }
      lines.add(line);
    }
    for (var lat = -75; lat <= 75; lat += 15) {
      final line = Float32List(121 * 3);
      for (var i = 0; i <= 120; i++) {
        unitVector(lat.toDouble(), -180 + i * 3.0, line, i * 3);
      }
      lines.add(line);
    }
    return lines;
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final p = GlobeProjection(camera, size);
    canvas.clipRect(Offset.zero & size);
    _paintSpace(canvas, size, p);
    _paintSphere(canvas, p);
    _paintLines(canvas, size, p, _graticule,
        _stroke(Colors.white.withValues(alpha: 0.05), 0.6));
    final world = this.world;
    if (world != null) {
      _paintDots(canvas, size, p, world.dots);
      _paintLines(canvas, size, p, world.coast,
          _stroke(_land.withValues(alpha: 0.6), 0.9));
      final borders = _ramp(camera.zoom, 1.3, 2.2);
      if (borders > 0) {
        _paintLines(canvas, size, p, world.borders,
            _stroke(Colors.white.withValues(alpha: 0.28 * borders), 0.7));
      }
      final states = _ramp(camera.zoom, 2.4, 3.6);
      if (states > 0) {
        _paintLines(canvas, size, p, world.states,
            _stroke(Colors.white.withValues(alpha: 0.16 * states), 0.6));
      }
    }
    final positions = _nodePositions();
    _paintLinks(canvas, p, positions);
    _paintRoutes(canvas, p, positions);
    _paintNodes(canvas, p, positions);
  }

  /// 0 below [from], 1 above [to].
  static double _ramp(double value, double from, double to) =>
      ((value - from) / (to - from)).clamp(0.0, 1.0).toDouble();

  static Paint _stroke(Color color, double width) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeJoin = StrokeJoin.round
    ..color = color;

  void _paintSpace(Canvas canvas, Size size, GlobeProjection p) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF02050C), Color(0xFF071224)],
        ).createShader(Offset.zero & size),
    );
    final twinkle = pulse.value;
    final star = Paint();
    for (var i = 0; i < _stars.length; i++) {
      final s = _stars[i];
      final alpha = 0.15 + 0.5 * ((sin((twinkle + i * 0.37) * 2 * pi) + 1) / 2);
      star.color = Colors.white.withValues(alpha: alpha * 0.6);
      canvas.drawCircle(Offset(s.dx * size.width, s.dy * size.height),
          i % 7 == 0 ? 1.2 : 0.7, star);
    }
  }

  void _paintSphere(Canvas canvas, GlobeProjection p) {
    final r = p.radius;
    final c = p.center;
    canvas.drawCircle(
      c,
      r * 1.25,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.transparent,
            const Color(0xFF26C6DA).withValues(alpha: 0.32),
            const Color(0xFF26C6DA).withValues(alpha: 0.08),
            Colors.transparent,
          ],
          stops: const [0.78, 0.8, 0.88, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r * 1.25)),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.45),
          radius: 1.15,
          colors: [Color(0xFF1F3D63), Color(0xFF0D1C33), Color(0xFF050B17)],
          stops: [0, 0.55, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    canvas.drawCircle(
        c,
        r,
        _stroke(const Color(0xFF4DD0E1).withValues(alpha: 0.25),
            max(1.0, r * 0.006)));
  }

  void _paintDots(
      Canvas canvas, Size size, GlobeProjection p, Float32List dots) {
    final fade = 1 - _ramp(camera.zoom, 6, 30) * 0.85;
    final near = Float32List(dots.length ~/ 3 * 2);
    final mid = Float32List(dots.length ~/ 3 * 2);
    final far = Float32List(dots.length ~/ 3 * 2);
    var nearCount = 0, midCount = 0, farCount = 0;
    final w = size.width, h = size.height;
    for (var i = 0; i < dots.length; i += 3) {
      final x = dots[i], y = dots[i + 1], z = dots[i + 2];
      final d = p.facing(x, y, z);
      if (d <= 0) continue;
      final sx = p.center.dx + p.radius * (p.ex * x + p.ey * y);
      final sy = p.center.dy - p.radius * (p.nx * x + p.ny * y + p.nz * z);
      if (sx < -4 || sy < -4 || sx > w + 4 || sy > h + 4) continue;
      if (d > 0.6) {
        near[nearCount++] = sx;
        near[nearCount++] = sy;
      } else if (d > 0.3) {
        mid[midCount++] = sx;
        mid[midCount++] = sy;
      } else {
        far[farCount++] = sx;
        far[farCount++] = sy;
      }
    }
    final dotSize = (1.4 + log(camera.zoom.clamp(1.0, 40.0)) * 0.8).toDouble();
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = dotSize;
    for (final (points, count, alpha) in [
      (far, farCount, 0.22),
      (mid, midCount, 0.45),
      (near, nearCount, 0.75),
    ]) {
      if (count == 0) continue;
      paint.color = _land.withValues(alpha: alpha * fade);
      canvas.drawRawPoints(ui.PointMode.points,
          Float32List.sublistView(points, 0, count), paint);
    }
  }

  void _paintLines(Canvas canvas, Size size, GlobeProjection p,
      List<Float32List> lines, Paint paint) {
    final margin = max(size.width, size.height);
    final minX = -margin, minY = -margin;
    final maxX = size.width + margin, maxY = size.height + margin;
    final path = Path();
    for (final line in lines) {
      var down = false;
      for (var i = 0; i < line.length; i += 3) {
        final x = line[i], y = line[i + 1], z = line[i + 2];
        if (p.facing(x, y, z) <= 0) {
          down = false;
          continue;
        }
        final sx = p.center.dx + p.radius * (p.ex * x + p.ey * y);
        final sy = p.center.dy - p.radius * (p.nx * x + p.ny * y + p.nz * z);
        if (sx < minX || sy < minY || sx > maxX || sy > maxY) {
          down = false;
          continue;
        }
        if (down) {
          path.lineTo(sx, sy);
        } else {
          path.moveTo(sx, sy);
          down = true;
        }
      }
    }
    canvas.drawPath(path, paint);
  }

  Map<String, List<double>> _nodePositions() {
    final positions = <String, List<double>>{};
    for (final node in nodes) {
      final v = <double>[0, 0, 0];
      unitVector(node.lat, node.lon, v, 0);
      positions[node.id] = v;
    }
    return positions;
  }

  /// The arc from [a] to [b] (unit vectors) along the great circle, raised
  /// in the middle so longer hops arc higher. Null entries are hidden.
  List<Offset?> _arc(GlobeProjection p, List<double> a, List<double> b) {
    final cosW =
        (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]).clamp(-1.0, 1.0).toDouble();
    final w = acos(cosW);
    if (w < 1e-9) return [p.project(a[0], a[1], a[2])];
    final steps = (w * 60).ceil().clamp(8, 96);
    final lift = min(0.45, w * 0.7);
    final s = sin(w);
    return [
      for (var i = 0; i <= steps; i++)
        () {
          final t = i / steps;
          final k1 = sin((1 - t) * w) / s;
          final k2 = sin(t * w) / s;
          return p.project(
            k1 * a[0] + k2 * b[0],
            k1 * a[1] + k2 * b[1],
            k1 * a[2] + k2 * b[2],
            1 + lift * sin(pi * t),
          );
        }(),
    ];
  }

  void _drawArc(Canvas canvas, List<Offset?> points, Paint paint,
      {bool dashed = false}) {
    final path = Path();
    var down = false;
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      if (point == null || (dashed && i.isOdd)) {
        down = false;
        if (point != null && dashed) {
          path.moveTo(point.dx, point.dy);
          down = true;
        }
        continue;
      }
      if (down) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
        down = true;
      }
    }
    canvas.drawPath(path, paint);
  }

  void _paintLinks(
      Canvas canvas, GlobeProjection p, Map<String, List<double>> positions) {
    for (final link in links) {
      final a = positions[link.from], b = positions[link.to];
      if (a == null || b == null) continue;
      _drawArc(
        canvas,
        _arc(p, a, b),
        _stroke(
            (link.inferred ? _mesh : _direct)
                .withValues(alpha: link.inferred ? 0.3 : 0.55),
            link.inferred ? 1.0 : 1.5),
        dashed: link.inferred,
      );
    }
  }

  void _paintRoutes(
      Canvas canvas, GlobeProjection p, Map<String, List<double>> positions) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var animated = 0;
    for (final route in routes) {
      // Hops through devices that don't share a location are skipped; the
      // arc over the gap is dashed.
      final legs = <(List<double>, List<double>, bool)>[];
      List<double>? previous;
      var gap = false;
      for (final address in route.path) {
        final position = positions[address];
        if (position == null) {
          gap = previous != null;
          continue;
        }
        if (previous != null) legs.add((previous, position, gap));
        previous = position;
        gap = false;
      }
      if (legs.isEmpty) continue;

      final age = (now - route.tsMs) / RouteLog.showFor.inMilliseconds;
      final strength = (1 - age).clamp(0.25, 1.0).toDouble() *
          (route.alternate ? 0.55 : 1.0);
      final color = route.delivered ? _route : _transit;
      final glow = _stroke(color.withValues(alpha: 0.18 * strength), 6);
      final line = _stroke(
          color.withValues(alpha: 0.9 * strength), route.alternate ? 1.3 : 2.2);
      final trail = <Offset>[];
      for (final (a, b, dashed) in legs) {
        final arc = _arc(p, a, b);
        _drawArc(canvas, arc, glow, dashed: dashed);
        _drawArc(canvas, arc, line, dashed: dashed);
        trail.addAll(arc.whereType<Offset>());
      }
      if (animated < 4 && trail.length > 1) {
        animated++;
        _paintComet(canvas, trail, (pulse.value + animated * 0.27) % 1, color,
            strength);
      }
    }
  }

  /// A bright pulse [t] of the way along [trail].
  void _paintComet(Canvas canvas, List<Offset> trail, double t, Color color,
      double strength) {
    final lengths = <double>[0];
    for (var i = 1; i < trail.length; i++) {
      lengths.add(lengths.last + (trail[i] - trail[i - 1]).distance);
    }
    final total = lengths.last;
    if (total <= 0) return;
    final target = t * total;
    var i = 1;
    while (i < lengths.length - 1 && lengths[i] < target) {
      i++;
    }
    final span = lengths[i] - lengths[i - 1];
    final f = span <= 0 ? 0.0 : (target - lengths[i - 1]) / span;
    final at = Offset.lerp(trail[i - 1], trail[i], f)!;
    canvas.drawCircle(
        at, 9, Paint()..color = color.withValues(alpha: 0.25 * strength));
    canvas.drawCircle(
        at, 3.2, Paint()..color = Colors.white.withValues(alpha: strength));
  }

  void _paintNodes(
      Canvas canvas, GlobeProjection p, Map<String, List<double>> positions) {
    hits.clear();
    final ordered = [...nodes]..sort((a, b) {
        int rank(GlobeNode n) => n.id == selected
            ? 3
            : n.kind == GlobeNodeKind.me
                ? 2
                : n.kind == GlobeNodeKind.direct
                    ? 1
                    : 0;
        return rank(a).compareTo(rank(b));
      });
    final labelAll = camera.zoom >= 5;
    for (final node in ordered) {
      final v = positions[node.id]!;
      final at = p.project(v[0], v[1], v[2]);
      if (at == null) continue;
      hits[node.id] = at;
      final color = switch (node.kind) {
        GlobeNodeKind.me => _me,
        GlobeNodeKind.direct => _direct,
        GlobeNodeKind.mesh => _mesh,
      };
      final halo = p.radius * node.accuracyM / _earthRadiusM;
      if (halo > 5) {
        canvas.drawCircle(
            at, halo, Paint()..color = color.withValues(alpha: 0.07));
        canvas.drawCircle(at, halo, _stroke(color.withValues(alpha: 0.25), 1));
      }
      if (node.kind != GlobeNodeKind.mesh) {
        final t = (pulse.value * 2 + node.id.hashCode % 100 / 100) % 1;
        canvas.drawCircle(at, 6 + 16 * t,
            _stroke(color.withValues(alpha: 0.5 * (1 - t)), 1.4));
      }
      canvas.drawCircle(at, 10, Paint()..color = color.withValues(alpha: 0.2));
      canvas.drawCircle(at, node.kind == GlobeNodeKind.me ? 5.5 : 4.5,
          Paint()..color = color);
      canvas.drawCircle(at, 1.8, Paint()..color = Colors.white);
      if (node.id == selected) {
        canvas.drawCircle(at, 12, _stroke(Colors.white, 2));
      }
      if (labelAll || node.id == selected || node.kind != GlobeNodeKind.mesh) {
        _label(canvas, node.label, at + const Offset(0, 14));
      }
    }
  }

  void _label(Canvas canvas, String text, Offset at) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          shadows: [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 140);
    painter.paint(canvas, at - Offset(painter.width / 2, 0));
  }

  @override
  bool shouldRepaint(_GlobePainter old) => true;
}
