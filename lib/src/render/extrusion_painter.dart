import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../grid/grid_layout.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import 'extrusion_layouter.dart';
import 'extrusion_shading.dart';

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

  /// When set, every painted frame appends its UI-thread microseconds
  /// here. For benchmarks; null otherwise, so nothing accumulates.
  static List<int>? debugFrameLog;

  /// MapLibre's camera: a 36.87° vertical field of view puts the camera
  /// 1.5 viewport heights above the map.
  static const double cameraDistance = 1.5;

  static const double _earthRadius = 6371008.8;

  /// The most vertices one draw call takes: `Vertices` indices are
  /// 16-bit.
  static const int _maxVertices = 65535;

  /// Walls leaning less than this many logical pixels are not drawn.
  static const double minWallLean = 0.5;

  /// Logical pixels per metre on the ground at [latitude], with the
  /// camera at [cameraZoom] (flutter_map's: 256-pixel tiles).
  static double pixelsPerMetre(double cameraZoom, double latitude) =>
      256 *
      math.pow(2.0, cameraZoom) /
      (2 * math.pi * _earthRadius * math.cos(latitude * math.pi / 180));

  /// How much a point [lift] pixels above the ground (altitude times
  /// [pixelsPerMetre]) scales about the screen centre, for a viewport
  /// [height] pixels tall: `D / (D - lift)` with the camera `D` above the
  /// map, lifts past MapLibre's near plane held at it.
  static double scaleAt(double lift, double height) {
    final d = cameraDistance * height;
    final maxLift = d - height / 50;
    return d / (d - (lift > maxLift ? maxLift : lift));
  }

  int? _generation;
  List<_LayerOrder> _orders = const [];

  /// The light the colour tables were filled under, and the light and
  /// rotation [_levels] were worked out for.
  ExtrusionLight? _tableLight;
  ExtrusionLight? _levelsLight;
  double? _levelsRotation;

  /// Per wall direction, its light level this frame.
  final _levels = Uint8List(256);

  final _positions = Float32List(_maxVertices * 2);
  final _colors = Int32List(_maxVertices);
  var _indices = Uint16List(1 << 18);
  var _vertexCount = 0;
  var _indexCount = 0;

  /// Forgets the buildings and frees the last frame's vertices — for a
  /// theme or provider change, and the layer's dispose.
  void reset() {
    _disposeLast();
    _generation = null;
    _orders = const [];
    _tableLight = null;
    _levelsLight = null;
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
    StyleLight? light,
  }) {
    final stopwatch = Stopwatch()..start();
    if (_generation != generation) {
      _generation = generation;
      _disposeLast();
      _orders = _order(layouts());
      _tableLight = null;
    }
    if (_orders.isEmpty) return;
    final evaluated = ExtrusionLight.of(light, styleZoom);
    final frame = (
      zoom: cameraZoom,
      styleZoom: styleZoom,
      center: worldCenter,
      latitude: latitude,
      viewport: viewport,
      rotation: rotation,
      light: evaluated,
    );
    if (frame == _lastFrame) {
      // Nothing that moves a vertex changed — a label fade, a tile
      // fading in: draw what the last frame built.
      for (final order in _orders) {
        order.redraw(canvas);
      }
      _count(stopwatch);
      return;
    }
    _disposeLast();
    _lastFrame = frame;
    if (evaluated != _tableLight) {
      _tableLight = evaluated;
      for (final order in _orders) {
        order.fillTables(evaluated);
      }
    }
    if (evaluated != _levelsLight || rotation != _levelsRotation) {
      _levelsLight = evaluated;
      _levelsRotation = rotation;
      ExtrusionShading.levelsOf(evaluated, rotation, _levels);
    }
    developer.Timeline.startSync('VT extrusion');

    final d = cameraDistance * viewport.height;
    final ppm = pixelsPerMetre(cameraZoom, latitude);
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
      order.cull(cameraZoom, worldCenter, hx, hy);
      order.opacity = opacity;
      _drawLayer(order, d, ppm, maxLift, hx, hy);
      order.redraw(canvas);
    }

    developer.Timeline.finishSync();
    _count(stopwatch);
  }

  void _count(Stopwatch stopwatch) {
    final micros = stopwatch.elapsedMicroseconds;
    debugFrames++;
    debugMicros += micros;
    debugFrameLog?.add(micros);
  }

  /// What the last built frame was built for.
  ({
    double zoom,
    double styleZoom,
    Offset center,
    double latitude,
    Size viewport,
    double rotation,
    ExtrusionLight light,
  })? _lastFrame;

  void _disposeLast() {
    _lastFrame = null;
    for (final order in _orders) {
      order.disposeVertices();
    }
  }

  /// Walls whose top leans less than this many logical pixels away from
  /// their foot share their corners with the walls beside them: two
  /// vertices a wall instead of four, the price being that a wall's
  /// colour runs into its neighbour's instead of changing at the corner
  /// — invisible on a sliver.
  static const double _shareCornersBelow = 3;

  void _drawLayer(_LayerOrder order, double d, double ppm, double maxLift,
      double hx, double hy) {
    final layouts = order.layouts;
    final tables = order.tables;
    final levels = _levels;
    final tx = order.tx, ty = order.ty, ts = order.scale;
    final entryLayout = order.layout, entryBuilding = order.building;
    final candidates = order.candidates;
    final pos = _positions;
    final col = _colors;
    var idx = _indices;
    _vertexCount = 0;
    _indexCount = 0;

    for (var c = 0; c < order.candidateCount; c++) {
      final e = candidates[c];
      final li = entryLayout[e];
      final bi = entryBuilding[e];
      final layout = layouts[li];
      final x0 = tx[li], y0 = ty[li], s = ts[li];
      final bounds = layout.bounds;
      final fx0 = x0 + bounds[bi * 4] * s;
      final fx1 = x0 + bounds[bi * 4 + 2] * s;
      if (fx1 < -hx || fx0 > hx) continue;
      final fy0 = y0 + bounds[bi * 4 + 1] * s;
      final fy1 = y0 + bounds[bi * 4 + 3] * s;
      // Leaning is away from the centre: a footprint past an edge of
      // the viewport leans further past it.
      if (fy1 < -hy || fy0 > hy) continue;
      var lift = layout.heights[bi] * ppm;
      if (lift > maxLift) lift = maxLift;
      final kt = d / (d - lift);
      var baseLift = layout.bases[bi] * ppm;
      if (baseLift > maxLift) baseLift = maxLift;
      final kb = d / (d - baseLift);

      final mesh = layout.mesh;
      final b = layout.buildings[bi];
      final v0 = mesh.vertexStart[b];
      final vn = mesh.vertexStart[b + 1] - v0;
      final r0 = mesh.roofStart[b], r1 = mesh.roofStart[b + 1];
      final w0 = mesh.wallStart[b];
      var w1 = mesh.wallStart[b + 1];
      // How far the building's furthest corner leans: walls leaning
      // under [minWallLean] are left out, they would not cover a pixel.
      final rx = fx0.abs() > fx1.abs() ? fx0 : fx1;
      final ry = fy0.abs() > fy1.abs() ? fy0 : fy1;
      final lean = math.sqrt(rx * rx + ry * ry) * (kt - kb);
      if (lean < minWallLean) w1 = w0;
      final wallCount = (w1 - w0) >> 1;

      final needVertices = vn + wallCount * 4;
      final needIndices = (r1 - r0) + wallCount * 6;
      if (_vertexCount + needVertices > _maxVertices) {
        order.add(_build());
      }
      if (_indexCount + needIndices > idx.length) {
        idx = _indices =
            Uint16List(math.max(idx.length * 2, _indexCount + needIndices))
              ..setRange(0, _indexCount, idx);
      }

      final xy = mesh.xy;
      final table = tables[li];
      final colorAt = layout.classOf[bi] * ExtrusionShading.stride;

      // Walls first: the roof covers whatever of them lies beneath it.
      if (wallCount > 0) {
        final walls = mesh.walls;
        final angles = mesh.wallAngle;
        const top = 1 + ExtrusionShading.levels;
        final share = lean < _shareCornersBelow;
        // The relative vertex the last wall drawn ended on, while its
        // corner can be shared.
        var openEnd = -1;
        var v = _vertexCount;
        var k = _indexCount;
        for (var w = w0; w < w1; w += 2) {
          final ra = walls[w], rc = walls[w + 1];
          final a = (v0 + ra) * 2;
          final c = (v0 + rc) * 2;
          final ax = x0 + xy[a] * s, ay = y0 + xy[a + 1] * s;
          final cx = x0 + xy[c] * s, cy = y0 + xy[c + 1] * s;
          // Outward normal (dy, -dx): a wall shows only facing the
          // screen centre, the camera's foot.
          if ((cy - ay) * ax + (ax - cx) * ay >= 0) {
            openEnd = -1;
            continue;
          }
          final level = colorAt + levels[angles[w >> 1]];
          final foot = table[level + 1];
          final head = table[level + top];
          int footA, headA;
          if (share && openEnd == ra) {
            // Continue the strip from the last wall's end corner.
            footA = v - 2;
            headA = v - 1;
          } else {
            final o = v * 2;
            pos[o] = ax * kb;
            pos[o + 1] = ay * kb;
            pos[o + 2] = ax * kt;
            pos[o + 3] = ay * kt;
            col[v] = foot;
            col[v + 1] = head;
            footA = v;
            headA = v + 1;
            v += 2;
          }
          final o = v * 2;
          pos[o] = cx * kb;
          pos[o + 1] = cy * kb;
          pos[o + 2] = cx * kt;
          pos[o + 3] = cy * kt;
          col[v] = foot;
          col[v + 1] = head;
          idx[k] = footA;
          idx[k + 1] = v;
          idx[k + 2] = v + 1;
          idx[k + 3] = footA;
          idx[k + 4] = v + 1;
          idx[k + 5] = headA;
          k += 6;
          v += 2;
          openEnd = share ? rc : -1;
        }
        _vertexCount = v;
        _indexCount = k;
      }

      // The roof.
      final roofColor = table[colorAt];
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
    final last = _build();
    if (last != null) order.add(last);
  }

  /// The vertices written since the last call, as one draw's worth; null
  /// when there are none.
  ui.Vertices? _build() {
    if (_indexCount == 0) {
      _vertexCount = 0;
      return null;
    }
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(_positions, 0, _vertexCount * 2),
      colors: Int32List.sublistView(_colors, 0, _vertexCount),
      indices: Uint16List.sublistView(_indices, 0, _indexCount),
    );
    debugVertices += _vertexCount;
    _vertexCount = 0;
    _indexCount = 0;
    return vertices;
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

  /// Per layout, its colour classes' colours under the current light
  /// (`ExtrusionShading.fill`).
  final List<Int32List> tables;

  /// The entries whose footprints lie in [_window], ascending — so in
  /// drawing order — the first [candidateCount] of them. A frame only
  /// culls these; they are gathered again when the viewport leaves the
  /// window or the zoom moves on.
  final Int32List candidates;
  var candidateCount = 0;

  /// The window [candidates] were gathered for: its zoom, and its
  /// bounds in world pixels at that zoom.
  ({
    double zoom,
    double left,
    double top,
    double right,
    double bottom
  })? _window;

  /// This frame's draws, and the opacity they are composited with.
  final _vertices = <ui.Vertices>[];
  var opacity = 1.0;
  static final _layerPaint = Paint();
  static final _vertexPaint = Paint();

  _LayerOrder._(this.layer, this.layouts, this.layout, this.building)
      : tx = Float64List(layouts.length),
        ty = Float64List(layouts.length),
        scale = Float64List(layouts.length),
        tables = [
          for (final layout in layouts)
            Int32List(layout.classes.length ~/ 3 * ExtrusionShading.stride),
        ],
        candidates = Int32List(layout.length);

  /// The window a gathering covers beyond the viewport, as a share of
  /// its larger half-extent on every side.
  static const double _margin = 0.5;

  /// Gathers [candidates] again unless the viewport — [hx] by [hy]
  /// logical pixels either side of [worldCenter], at [cameraZoom] — lies
  /// within the window of the last gathering, at a zoom less than a
  /// quarter level from it.
  void cull(double cameraZoom, Offset worldCenter, double hx, double hy) {
    final window = _window;
    if (window != null && (cameraZoom - window.zoom).abs() < 0.25) {
      final f = math.pow(2.0, window.zoom - cameraZoom).toDouble();
      final cx = worldCenter.dx * f, cy = worldCenter.dy * f;
      if (cx - hx * f >= window.left &&
          cx + hx * f <= window.right &&
          cy - hy * f >= window.top &&
          cy + hy * f <= window.bottom) {
        return;
      }
    }
    final pad = _margin * math.max(hx, hy);
    final left = worldCenter.dx - hx - pad, right = worldCenter.dx + hx + pad;
    final top = worldCenter.dy - hy - pad, bottom = worldCenter.dy + hy + pad;
    _window =
        (zoom: cameraZoom, left: left, top: top, right: right, bottom: bottom);
    // Per layout, the window in its extent units.
    final count = layouts.length;
    final lx0 = Float64List(count), ly0 = Float64List(count);
    final lx1 = Float64List(count), ly1 = Float64List(count);
    for (var i = 0; i < count; i++) {
      final rect = displayTileRect(layouts[i].tile, cameraZoom);
      final unit = layouts[i].extent / rect.width;
      lx0[i] = (left - rect.left) * unit;
      lx1[i] = (right - rect.left) * unit;
      ly0[i] = (top - rect.top) * unit;
      ly1[i] = (bottom - rect.top) * unit;
    }
    var n = 0;
    for (var e = 0; e < layout.length; e++) {
      final li = layout[e];
      final bi = building[e] * 4;
      final bounds = layouts[li].bounds;
      if (bounds[bi + 2] < lx0[li] ||
          bounds[bi] > lx1[li] ||
          bounds[bi + 3] < ly0[li] ||
          bounds[bi + 1] > ly1[li]) {
        continue;
      }
      candidates[n++] = e;
    }
    candidateCount = n;
  }

  void add(ui.Vertices? vertices) {
    if (vertices != null) _vertices.add(vertices);
  }

  /// Draws this frame's vertices, composited at [opacity].
  void redraw(Canvas canvas) {
    if (_vertices.isEmpty) return;
    if (opacity < 1) {
      canvas.saveLayer(
          null, _layerPaint..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    for (final vertices in _vertices) {
      canvas.drawVertices(vertices, BlendMode.dst, _vertexPaint);
    }
    if (opacity < 1) canvas.restore();
  }

  void disposeVertices() {
    for (final vertices in _vertices) {
      vertices.dispose();
    }
    _vertices.clear();
  }

  void fillTables(ExtrusionLight light) {
    for (var l = 0; l < layouts.length; l++) {
      final classes = layouts[l].classes;
      final table = tables[l];
      for (var c = 0; c * 3 < classes.length; c++) {
        ExtrusionShading.fill(table, c * ExtrusionShading.stride,
            classes[c * 3], classes[c * 3 + 1], classes[c * 3 + 2], light);
      }
    }
  }

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
