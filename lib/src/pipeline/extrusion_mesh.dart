import 'dart:math' as math;
import 'dart:typed_data';

import '../render/earcut.dart';

/// The polygons of one source layer as buildings to extrude: roofs cut
/// into triangles, and the ring edges that stand up as walls.
///
/// Built on the worker while a tile is prepared, for the source layers a
/// `fill-extrusion` layer reads, so the UI isolate never triangulates.
/// It is geometry only — which buildings a layer draws, how tall and in
/// what colour is decided on the UI isolate (`ExtrusionLayouter`) — so
/// one mesh serves every extrusion layer over the source layer, at every
/// zoom the data tile is shown at.
///
/// The unit is one *polygon* — an exterior ring and its holes — not one
/// feature: producers merge every building of a height into one
/// multipolygon (an OpenMapTiles z14 tile holds a few hundred building
/// features of ~80 vertices each), and a feature spanning the tile
/// could never be culled. All of a feature's polygons share its height.
/// Everything is in tile-extent units and isolate-transferable typed
/// lists.
class ExtrusionMesh {
  /// Per polygon, the index of its feature in the source layer's
  /// `features`. Ascending: a feature's polygons are consecutive.
  final Int32List feature;

  /// Per polygon, the bounds of its exterior ring: `minX, minY, maxX,
  /// maxY`.
  final Float32List bounds;

  /// Polygon p's vertices are `vertexStart[p] ..< vertexStart[p + 1]`,
  /// as x,y pairs in [xy]; one entry more than there are polygons.
  final Int32List vertexStart;
  final Float32List xy;

  /// Polygon p's roof triangles are `roofStart[p] ..< roofStart[p + 1]`
  /// in [roof]: vertex indices relative to `vertexStart[p]`, three per
  /// triangle.
  final Int32List roofStart;
  final Uint16List roof;

  /// Polygon p's walls are `wallStart[p] ..< wallStart[p + 1]` in
  /// [walls], two relative vertex indices per wall: the ring edge from
  /// the first to the second, in ring order (exterior rings clockwise on
  /// screen, holes counter-clockwise, so a wall's outward normal is
  /// `(dy, -dx)` in y-down terms). Edges on the tile's clip boundary have
  /// none: they are no wall of the building, only where the tile cut it
  /// (MapLibre's `isBoundaryEdge`).
  final Int32List wallStart;
  final Uint16List walls;

  /// Per wall, the direction of its outward normal in 256ths of a turn,
  /// clockwise from +x in y-down terms: what the wall's shading depends
  /// on, quantized so that a frame maps 256 directions to light levels
  /// instead of normalizing every wall's normal.
  final Uint8List wallAngle;

  /// Per wall, the other polygons standing right in front of it: those
  /// containing the point 1.5 units (of a 4096 extent) outside it. A
  /// wall whose front changes along it is split there, at a vertex
  /// appended to its polygon's that the roof does not use.
  /// Wall w's are `wallCovers[wallCoverStart[w] ..< wallCoverStart[w +
  /// 1]]` — a terraced neighbour sharing the wall, the outline a taller
  /// building part rises out of, a lower part in front of a taller one.
  /// Painter's order cannot hide the stretch of a wall inside such a
  /// building behind its roof, as a depth buffer would: the layout
  /// raises the wall's foot to that roof instead
  /// (`ExtrusionLayout.wallFloors`), and leaves it out when the roof is
  /// as high. Most walls face the street and have none.
  final Int32List wallCoverStart;
  final Uint16List wallCovers;

  const ExtrusionMesh({
    required this.feature,
    required this.bounds,
    required this.vertexStart,
    required this.xy,
    required this.roofStart,
    required this.roof,
    required this.wallStart,
    required this.walls,
    required this.wallAngle,
    required this.wallCoverStart,
    required this.wallCovers,
  });

  /// The number of polygons.
  int get length => feature.length;

  int get byteSize =>
      feature.lengthInBytes +
      bounds.lengthInBytes +
      vertexStart.lengthInBytes +
      xy.lengthInBytes +
      roofStart.lengthInBytes +
      roof.lengthInBytes +
      wallStart.lengthInBytes +
      walls.lengthInBytes +
      wallAngle.lengthInBytes +
      wallCoverStart.lengthInBytes +
      wallCovers.lengthInBytes +
      64;
}

/// Accumulates an [ExtrusionMesh] one polygon feature at a time.
class ExtrusionMeshBuilder {
  final int extent;

  ExtrusionMeshBuilder(this.extent);

  final _feature = _IntBuffer();
  final _bounds = _FloatBuffer();
  final _vertexStart = _IntBuffer()..add(0);
  final _xy = _FloatBuffer();
  final _roofStart = _IntBuffer()..add(0);
  final _roof = _IntBuffer();
  final _wallStart = _IntBuffer()..add(0);
  final _walls = _IntBuffer();
  final _wallAngle = _IntBuffer();

