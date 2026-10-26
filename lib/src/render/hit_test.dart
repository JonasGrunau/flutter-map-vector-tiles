import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'symbol_layouter.dart';

/// The area a rendered-feature query covers: a point, or a convex
/// polygon — a screen rectangle, which turns into a rotated quad in a
/// tile's coordinates when the map is rotated. Every test here works in
/// whatever space the vertices are given in; the caller transforms the
/// query into the space of the geometry, once per tile, rather than the
/// geometry into the query's.
class HitArea {
  /// The vertices, in order around the polygon (either direction); a
  /// single vertex for a point.
  final List<Offset> points;

  late final Rect bounds = _boundsOf(points);

  HitArea(this.points) : assert(points.isNotEmpty);

  bool get isPoint => points.length == 1;

  /// This area with [transform] applied to every vertex.
  HitArea map(Offset Function(Offset) transform) =>
      HitArea([for (final p in points) transform(p)]);

  /// Whether [p] lies inside the polygon (never, for a point area).
  bool contains(Offset p) => points.length >= 3 && _insideConvex(points, p);

  /// The part of this area inside [rect], or null when none is. A
  /// point on the rectangle's edge counts as inside.
  HitArea? clipTo(Rect rect) {
    if (isPoint) {
      final p = points.first;
      return p.dx >= rect.left &&
              p.dx <= rect.right &&
              p.dy >= rect.top &&
              p.dy <= rect.bottom
          ? this
          : null;
    }
    if (bounds.left >= rect.left &&
        bounds.right <= rect.right &&
        bounds.top >= rect.top &&
        bounds.bottom <= rect.bottom) {
      return this;
    }
    // Sutherland–Hodgman against each edge; a convex polygon stays one.
    var poly = points;
    for (final (inside, cut)
        in <(bool Function(Offset), Offset Function(Offset, Offset))>[
      ((p) => p.dx >= rect.left, (a, b) => _atX(a, b, rect.left)),
      ((p) => p.dx <= rect.right, (a, b) => _atX(a, b, rect.right)),
      ((p) => p.dy >= rect.top, (a, b) => _atY(a, b, rect.top)),
      ((p) => p.dy <= rect.bottom, (a, b) => _atY(a, b, rect.bottom)),
    ]) {
      if (poly.isEmpty) return null;
      final next = <Offset>[];
      for (var i = 0; i < poly.length; i++) {
        final a = poly[i];
        final b = poly[(i + 1) % poly.length];
        final aIn = inside(a), bIn = inside(b);
        if (aIn) next.add(a);
        if (aIn != bIn) next.add(cut(a, b));
      }
      poly = next;
    }
    return poly.length < 3 ? null : HitArea(poly);
  }

  static Offset _atX(Offset a, Offset b, double x) =>
      Offset(x, a.dy + (b.dy - a.dy) * (x - a.dx) / (b.dx - a.dx));

  static Offset _atY(Offset a, Offset b, double y) =>
      Offset(a.dx + (b.dx - a.dx) * (y - a.dy) / (b.dy - a.dy), y);

