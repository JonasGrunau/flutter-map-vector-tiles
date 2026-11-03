import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../grid/grid_layout.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import 'extrusion_layouter.dart';

/// Draws `fill-extrusion` layers as 3D buildings, the way MapLibre GL
/// draws them with the camera looking straight down (pitch 0): through a
/// perspective camera, so a building's roof sits further from the screen
/// centre than its foot, and its walls show on the side facing the
/// centre — more of them towards the screen edges.
///
/// The lean changes with every pan and zoom, so the buildings cannot be
/// baked into the tile rasters: every frame writes them into vertex
/// buffers and draws them over the tiles, in the canvas space the tiles
/// are drawn in (rotated world pixels, origin at the screen centre),
/// where a point at altitude z simply scales by `D / (D - z·ppm)` about
/// the origin. Painter's order stands in for a depth buffer: buildings
/// are drawn from the lowest roof to the tallest, each one's walls
/// before its roof.
class ExtrusionPainter {
  /// Frames painted and the UI-thread time they took, and the vertices
  /// they drew. For tests and benchmarks.
  static int debugFrames = 0;
  static int debugMicros = 0;
  static int debugVertices = 0;

  /// MapLibre's camera: a 36.87° vertical field of view puts the camera
  /// 1.5 viewport heights above the map.
  static const double cameraDistance = 1.5;

  static const double _earthRadius = 6371008.8;

  /// The most vertices one draw call takes: `Vertices` indices are
  /// 16-bit.
  static const int _maxVertices = 65535;

  /// Walls leaning less than this many logical pixels are not drawn.
  static const double minWallLean = 0.5;

  int? _generation;
  List<_LayerOrder> _orders = const [];

  final _paint = Paint();
  final _positions = Float32List(_maxVertices * 2);
  final _colors = Int32List(_maxVertices);
  var _indices = Uint16List(1 << 18);
  var _vertexCount = 0;
  var _indexCount = 0;

  void reset() {
    _generation = null;
    _orders = const [];
  }

