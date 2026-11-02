import 'dart:math' as math;
import 'dart:typed_data';

import 'expression.dart';

/// The geometry argument of `within` and `distance`: a GeoJSON object
/// (`Point` … `MultiPolygon`, `Feature`, `FeatureCollection`) flattened
/// into point sets, polylines and polygons, in longitude/latitude.
///
/// Parsed once, when the expression is compiled; [parse] returns null
/// for anything that is not GeoJSON geometry, which the parser reports
/// as unsupported, as MapLibre rejects it.
final class GeoShapes {
  /// Every `Point` / `MultiPoint` coordinate, interleaved lng, lat.
  final Float64List points;
  final List<Float64List> lines;

  /// Rings per polygon, the exterior first, each interleaved lng, lat.
  final List<List<Float64List>> polygons;

  const GeoShapes._(this.points, this.lines, this.polygons);

  bool get isEmpty => points.isEmpty && lines.isEmpty && polygons.isEmpty;

  static GeoShapes? parse(Object? json) {
    final points = <double>[];
    final lines = <Float64List>[];
    final polygons = <List<Float64List>>[];
    if (!_collect(json, points, lines, polygons)) return null;
    final shapes = GeoShapes._(Float64List.fromList(points), lines, polygons);
    return shapes.isEmpty ? null : shapes;
  }

  static bool _collect(Object? json, List<double> points,
      List<Float64List> lines, List<List<Float64List>> polygons) {
    if (json is! Map) return false;
    final coordinates = json['coordinates'];
    switch (json['type']) {
      case 'FeatureCollection':
        final features = json['features'];
        if (features is! List) return false;
        for (final feature in features) {
          if (!_collect(feature, points, lines, polygons)) return false;
        }
        return true;
      case 'Feature':
        return _collect(json['geometry'], points, lines, polygons);
      case 'GeometryCollection':
        final geometries = json['geometries'];
        if (geometries is! List) return false;
        for (final geometry in geometries) {
          if (!_collect(geometry, points, lines, polygons)) return false;
        }
        return true;
      case 'Point':
        final p = _position(coordinates);
        if (p == null) return false;
        points.addAll(p);
        return true;
      case 'MultiPoint':
        final run = _run(coordinates);
        if (run == null) return false;
        points.addAll(run);
        return true;
      case 'LineString':
        final run = _run(coordinates);
        if (run == null) return false;
        lines.add(run);
        return true;
      case 'MultiLineString':
        if (coordinates is! List) return false;
        for (final line in coordinates) {
          final run = _run(line);
          if (run == null) return false;
          lines.add(run);
        }
        return true;
      case 'Polygon':
        final rings = _rings(coordinates);
        if (rings == null) return false;
        polygons.add(rings);
        return true;
      case 'MultiPolygon':
        if (coordinates is! List) return false;
        for (final polygon in coordinates) {
          final rings = _rings(polygon);
          if (rings == null) return false;
          polygons.add(rings);
        }
        return true;
      default:
        return false;
    }
  }

  static List<double>? _position(Object? json) {
    if (json is! List || json.length < 2) return null;
    final lng = json[0];
    final lat = json[1];
    if (lng is! num || lat is! num) return null;
    return [lng.toDouble(), lat.toDouble()];
  }

  static Float64List? _run(Object? json) {
    if (json is! List) return null;
    final out = Float64List(json.length * 2);
    for (var i = 0; i < json.length; i++) {
      final p = _position(json[i]);
      if (p == null) return null;
      out[i * 2] = p[0];
      out[i * 2 + 1] = p[1];
    }
    return out;
  }

  static List<Float64List>? _rings(Object? json) {
    if (json is! List || json.isEmpty) return null;
    final rings = <Float64List>[];
    for (final ring in json) {
      final run = _run(ring);
      if (run == null) return null;
      rings.add(run);
    }
    return rings;
  }
}

// ---------------------------------------------------------------------------
// The feature side: tile-local runs split by geometry type.