  static Rect _boundsOf(List<Offset> points) {
    var minX = points.first.dx, maxX = minX;
    var minY = points.first.dy, maxY = minY;
    for (final p in points) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// The polygon's edges as segments; a point area is one degenerate
  /// segment, so distance tests treat both alike.
  Iterable<(Offset, Offset)> get _edges sync* {
    if (points.length == 1) {
      yield (points.first, points.first);
      return;
    }
    for (var i = 0; i < points.length; i++) {
      yield (points[i], points[(i + 1) % points.length]);
    }
  }

  /// Whether this area overlaps the polygon [rings] (interleaved x,y
  /// runs, closed implicitly), filled with the non-zero rule as the
  /// rasterizer fills it.
  bool hitsPolygon(List<Float32List> rings) {
    for (final p in points) {
      if (_windingNumber(rings, p.dx, p.dy) != 0) return true;
    }
    if (points.length < 3) return false;
    for (final ring in rings) {
      final n = ring.length ~/ 2;
      for (var i = 0; i < n; i++) {
        final a = Offset(ring[i * 2], ring[i * 2 + 1]);
        if (contains(a)) return true;
        final j = (i + 1) % n;
        final b = Offset(ring[j * 2], ring[j * 2 + 1]);
        for (final (c, d) in _edges) {
          if (_segmentsIntersect(a, b, c, d)) return true;
        }
      }
    }
    return false;
  }

  /// Whether this area comes within [halfWidth] of the polylines
  /// [runs] — a stroke of twice that width.
  bool hitsLine(List<Float32List> runs, double halfWidth,
      {bool close = false}) {
    final limit = halfWidth * halfWidth;
    for (final run in runs) {
      final n = run.length ~/ 2;
      if (n == 0) continue;
      if (n == 1) {
        if (_distanceSqTo(Offset(run[0], run[1])) <= limit) return true;
        continue;
      }
      final segments = close ? n : n - 1;
      for (var i = 0; i < segments; i++) {
        final j = (i + 1) % n;
        final a = Offset(run[i * 2], run[i * 2 + 1]);
        final b = Offset(run[j * 2], run[j * 2 + 1]);
        if (contains(a)) return true;
        for (final (c, d) in _edges) {
          if (_segmentDistanceSq(a, b, c, d) <= limit) return true;
        }
      }
    }
    return false;
  }

  /// Whether this area comes within [radius] of [center].
  bool hitsCircle(Offset center, double radius) =>
      contains(center) || _distanceSqTo(center) <= radius * radius;

  /// Whether this area overlaps the convex polygon [quad] — a label's
  /// box, separating-axis test.
  bool hitsConvex(List<Offset> quad) {
    if (points.length == 1) return _insideConvex(quad, points.first);
    return !_separated(points, quad) && !_separated(quad, points);
  }

  double _distanceSqTo(Offset p) {
    var best = double.infinity;
    for (final (a, b) in _edges) {
      best = math.min(best, _pointSegmentDistanceSq(p, a, b));
    }
    return best;
  }
}

/// A label or icon `LabelMode.tile` drew into a tile image, with the
/// convex quads it covers in tile pixels — kept with the tile, and with
/// it in the finished-tile cache, so the quads are packed: eight floats
/// (four x,y vertices) each.
class LabelHit {
  final SymbolInstance instance;
  final Float32List quads;

  LabelHit(this.instance, List<List<Offset>> quads)
      : quads = Float32List(quads.length * 8) {
    var i = 0;
    for (final quad in quads) {
      for (final p in quad) {
        this.quads[i++] = p.dx;
        this.quads[i++] = p.dy;
      }
    }
  }

  bool hits(HitArea area) {
    for (var q = 0; q + 7 < quads.length; q += 8) {
      if (area.hitsConvex([
        for (var v = 0; v < 8; v += 2) Offset(quads[q + v], quads[q + v + 1]),
      ])) {
        return true;
      }
    }
    return false;
  }
}

/// The corners of a [width]×[height] box centred on [center] and
/// rotated by [angle] radians about it.
List<Offset> rotatedBox(
    Offset center, double width, double height, double angle) {
  final c = math.cos(angle), s = math.sin(angle);
  final hw = width / 2, hh = height / 2;
  Offset corner(double x, double y) =>
      Offset(center.dx + x * c - y * s, center.dy + x * s + y * c);
  return [corner(-hw, -hh), corner(hw, -hh), corner(hw, hh), corner(-hw, hh)];
}

/// The corners of [rect] rotated by [angle] radians about [pivot].
List<Offset> rotatedRect(Rect rect, Offset pivot, double angle) {
  if (angle == 0) {
    return [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft];
  }
  final c = math.cos(angle), s = math.sin(angle);
  Offset turn(Offset p) {
    final d = p - pivot;
    return Offset(
        pivot.dx + d.dx * c - d.dy * s, pivot.dy + d.dx * s + d.dy * c);
  }

  return [
    turn(rect.topLeft),
    turn(rect.topRight),
    turn(rect.bottomRight),
    turn(rect.bottomLeft),
  ];
}

/// Non-zero winding number of [rings] around (x, y).
int _windingNumber(List<Float32List> rings, double x, double y) {
  var winding = 0;
  for (final ring in rings) {
    final n = ring.length ~/ 2;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final ax = ring[i * 2], ay = ring[i * 2 + 1];
      final bx = ring[j * 2], by = ring[j * 2 + 1];
      final side = (bx - ax) * (y - ay) - (x - ax) * (by - ay);
      if (ay <= y) {
        if (by > y && side > 0) winding++;
      } else if (by <= y && side < 0) {
        winding--;
      }
    }
  }
  return winding;
}