  // Scratch for the polygon being added, handed to earcut.
  var _coords = Float64List(256);
  var _coordCount = 0;
  final _holes = <int>[];
  final _triangles = <int>[];
  var _minX = 0.0, _minY = 0.0, _maxX = 0.0, _maxY = 0.0;

  /// The most vertices a polygon may have: its roof indices are 16-bit,
  /// and it must fit one draw call's vertex buffer.
  static const maxVertices = 65535;

  /// Adds feature [index], a polygon with [rings] whose shoelace areas
  /// are [areas] (positive for exterior rings): each exterior ring and
  /// the holes after it become one polygon of the mesh.
  void add(int index, List<Float32List> rings, Float64List areas) {
    _coordCount = 0;
    for (var r = 0; r < rings.length; r++) {
      final area = areas[r];
      if (area == 0) continue;
      final ring = rings[r];
      if (area > 0) {
        _finish(index);
        _holes.clear();
        _minX = _maxX = ring[0];
        _minY = _maxY = ring[1];
        for (var i = 2; i + 1 < ring.length; i += 2) {
          final x = ring[i], y = ring[i + 1];
          if (x < _minX) _minX = x;
          if (x > _maxX) _maxX = x;
          if (y < _minY) _minY = y;
          if (y > _maxY) _maxY = y;
        }
      } else if (_coordCount == 0) {
        continue; // a hole with no exterior
      }
      if ((_coordCount + ring.length) >> 1 > maxVertices) continue;
      if (area < 0) _holes.add(_coordCount >> 1);
      if (_coords.length < _coordCount + ring.length) {
        final grown = Float64List((_coordCount + ring.length) * 2);
        grown.setRange(0, _coordCount, _coords);
        _coords = grown;
      }
      _coords.setRange(_coordCount, _coordCount + ring.length, ring);
      _coordCount += ring.length;
    }
    _finish(index);
  }

  /// Turns the polygon in the scratch into a mesh entry of feature
  /// [index]: its vertices, its roof cut by earcut, its walls.
  void _finish(int index) {
    final coordCount = _coordCount;
    _coordCount = 0;
    if (coordCount < 6) return;
    final roofBefore = _roof.length;
    _triangles.clear();
    earcut(Float64List.sublistView(_coords, 0, coordCount), _holes, _triangles);
    for (final i in _triangles) {
      _roof.add(i);
    }
    final wallsBefore = _walls.length;
    final vertices = coordCount >> 1;
    for (var h = 0; h <= _holes.length; h++) {
      final start = h == 0 ? 0 : _holes[h - 1];
      final end = h == _holes.length ? vertices : _holes[h];
      final c = _coords;
      for (var k = start; k < end; k++) {
        final j = k + 1 == end ? start : k + 1;
        final x1 = c[2 * k], y1 = c[2 * k + 1];
        final x2 = c[2 * j], y2 = c[2 * j + 1];
        if (x1 == x2 && y1 == y2) continue;
        if (_isBoundaryEdge(x1, y1, x2, y2)) continue;
        _walls
          ..add(k)
          ..add(j);
        // The outward normal (dy, -dx).
        final turn = math.atan2(-(x2 - x1), y2 - y1) / (2 * math.pi);
        _wallAngle.add((turn * 256).round() & 255);
      }
    }
    if (_roof.length == roofBefore && _walls.length == wallsBefore) return;
    // (A polygon with walls but no roof keeps them: its roof is
    // degenerate, its walls are not.)
    for (var i = 0; i < coordCount; i++) {
      _xy.add(_coords[i]);
    }
    _feature.add(index);
    _bounds
      ..add(_minX)
      ..add(_minY)
      ..add(_maxX)
      ..add(_maxY);
    _vertexStart.add(_xy.length >> 1);
    _roofStart.add(_roof.length);
    _wallStart.add(_walls.length);
  }

  /// An edge along the tile's clip boundary, outside its extent: where
  /// the producer cut the polygon, not one of its walls.
  bool _isBoundaryEdge(double x1, double y1, double x2, double y2) =>
      (x1 == x2 && (x1 < 0 || x1 > extent)) ||
      (y1 == y2 && (y1 < 0 || y1 > extent));

  bool get isEmpty => _feature.length == 0;