/// [geometry]'s polygons: rings grouped under the exterior that
/// precedes them. The first ring's winding marks an exterior, as MVT
/// decoders read it; a later ring wound the same way starts the next
/// polygon.
List<List<Float32List>> _featurePolygons(List<Float32List> rings) {
  final polygons = <List<Float32List>>[];
  double? exteriorSign;
  for (final ring in rings) {
    final area = _signedArea(ring);
    if (area == 0) continue;
    exteriorSign ??= area.sign;
    if (area.sign == exteriorSign || polygons.isEmpty) {
      polygons.add([ring]);
    } else {
      polygons.last.add(ring);
    }
  }
  return polygons;
}

double _signedArea(Float32List ring) {
  var sum = 0.0;
  final n = ring.length ~/ 2;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    sum += ring[j * 2] * ring[i * 2 + 1] - ring[i * 2] * ring[j * 2 + 1];
  }
  return sum;
}

// ---------------------------------------------------------------------------
// within

/// Whether [geometry] lies inside [shapes]' polygons, as the `within`
/// operator defines it: every point strictly inside (one on a boundary
/// is not), every line inside one polygon without touching its
/// boundary. Polygon features are never within.
///
/// The test runs in Web Mercator, both sides snapped to the feature's
/// own grid (its tile extent at its zoom) — a polygon edge is straight
/// on the map, not in longitude/latitude.
bool featureWithin(FeatureGeometry geometry, GeoShapes shapes) {
  if (shapes.polygons.isEmpty) return false;
  final grid = geometry.extent * math.pow(2, geometry.z).toDouble();
  final ox = geometry.x * geometry.extent.toDouble();
  final oy = geometry.y * geometry.extent.toDouble();
  final polygons = [
    for (final polygon in shapes.polygons)
      [for (final ring in polygon) _toGrid(ring, grid)],
  ];
  final bounds = [for (final polygon in polygons) _bounds(polygon.first)];

  switch (geometry.type) {
    case 'Point':
      var any = false;
      for (final run in geometry.parts) {
        for (var i = 0; i + 1 < run.length; i += 2) {
          final x = _wrapInto(run[i] + ox, bounds, grid);
          final y = run[i + 1] + oy;
          if (!_pointInAny(x, y, polygons, bounds)) return false;
          any = true;
        }
      }
      return any;
    case 'LineString':
      var any = false;
      for (final run in geometry.parts) {
        if (run.length < 2) continue;
        final line = Float64List(run.length);
        // A line is shifted whole, by where its first vertex lands: a
        // line straddling the antimeridian is one line, not two.
        final shift = _wrapInto(run[0] + ox, bounds, grid) - (run[0] + ox);
        for (var i = 0; i + 1 < run.length; i += 2) {
          line[i] = run[i] + ox + shift;
          line[i + 1] = run[i + 1] + oy;
        }
        var inside = false;
        for (var p = 0; p < polygons.length && !inside; p++) {
          inside = _lineInPolygon(line, polygons[p], bounds[p]);
        }
        if (!inside) return false;
        any = true;
      }
      return any;
    default:
      return false;
  }
}

/// [ring] (lng, lat) as Web Mercator coordinates on a grid of [grid]
/// cells per world side, rounded to whole cells.
Float64List _toGrid(Float64List ring, double grid) {
  final out = Float64List(ring.length);
  for (var i = 0; i + 1 < ring.length; i += 2) {
    out[i] = (_mercatorX(ring[i]) * grid).roundToDouble();
    out[i + 1] = (_mercatorY(ring[i + 1]) * grid).roundToDouble();
  }
  return out;
}

double _mercatorX(double lng) => (180 + lng) / 360;

double _mercatorY(double lat) {
  final clamped = lat.clamp(-85.051128779806604, 85.051128779806604);
  final sin = math.sin(clamped * math.pi / 180);
  return 0.5 - math.log((1 + sin) / (1 - sin)) / (4 * math.pi);
}

/// minX, minY, maxX, maxY of an interleaved run.
Float64List _bounds(Float64List ring) {
  final b = Float64List.fromList([
    double.infinity,
    double.infinity,
    double.negativeInfinity,
    double.negativeInfinity,
  ]);
  for (var i = 0; i + 1 < ring.length; i += 2) {
    b[0] = math.min(b[0], ring[i]);
    b[1] = math.min(b[1], ring[i + 1]);
    b[2] = math.max(b[2], ring[i]);
    b[3] = math.max(b[3], ring[i + 1]);
  }
  return b;
}