bool _insideConvex(List<Offset> polygon, Offset p) {
  var sign = 0;
  for (var i = 0; i < polygon.length; i++) {
    final a = polygon[i];
    final b = polygon[(i + 1) % polygon.length];
    final cross = (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx);
    if (cross == 0) continue;
    final s = cross > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

/// Whether one of [a]'s edge normals separates the convex polygons.
bool _separated(List<Offset> a, List<Offset> b) {
  for (var i = 0; i < a.length; i++) {
    final p = a[i], q = a[(i + 1) % a.length];
    final nx = q.dy - p.dy, ny = p.dx - q.dx;
    if (nx == 0 && ny == 0) continue;
    var minA = double.infinity, maxA = double.negativeInfinity;
    for (final v in a) {
      final d = v.dx * nx + v.dy * ny;
      minA = math.min(minA, d);
      maxA = math.max(maxA, d);
    }
    var minB = double.infinity, maxB = double.negativeInfinity;
    for (final v in b) {
      final d = v.dx * nx + v.dy * ny;
      minB = math.min(minB, d);
      maxB = math.max(maxB, d);
    }
    if (maxA < minB || maxB < minA) return true;
  }
  return false;
}

double _cross(Offset o, Offset a, Offset b) =>
    (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);

bool _onSegment(Offset a, Offset b, Offset p) =>
    math.min(a.dx, b.dx) <= p.dx &&
    p.dx <= math.max(a.dx, b.dx) &&
    math.min(a.dy, b.dy) <= p.dy &&
    p.dy <= math.max(a.dy, b.dy);

bool _segmentsIntersect(Offset a, Offset b, Offset c, Offset d) {
  final d1 = _cross(c, d, a);
  final d2 = _cross(c, d, b);
  final d3 = _cross(a, b, c);
  final d4 = _cross(a, b, d);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
    return true;
  }
  return (d1 == 0 && _onSegment(c, d, a)) ||
      (d2 == 0 && _onSegment(c, d, b)) ||
      (d3 == 0 && _onSegment(a, b, c)) ||
      (d4 == 0 && _onSegment(a, b, d));
}

double _pointSegmentDistanceSq(Offset p, Offset a, Offset b) {
  final dx = b.dx - a.dx, dy = b.dy - a.dy;
  final lengthSq = dx * dx + dy * dy;
  var t = lengthSq == 0
      ? 0.0
      : ((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / lengthSq;
  t = t.clamp(0.0, 1.0);
  final ex = a.dx + t * dx - p.dx, ey = a.dy + t * dy - p.dy;
  return ex * ex + ey * ey;
}

double _segmentDistanceSq(Offset a, Offset b, Offset c, Offset d) {
  if (_segmentsIntersect(a, b, c, d)) return 0;
  return math.min(
    math.min(
        _pointSegmentDistanceSq(a, c, d), _pointSegmentDistanceSq(b, c, d)),
    math.min(
        _pointSegmentDistanceSq(c, a, b), _pointSegmentDistanceSq(d, a, b)),
  );
}