  void paint(
    Canvas canvas, {
    required int generation,
    required Iterable<ExtrusionLayout> Function() layouts,
    required double cameraZoom,
    required double styleZoom,
    required Offset worldCenter,
    required double latitude,
    required Size viewport,
    required double rotation,
  }) {
    if (_generation != generation) {
      _generation = generation;
      _orders = _order(layouts());
    }
    if (_orders.isEmpty) return;
    final stopwatch = Stopwatch()..start();
    developer.Timeline.startSync('VT extrusion');

    final d = cameraDistance * viewport.height;
    final ppm = 256 *
        math.pow(2.0, cameraZoom) /
        (2 * math.pi * _earthRadius * math.cos(latitude * math.pi / 180));
    // MapLibre's near plane sits a fiftieth of the viewport height in
    // front of the camera: nothing gets closer.
    final maxLift = d - viewport.height / 50;
    final cosR = math.cos(rotation).abs(), sinR = math.sin(rotation).abs();
    final hx = cosR * viewport.width / 2 + sinR * viewport.height / 2;
    final hy = sinR * viewport.width / 2 + cosR * viewport.height / 2;
    final zoomCtx = EvalContext(zoom: styleZoom);

    for (final order in _orders) {
      final layer = order.layer;
      if (!layer.coversZoom(styleZoom)) continue;
      final opacity = layer.opacity.eval(zoomCtx).clamp(0.0, 1.0);
      if (opacity == 0) continue;
      final layouts = order.layouts;
      final tx = order.tx, ty = order.ty, ts = order.scale;
      for (var i = 0; i < layouts.length; i++) {
        final layout = layouts[i];
        final rect = displayTileRect(layout.tile, cameraZoom);
        tx[i] = rect.left - worldCenter.dx;
        ty[i] = rect.top - worldCenter.dy;
        ts[i] = rect.width / layout.extent;
      }
      if (opacity < 1) {
        canvas.saveLayer(
            null, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
      }
      _drawLayer(canvas, order, d, ppm, maxLift, hx, hy);
      if (opacity < 1) canvas.restore();
    }

    developer.Timeline.finishSync();
    debugFrames++;
    debugMicros += stopwatch.elapsedMicroseconds;
  }

  void _drawLayer(Canvas canvas, _LayerOrder order, double d, double ppm,
      double maxLift, double hx, double hy) {
    final layouts = order.layouts;
    final tx = order.tx, ty = order.ty, ts = order.scale;
    final entryLayout = order.layout, entryBuilding = order.building;
    final pos = _positions;
    final col = _colors;
    var idx = _indices;
    _vertexCount = 0;
    _indexCount = 0;

    for (var e = 0; e < entryLayout.length; e++) {
      final li = entryLayout[e];
      final bi = entryBuilding[e];
      final layout = layouts[li];
      final x0 = tx[li], y0 = ty[li], s = ts[li];
      final bounds = layout.bounds;
      final fx0 = x0 + bounds[bi * 4] * s;
      final fy0 = y0 + bounds[bi * 4 + 1] * s;
      final fx1 = x0 + bounds[bi * 4 + 2] * s;
      final fy1 = y0 + bounds[bi * 4 + 3] * s;
      var lift = layout.heights[bi] * ppm;
      if (lift > maxLift) lift = maxLift;
      final kt = d / (d - lift);
      var baseLift = layout.bases[bi] * ppm;
      if (baseLift > maxLift) baseLift = maxLift;
      final kb = d / (d - baseLift);
      // The foot and the roof, scaled about the origin, bound it all.
      final minX = fx0 < fx0 * kt ? fx0 : fx0 * kt;
      final maxX = fx1 > fx1 * kt ? fx1 : fx1 * kt;
      final minY = fy0 < fy0 * kt ? fy0 : fy0 * kt;
      final maxY = fy1 > fy1 * kt ? fy1 : fy1 * kt;
      if (maxX < -hx || minX > hx || maxY < -hy || minY > hy) continue;

      final mesh = layout.mesh;
      final b = layout.buildings[bi];
      final v0 = mesh.vertexStart[b];
      final vn = mesh.vertexStart[b + 1] - v0;
      final r0 = mesh.roofStart[b], r1 = mesh.roofStart[b + 1];
      final w0 = mesh.wallStart[b];
      var w1 = mesh.wallStart[b + 1];
      // Walls leaning under [minWallLean] at the building's furthest
      // corner are left out: they would not cover a pixel.
      final reach = (fx0.abs() > fx1.abs() ? fx0.abs() : fx1.abs()) +
          (fy0.abs() > fy1.abs() ? fy0.abs() : fy1.abs());
      if (reach * (kt - kb) < minWallLean) w1 = w0;
      final wallCount = (w1 - w0) >> 1;

      final needVertices = vn + wallCount * 4;
      final needIndices = (r1 - r0) + wallCount * 6;
      if (_vertexCount + needVertices > _maxVertices) {
        _flush(canvas);
      }
      if (_indexCount + needIndices > idx.length) {
        idx = _indices =
            Uint16List(math.max(idx.length * 2, _indexCount + needIndices))
              ..setRange(0, _indexCount, idx);
      }

      final xy = mesh.xy;
      final roofColor = layout.colors[bi];
      final wallColor = _shade(roofColor, 0.8);

      // Walls first: the roof covers whatever of them lies beneath it.
      if (wallCount > 0) {
        final walls = mesh.walls;
        for (var w = w0; w < w1; w += 2) {
          final a = (v0 + walls[w]) * 2;
          final c = (v0 + walls[w + 1]) * 2;
          final ax = x0 + xy[a] * s, ay = y0 + xy[a + 1] * s;
          final cx = x0 + xy[c] * s, cy = y0 + xy[c + 1] * s;
          // Outward normal (dy, -dx): a wall shows only facing the
          // screen centre, the camera's foot.
          if ((cy - ay) * ax + (ax - cx) * ay >= 0) continue;
          final v = _vertexCount;
          final o = v * 2;
          pos[o] = ax * kb;
          pos[o + 1] = ay * kb;
          pos[o + 2] = cx * kb;
          pos[o + 3] = cy * kb;
          pos[o + 4] = cx * kt;
          pos[o + 5] = cy * kt;
          pos[o + 6] = ax * kt;
          pos[o + 7] = ay * kt;
          col[v] = wallColor;
          col[v + 1] = wallColor;
          col[v + 2] = wallColor;
          col[v + 3] = wallColor;
          final k = _indexCount;
          idx[k] = v;
          idx[k + 1] = v + 1;
          idx[k + 2] = v + 2;
          idx[k + 3] = v;
          idx[k + 4] = v + 2;
          idx[k + 5] = v + 3;
          _indexCount = k + 6;
          _vertexCount = v + 4;
        }
      }

      // The roof.
      final ax = x0 * kt, ay = y0 * kt, as = s * kt;
      final base = _vertexCount;
      var o = base * 2;
      var p = v0 * 2;
      for (var v = 0; v < vn; v++) {
        pos[o] = ax + xy[p] * as;
        pos[o + 1] = ay + xy[p + 1] * as;
        col[base + v] = roofColor;
        o += 2;
        p += 2;
      }
      _vertexCount = base + vn;
      final roof = mesh.roof;
      var k = _indexCount;
      for (var r = r0; r < r1; r++) {
        idx[k++] = base + roof[r];
      }
      _indexCount = k;
    }
    _flush(canvas);
  }

  void _flush(Canvas canvas) {
    if (_indexCount == 0) {
      _vertexCount = 0;
      return;
    }
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_positions, 0, _vertexCount * 2),
      colors: Int32List.sublistView(_colors, 0, _vertexCount),
      indices: Uint16List.sublistView(_indices, 0, _indexCount),
    );
    canvas.drawVertices(vertices, BlendMode.dst, _paint);
    vertices.dispose();
    debugVertices += _vertexCount;
    _vertexCount = 0;
    _indexCount = 0;
  }

  static int _shade(int argb, double f) {
    final r = (((argb >> 16) & 0xff) * f).round();
    final g = (((argb >> 8) & 0xff) * f).round();
    final b = ((argb & 0xff) * f).round();
    return (0xff << 24) | (r << 16) | (g << 8) | b;
  }

  /// Every building of [layouts], per layer in theme order, lowest roof
  /// first.
  static List<_LayerOrder> _order(Iterable<ExtrusionLayout> layouts) {
    final byLayer = <FillThemeLayer, List<ExtrusionLayout>>{};
    for (final layout in layouts) {
      (byLayer[layout.layer] ??= []).add(layout);
    }
    return [
      for (final entry in byLayer.entries)
        _LayerOrder.sorted(entry.key, entry.value),
    ];
  }
}