/// [x], when it lies outside the polygons' horizontal span, moved by one
/// world towards it if either edge of the span is more than half a
/// world away — so a polygon given past ±180° still catches features on
/// the other copy of the world.
double _wrapInto(double x, List<Float64List> bounds, double grid) {
  var minX = double.infinity;
  var maxX = double.negativeInfinity;
  for (final b in bounds) {
    minX = math.min(minX, b[0]);
    maxX = math.max(maxX, b[2]);
  }
  if (x >= minX && x <= maxX) return x;
  final half = grid / 2;
  if (x - minX > half) return x - grid;
  if (minX - x > half) return x + grid;
  if (x - maxX > half) return x - grid;
  if (maxX - x > half) return x + grid;
  return x;
}

bool _pointInAny(double x, double y, List<List<Float64List>> polygons,
    List<Float64List> bounds) {
  for (var p = 0; p < polygons.length; p++) {
    final b = bounds[p];
    if (x <= b[0] || x >= b[2] || y <= b[1] || y >= b[3]) continue;
    if (_pointInPolygon(x, y, polygons[p], strict: true)) return true;
  }
  return false;
}

/// Even-odd containment over the exterior and its holes. [strict]
/// rejects a point on any edge.
bool _pointInPolygon(double x, double y, List<Float64List> rings,
    {required bool strict}) {
  var inside = false;
  for (final ring in rings) {
    final n = ring.length ~/ 2;
    for (var i = 0, j = n - 1; i < n; j = i++) {
      final xi = ring[i * 2], yi = ring[i * 2 + 1];
      final xj = ring[j * 2], yj = ring[j * 2 + 1];
      if (_onSegment(x, y, xi, yi, xj, yj)) return !strict;
      if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
  }
  return inside;
}

bool _onSegment(
    double px, double py, double ax, double ay, double bx, double by) {
  final cross = (px - ax) * (by - ay) - (py - ay) * (bx - ax);
  if (cross != 0) return false;
  return px >= math.min(ax, bx) &&
      px <= math.max(ax, bx) &&
      py >= math.min(ay, by) &&
      py <= math.max(ay, by);
}

bool _lineInPolygon(
    Float64List line, List<Float64List> polygon, Float64List bounds) {
  for (var i = 0; i + 1 < line.length; i += 2) {
    final x = line[i], y = line[i + 1];
    if (x <= bounds[0] || x >= bounds[2] || y <= bounds[1] || y >= bounds[3]) {
      return false;
    }
    if (!_pointInPolygon(x, y, polygon, strict: true)) return false;
  }
  for (var i = 0; i + 3 < line.length; i += 2) {
    for (final ring in polygon) {
      if (_segmentCrossesRing(
          line[i], line[i + 1], line[i + 2], line[i + 3], ring)) {
        return false;
      }
    }
  }
  return true;
}

bool _segmentCrossesRing(
    double ax, double ay, double bx, double by, Float64List ring) {
  final n = ring.length ~/ 2;
  for (var i = 0, j = n - 1; i < n; j = i++) {
    if (_segmentsIntersect(ax, ay, bx, by, ring[j * 2], ring[j * 2 + 1],
        ring[i * 2], ring[i * 2 + 1])) {
      return true;
    }
  }
  return false;
}

/// Whether segments a–b and c–d share a point, touching included.
bool _segmentsIntersect(double ax, double ay, double bx, double by, double cx,
    double cy, double dx, double dy) {
  final d1 = _orient(cx, cy, dx, dy, ax, ay);
  final d2 = _orient(cx, cy, dx, dy, bx, by);
  final d3 = _orient(ax, ay, bx, by, cx, cy);
  final d4 = _orient(ax, ay, bx, by, dx, dy);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return true;
  }
  return (d1 == 0 && _onSegment(ax, ay, cx, cy, dx, dy)) ||
      (d2 == 0 && _onSegment(bx, by, cx, cy, dx, dy)) ||
      (d3 == 0 && _onSegment(cx, cy, ax, ay, bx, by)) ||
      (d4 == 0 && _onSegment(dx, dy, ax, ay, bx, by));
}