  ExtrusionMesh build() {
    final bounds = _bounds.toFloat32List();
    final vertexStart = _vertexStart.toInt32List();
    final xy = _xy.toFloat32List();
    final roofStart = _roofStart.toInt32List();
    final roof = _roof.toUint16List();
    final wallStart = _wallStart.toInt32List();
    final walls = _walls.toUint16List();
    final wallAngle = _wallAngle.toUint8List();
    final polygons = wallStart.length - 1;
    // Polygon indices in the cover lists are 16-bit.
    if (polygons < 2 || polygons > 0xffff) {
      return ExtrusionMesh(
        feature: _feature.toInt32List(),
        bounds: bounds,
        vertexStart: vertexStart,
        xy: xy,
        roofStart: roofStart,
        roof: roof,
        wallStart: wallStart,
        walls: walls,
        wallAngle: wallAngle,
        wallCoverStart: Int32List((walls.length >> 1) + 1),
        wallCovers: Uint16List(0),
      );
    }
    final covers = _Covers(extent, bounds, vertexStart, xy, roofStart, roof);

    // Walls again, split where what stands in front of them changes —
    // the extra vertices appended to their polygon's, which the roof
    // triangles do not use — each with its covers.
    final outXy = _FloatBuffer();
    final outVertexStart = _IntBuffer()..add(0);
    final outWallStart = _IntBuffer()..add(0);
    final outWalls = _IntBuffer();
    final outAngle = _IntBuffer();
    final coverStart = _IntBuffer()..add(0);
    final coverList = _IntBuffer();
    final extra = <double>[];
    for (var p = 0; p < polygons; p++) {
      final v0 = vertexStart[p], vn = vertexStart[p + 1] - v0;
      extra.clear();
      for (var w = wallStart[p]; w < wallStart[p + 1]; w += 2) {
        final ra = walls[w], rb = walls[w + 1];
        final a = (v0 + ra) * 2, b = (v0 + rb) * 2;
        final ax = xy[a], ay = xy[a + 1], bx = xy[b], by = xy[b + 1];
        final angle = wallAngle[w >> 1];
        final cuts = covers.along(p, ax, ay, bx, by);
        // cuts: t values in (0, 1) where the cover changes, then the
        // cover of each piece.
        var from = ra;
        for (var k = 0; k <= cuts.splits.length; k++) {
          int to;
          if (k == cuts.splits.length) {
            to = rb;
          } else if (vn + (extra.length >> 1) < maxVertices) {
            final t = cuts.splits[k];
            extra
              ..add(ax + (bx - ax) * t)
              ..add(ay + (by - ay) * t);
            to = vn + (extra.length >> 1) - 1;
          } else {
            continue; // no room for a vertex: the piece runs on
          }
          outWalls
            ..add(from)
            ..add(to);
          outAngle.add(angle);
          for (final q in cuts.pieces[k]) {
            coverList.add(q);
          }
          coverStart.add(coverList.length);
          from = to;
        }
      }
      for (var i = v0 * 2; i < (v0 + vn) * 2; i++) {
        outXy.add(xy[i]);
      }
      for (final v in extra) {
        outXy.add(v);
      }
      outVertexStart.add(outXy.length >> 1);
      outWallStart.add(outWalls.length);
    }
    return ExtrusionMesh(
      feature: _feature.toInt32List(),
      bounds: bounds,
      vertexStart: outVertexStart.toInt32List(),
      xy: outXy.toFloat32List(),
      roofStart: roofStart,
      roof: roof,
      wallStart: outWallStart.toInt32List(),
      walls: outWalls.toUint16List(),
      wallAngle: outAngle.toUint8List(),
      wallCoverStart: coverStart.toInt32List(),
      wallCovers: coverList.toUint16List(),
    );
  }
}

/// Which polygons stand right in front of a wall, for
/// [ExtrusionMesh.wallCovers]: the ones whose roof triangles hold the
/// point [reach] outside it, looked up through a grid over the
/// polygons' bounds.
class _Covers {
  _Covers(int extent, this.bounds, this.vertexStart, this.xy, this.roofStart,
      this.roof)
      : origin = -extent / 2,
        cell = extent * 2 / side,
        reach = 1.5 * extent / 4096 {
    final polygons = bounds.length ~/ 4;
    final count = Int32List(side * side + 1);
    for (var pass = 0; pass < 2; pass++) {
      final fill = pass == 0 ? null : Int32List.fromList(_cellStart);
      for (var p = 0; p < polygons; p++) {
        for (var cy = _cellOf(bounds[p * 4 + 1]);
            cy <= _cellOf(bounds[p * 4 + 3]);
            cy++) {
          for (var cx = _cellOf(bounds[p * 4]);
              cx <= _cellOf(bounds[p * 4 + 2]);
              cx++) {
            if (fill == null) {
              count[cy * side + cx + 1]++;
            } else {
              _inCell[fill[cy * side + cx]++] = p;
            }
          }
        }
      }
      if (pass == 0) {
        for (var i = 1; i <= side * side; i++) {
          count[i] += count[i - 1];
        }
        _cellStart = count;
        _inCell = Int32List(count[side * side]);
      }
    }
  }

  /// 128 × 128 cells over the extent and half of it either side, where a
  /// tile's buffer lies.
  static const side = 128;
  final double origin, cell;