/// One layer's buildings across all tiles, in drawing order.
class _LayerOrder {
  final FillThemeLayer layer;
  final List<ExtrusionLayout> layouts;

  /// Per entry, the layout and the building within it.
  final Int32List layout;
  final Int32List building;

  /// Per layout, scratch for the frame's tile transform.
  final Float64List tx, ty, scale;

  _LayerOrder._(this.layer, this.layouts, this.layout, this.building)
      : tx = Float64List(layouts.length),
        ty = Float64List(layouts.length),
        scale = Float64List(layouts.length);

  /// A counting sort on the roof height in decimetres: linear in the
  /// buildings, and stable, so equal heights keep tile order.
  factory _LayerOrder.sorted(
      FillThemeLayer layer, List<ExtrusionLayout> layouts) {
    var total = 0;
    for (final layout in layouts) {
      total += layout.length;
    }
    const buckets = 1 << 16;
    final counts = Int32List(buckets + 1);
    int keyOf(double height) {
      final key = (height * 10).round();
      return key < 0 ? 0 : (key >= buckets ? buckets - 1 : key);
    }

    for (final layout in layouts) {
      final heights = layout.heights;
      for (var i = 0; i < heights.length; i++) {
        counts[keyOf(heights[i]) + 1]++;
      }
    }
    for (var i = 1; i <= buckets; i++) {
      counts[i] += counts[i - 1];
    }
    final layoutOf = Int32List(total);
    final buildingOf = Int32List(total);
    for (var l = 0; l < layouts.length; l++) {
      final heights = layouts[l].heights;
      for (var i = 0; i < heights.length; i++) {
        final slot = counts[keyOf(heights[i])]++;
        layoutOf[slot] = l;
        buildingOf[slot] = i;
      }
    }
    return _LayerOrder._(layer, layouts, layoutOf, buildingOf);
  }
}