double _orient(
        double ax, double ay, double bx, double by, double cx, double cy) =>
    (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);

// ---------------------------------------------------------------------------
// distance

/// The shortest distance in metres between [geometry] and [shapes], 0
/// where they overlap; null for a feature without coordinates.
///
/// Measured on a local flat approximation of the WGS84 ellipsoid around
/// the feature's first coordinate — east-west and north-south metres
/// per degree from the ellipsoid's radii of curvature at that latitude
/// — the same model MapLibre measures `distance` with, accurate to well
/// under a percent over the few hundred kilometres a map label cares
/// about.
double? featureDistance(FeatureGeometry geometry, GeoShapes shapes) {
  final n = 1 << geometry.z;
  final extent = geometry.extent.toDouble();
  List<double> lngLat(double px, double py) {
    final wx = (geometry.x + px / extent) / n;
    final wy = (geometry.y + py / extent) / n;
    final lat = math.atan(_sinh(math.pi * (1 - 2 * wy))) * 180 / math.pi;
    return [wx * 360 - 180, lat];
  }

  // The feature in longitude/latitude, by type.
  final runs = <Float64List>[];
  for (final part in geometry.parts) {
    final run = Float64List(part.length);
    for (var i = 0; i + 1 < part.length; i += 2) {
      final p = lngLat(part[i], part[i + 1]);
      run[i] = p[0];
      run[i + 1] = p[1];
    }
    if (run.isNotEmpty) runs.add(run);
  }
  if (runs.isEmpty) return null;

  final plane = _Plane(runs.first[0], runs.first[1]);
  final source = switch (geometry.type) {
    'Point' => _Shape.points(plane.run(_concat(runs))),
    'LineString' => _Shape(lines: [for (final r in runs) plane.run(r)]),
    _ => _Shape(polygons: [
        for (final polygon in _featurePolygons(geometry.parts))
          [
            for (final ring in polygon) plane.run(_lngLatRun(ring, lngLat)),
          ],
      ]),
  };
  if (source.isEmpty) return null;
  final target = _Shape(
    points: plane.run(shapes.points),
    lines: [for (final line in shapes.lines) plane.run(line)],
    polygons: [
      for (final polygon in shapes.polygons)
        [for (final ring in polygon) plane.run(ring)],
    ],
  );
  return source.distanceTo(target);
}

Float64List _concat(List<Float64List> runs) {
  final out = Float64List(runs.fold(0, (n, r) => n + r.length));
  var o = 0;
  for (final r in runs) {
    out.setAll(o, r);
    o += r.length;
  }
  return out;
}

Float64List _lngLatRun(
    Float32List ring, List<double> Function(double, double) lngLat) {
  final out = Float64List(ring.length);
  for (var i = 0; i + 1 < ring.length; i += 2) {
    final p = lngLat(ring[i], ring[i + 1]);
    out[i] = p[0];
    out[i + 1] = p[1];
  }
  return out;
}

double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;

/// Longitude/latitude around a reference point as metres east and north
/// of it.
final class _Plane {
  final double lng0, lat0, kx, ky;

  factory _Plane(double lng0, double lat0) {
    // WGS84: equatorial radius (m) and flattening.
    const a = 6378137.0;
    const f = 1 / 298.257223563;
    const e2 = f * (2 - f);
    const rad = math.pi / 180;
    final cos = math.cos(lat0 * rad);
    final w2 = 1 / (1 - e2 * (1 - cos * cos));
    final w = math.sqrt(w2);
    // Prime vertical (east-west) and meridional (north-south) radii of
    // curvature, as metres per degree.
    return _Plane._(lng0, lat0, rad * a * w * cos, rad * a * w * w2 * (1 - e2));
  }

  _Plane._(this.lng0, this.lat0, this.kx, this.ky);

