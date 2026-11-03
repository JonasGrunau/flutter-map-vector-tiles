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

  const ExtrusionMesh({
    required this.feature,
    required this.bounds,
    required this.vertexStart,
    required this.xy,
    required this.roofStart,
    required this.roof,
    required this.wallStart,
    required this.walls,
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
      }
    }
    if (_roof.length == roofBefore && _walls.length == wallsBefore) return;
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

  ExtrusionMesh build() => ExtrusionMesh(
        feature: _feature.toInt32List(),
        bounds: _bounds.toFloat32List(),
        vertexStart: _vertexStart.toInt32List(),
        xy: _xy.toFloat32List(),
        roofStart: _roofStart.toInt32List(),
        roof: _roof.toUint16List(),
        wallStart: _wallStart.toInt32List(),
        walls: _walls.toUint16List(),
      );
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