  /// How far outside a wall it looks: 1.5 units of a 4096 extent, about
  /// half a metre at z14 — past the unit-wide slivers loosely mapped
  /// neighbours leave between them, short of the 2–3 units between the
  /// stelae of Berlin's Holocaust memorial, which MapLibre draws with
  /// every wall. Measured against MapLibre's walls there.
  final double reach;
  final Float32List bounds;
  final Int32List vertexStart;
  final Float32List xy;
  final Int32List roofStart;
  final Uint16List roof;
  late Int32List _cellStart;
  late Int32List _inCell;

  /// A wall's samples are at most this many extent units apart.
  static const double spacing = 16;

  int _cellOf(double v) {
    final c = ((v - origin) / cell).floor();
    return c < 0 ? 0 : (c >= side ? side - 1 : c);
  }

  /// The polygons other than [p] holding (x, y), ascending.
  List<int> at(int p, double x, double y) {
    final c = _cellOf(y) * side + _cellOf(x);
    List<int>? found;
    for (var k = _cellStart[c]; k < _cellStart[c + 1]; k++) {
      final q = _inCell[k];
      if (q == p ||
          x < bounds[q * 4] ||
          x > bounds[q * 4 + 2] ||
          y < bounds[q * 4 + 1] ||
          y > bounds[q * 4 + 3]) {
        continue;
      }
      if (_holds(q, x, y)) (found ??= []).add(q);
    }
    if (found == null) return const [];
    return found..sort();
  }

  bool _holds(int p, double x, double y) {
    final v0 = vertexStart[p];
    for (var r = roofStart[p]; r < roofStart[p + 1]; r += 3) {
      final a = (v0 + roof[r]) * 2;
      final b = (v0 + roof[r + 1]) * 2;
      final c = (v0 + roof[r + 2]) * 2;
      final d1 = (xy[b] - xy[a]) * (y - xy[a + 1]) -
          (xy[b + 1] - xy[a + 1]) * (x - xy[a]);
      final d2 = (xy[c] - xy[b]) * (y - xy[b + 1]) -
          (xy[c + 1] - xy[b + 1]) * (x - xy[b]);
      final d3 = (xy[a] - xy[c]) * (y - xy[c + 1]) -
          (xy[a + 1] - xy[c + 1]) * (x - xy[c]);
      if ((d1 >= 0 && d2 >= 0 && d3 >= 0) || (d1 <= 0 && d2 <= 0 && d3 <= 0)) {
        return true;
      }
    }
    return false;
  }

  /// The covers along polygon [p]'s wall from (ax, ay) to (bx, by):
  /// where they change, as fractions of the wall, and the covers of each
  /// piece between — sampled every [spacing] units, each change pinned
  /// down to a unit by bisection.
  ({List<double> splits, List<List<int>> pieces}) along(
      int p, double ax, double ay, double bx, double by) {
    final dx = bx - ax, dy = by - ay;
    final length = math.sqrt(dx * dx + dy * dy);
    // [reach] outside, along the outward normal (dy, -dx).
    final ox = dy / length * reach, oy = -dx / length * reach;
    List<int> sample(double t) => at(p, ax + dx * t + ox, ay + dy * t + oy);
    final n = (length / spacing).ceil().clamp(1, 1 << 20);
    var current = sample(0.5 / n);
    if (n == 1) return (splits: const [], pieces: [current]);
    final splits = <double>[];
    final pieces = <List<int>>[current];
    for (var i = 1; i < n; i++) {
      final next = sample((i + 0.5) / n);
      if (_same(next, current)) continue;
      // The change lies between the two samples.
      var lo = (i - 0.5) / n, hi = (i + 0.5) / n;
      while ((hi - lo) * length > 1) {
        final mid = (lo + hi) / 2;
        if (_same(sample(mid), current)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      splits.add((lo + hi) / 2);
      pieces.add(next);
      current = next;
    }
    return (splits: splits, pieces: pieces);
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _IntBuffer {
  var _data = Int32List(64);
  var length = 0;

  void add(int value) {
    if (length == _data.length) {
      _data = Int32List(length * 2)..setRange(0, length, _data);
    }
    _data[length++] = value;
  }

  Int32List toInt32List() => Int32List.fromList(
      Int32List.sublistView(_data, 0, length)); // a trimmed copy

  Uint8List toUint8List() {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _data[i];
    }
    return out;
  }

  Uint16List toUint16List() {
    final out = Uint16List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _data[i];
    }
    return out;
  }
}

class _FloatBuffer {
  var _data = Float32List(256);
  var length = 0;

  void add(double value) {
    if (length == _data.length) {
      _data = Float32List(length * 2)..setRange(0, length, _data);
    }
    _data[length++] = value;
  }

  Float32List toFloat32List() =>
      Float32List.fromList(Float32List.sublistView(_data, 0, length));
}