  Float64List run(Float64List lngLat) {
    final out = Float64List(lngLat.length);
    for (var i = 0; i + 1 < lngLat.length; i += 2) {
      var dLng = lngLat[i] - lng0;
      while (dLng < -180) {
        dLng += 360;
      }
      while (dLng > 180) {
        dLng -= 360;
      }
      out[i] = dLng * kx;
      out[i + 1] = (lngLat[i + 1] - lat0) * ky;
    }
    return out;
  }
}

/// A geometry on the plane: a point set, polylines and polygons.
final class _Shape {
  final Float64List points;
  final List<Float64List> lines;
  final List<List<Float64List>> polygons;

  _Shape({
    Float64List? points,
    this.lines = const [],
    this.polygons = const [],
  }) : points = points ?? Float64List(0);

  _Shape.points(Float64List points) : this(points: points);

  bool get isEmpty => points.isEmpty && lines.isEmpty && polygons.isEmpty;

  /// Every segment of the lines and polygon rings, and every point as a
  /// zero-length segment, as one list of x1, y1, x2, y2 quadruples.
  Float64List _segments() {
    final out = <double>[];
    for (var i = 0; i + 1 < points.length; i += 2) {
      out.addAll([points[i], points[i + 1], points[i], points[i + 1]]);
    }
    void addRun(Float64List run, {required bool closed}) {
      if (run.length == 2) {
        out.addAll([run[0], run[1], run[0], run[1]]);
        return;
      }
      for (var i = 0; i + 3 < run.length; i += 2) {
        out.addAll([run[i], run[i + 1], run[i + 2], run[i + 3]]);
      }
      if (closed && run.length >= 4) {
        final n = run.length;
        out.addAll([run[n - 2], run[n - 1], run[0], run[1]]);
      }
    }

    for (final line in lines) {
      addRun(line, closed: false);
    }
    for (final polygon in polygons) {
      for (final ring in polygon) {
        addRun(ring, closed: true);
      }
    }
    return Float64List.fromList(out);
  }

  /// Whether any vertex of [other] lies in one of this shape's polygons.
  bool _covers(_Shape other) {
    if (polygons.isEmpty) return false;
    bool inAny(double x, double y) {
      for (final polygon in polygons) {
        if (_pointInPolygon(x, y, polygon, strict: false)) return true;
      }
      return false;
    }

    for (var i = 0; i + 1 < other.points.length; i += 2) {
      if (inAny(other.points[i], other.points[i + 1])) return true;
    }
    for (final run in [
      ...other.lines,
      for (final polygon in other.polygons) ...polygon,
    ]) {
      for (var i = 0; i + 1 < run.length; i += 2) {
        if (inAny(run[i], run[i + 1])) return true;
      }
    }
    return false;
  }

  double distanceTo(_Shape other) {
    if (_covers(other) || other._covers(this)) return 0;
    final a = _segments();
    final b = other._segments();
    var best = double.infinity;
    for (var i = 0; i + 3 < a.length; i += 4) {
      for (var j = 0; j + 3 < b.length; j += 4) {
        final d = _segmentDistance(a[i], a[i + 1], a[i + 2], a[i + 3], b[j],
            b[j + 1], b[j + 2], b[j + 3]);
        if (d < best) {
          best = d;
          if (best == 0) return 0;
        }
      }
    }
    return best;
  }
}

double _segmentDistance(double ax, double ay, double bx, double by, double cx,
    double cy, double dx, double dy) {
  if (_segmentsIntersect(ax, ay, bx, by, cx, cy, dx, dy)) return 0;
  return math.min(
    math.min(_pointSegment(ax, ay, cx, cy, dx, dy),
        _pointSegment(bx, by, cx, cy, dx, dy)),
    math.min(_pointSegment(cx, cy, ax, ay, bx, by),
        _pointSegment(dx, dy, ax, ay, bx, by)),
  );
}

double _pointSegment(
    double px, double py, double ax, double ay, double bx, double by) {
  final vx = bx - ax, vy = by - ay;
  final len2 = vx * vx + vy * vy;
  var t = len2 == 0 ? 0.0 : ((px - ax) * vx + (py - ay) * vy) / len2;
  t = t.clamp(0.0, 1.0);
  final x = ax + vx * t - px, y = ay + vy * t - py;
  return math.sqrt(x * x + y * y);
}
