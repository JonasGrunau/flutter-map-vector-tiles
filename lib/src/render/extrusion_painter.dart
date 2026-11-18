import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

import '../core/tile_key.dart';
import '../grid/grid_layout.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import 'extrusion_layouter.dart';
import 'extrusion_shading.dart';
import 'tile_rasterizer.dart';

/// A data tile's buildings on offer to the painter. [skip], when set,
/// leaves out the buildings whose footprint centre falls in a cell of a
/// [side] × [side] grid over the tile that it marks: a tile of the level
/// a zoom crossing is leaving counts only where the arriving level has
/// no buildings yet, or the two would draw each building twice.
typedef ExtrusionTile = ({ExtrusionLayout layout, Uint8List? skip, int side});

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

  /// Re-sorts of the buildings on offer (a new set of data tiles), and
  /// the time they took, counted in [debugMicros] too.
  static int debugRebuilds = 0;
  static int debugRebuildMicros = 0;

  /// When set, every painted frame appends its UI-thread microseconds
  /// here. For benchmarks; null otherwise, so nothing accumulates.
  static List<int>? debugFrameLog;

  /// With [debugFrameLog]: per frame, the vertices it drew, and the
  /// microseconds it spent gathering candidates again (0 when it kept
  /// the last window) — what a slow frame was busy with.
  static List<int>? debugFrameVertices;
  static List<int>? debugFrameCullMicros;

  /// Draws every layer opaque, without its `saveLayer` — for a
  /// benchmark to put a number on the layer's raster-thread cost.
  static bool debugForceOpaque = false;

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

  /// Every building on offer, and of the data tiles on offer a little
  /// while ago, per layer in drawing order. Which tiles are on offer now
  /// — and which of their buildings a skip mask leaves out — is marked
  /// on the orders, not sorted into them: a zoom sweep takes data tiles
  /// off and puts them back at every level crossing, and sorting every
  /// building again for each change cost 2 ms on a phone, twenty times a
  /// second. Only a data tile the orders do not hold sorts them again.
  List<_LayerOrder> _orders = const [];

  /// The tiles on offer, as last marked on [_orders].
  List<ExtrusionTile> _tiles = const [];

  /// The theme's 3D layers, in style order, that [_orders] were last
  /// matched against: they give the orders their order and their layer
  /// objects — opacity, translate, zoom range — by id.
  List<FillThemeLayer>? _layers;

  /// How long a data tile no longer on offer keeps its place in the
  /// orders; the first frame after that sorts it out.
  @visibleForTesting
  static Duration keepInactiveFor = const Duration(seconds: 2);

  /// When the first frame sorts out the layouts off offer past
  /// [keepInactiveFor], in microseconds of [_clock]: twice that after
  /// the first of them went off, so the ones a zoom sweep takes off one
  /// after another go in one sort, not one each. Null while every
  /// layout held is on offer.
  double? _expiry;

  final _clock = Stopwatch()..start();

  /// The light the colour tables were filled under, and the light and
  /// rotation [_levels] were worked out for.
  ExtrusionLight? _tableLight;
  ExtrusionLight? _levelsLight;
  double? _levelsRotation;

  /// Per wall direction, its light level this frame.
  final _levels = Uint8List(256);

  // Allocated on the first frame that draws a building: every layer
  // holds a painter, and most never draw one (`ExtrusionMode.flat`, or
  // a style without `fill-extrusion`).
  late final _positions = Float32List(_maxVertices * 2);
  late final _colors = Int32List(_maxVertices);
  late var _indices = Uint16List(1 << 18);
  var _vertexCount = 0;
  var _indexCount = 0;

  /// Forgets the buildings and frees the last frame's vertices — for a
  /// theme or provider change, and the layer's dispose.
  void reset() {
    _disposeLast();
    _generation = null;
    _orders = const [];
    _tiles = const [];
    _layers = null;
    _expiry = null;
    _tableLight = null;
    _levelsLight = null;
  }

  /// Lets go of the buildings no longer on offer, grace period or not —
  /// for `VectorTileLayer.clearMemoryCache`.
  void trim() {
    if (_expiry != null) _resort(_tiles, keepMicros: 0);
  }

  /// Draws the buildings [layouts] offers of [layers] — the theme's 3D
  /// layers, in style order.
  void paint(
    Canvas canvas, {
    required int generation,
    required Iterable<ExtrusionTile> Function() layouts,
    required List<FillThemeLayer> layers,
    required double cameraZoom,
    required double styleZoom,
    required Offset worldCenter,
    required double latitude,
    required Size viewport,
    required double rotation,
    StyleLight? light,
  }) {
    final stopwatch = Stopwatch()..start();
    final vertices0 = debugVertices;
    _cullMicros = 0;
    if (!identical(layers, _layers)) {
      // A new theme — a sibling one for new global state, say — over
      // the same buildings: its layers take over, by id, without a sort.
      _layers = layers;
      _disposeLast();
      _orders = _matched(_orders, layers);
    }
    if (_generation != generation) {
      _generation = generation;
      // The generation moves with every label publish and every display
      // tile, most of which leave the data tiles — and so the buildings
      // — as they were: sort only when they changed.
      // In a fixed order: the display tiles they come from come and go
      // in any order, and the same buildings must compare equal.
      final tiles = layouts().toList(growable: false)..sort(_byTile);
      if (!_sameTiles(tiles, _tiles)) {
        _disposeLast();
        _tiles = tiles;
        if (_activate(tiles)) {
          _noteExpiry();
        } else {
          _resort(tiles);
        }
      }
    }
    final expiry = _expiry;
    if (expiry != null && _clock.elapsedMicroseconds >= expiry) {
      // A data tile off offer past its grace period: let go of it.
      _resort(_tiles);
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
      _count(stopwatch, vertices0);
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
      // `fill-extrusion-translate` moves the footprint on the ground,
      // before the camera projects it.
      final translate = TileRasterizer.translateOf(layer.translate, styleZoom);
      for (var i = 0; i < layouts.length; i++) {
        final layout = layouts[i];
        final rect = displayTileRect(layout.tile, cameraZoom);
        tx[i] = rect.left - worldCenter.dx + translate.dx;
        ty[i] = rect.top - worldCenter.dy + translate.dy;
        ts[i] = rect.width / layout.extent;
      }
      final culled = stopwatch.elapsedMicroseconds;
      if (order.cull(cameraZoom, worldCenter, hx, hy)) {
        _cullMicros += stopwatch.elapsedMicroseconds - culled;
      }
      order.opacity = debugForceOpaque ? 1 : opacity;
      _drawLayer(order, styleZoom, d, ppm, maxLift, hx, hy);
      order.redraw(canvas);
    }

    developer.Timeline.finishSync();
    _count(stopwatch, vertices0);
  }

  static int _byTile(ExtrusionTile a, ExtrusionTile b) {
    final x = a.layout, y = b.layout;
    if (x.tile.z != y.tile.z) return x.tile.z - y.tile.z;
    if (x.tile.x != y.tile.x) return x.tile.x - y.tile.x;
    if (x.tile.y != y.tile.y) return x.tile.y - y.tile.y;
    final byLayer = x.layer.id.compareTo(y.layer.id);
    if (byLayer != 0) return byLayer;
    // The same data tile and layer twice: two zooms' layouts.
    return (x.zoom ?? -1) - (y.zoom ?? -1);
  }

  /// Marks the layouts of [tiles] on offer in [_orders], with their skip
  /// masks, and every other one off. False, and nothing marked, when
  /// one of them is not in the orders.
  bool _activate(List<ExtrusionTile> tiles) {
    final byLayer = {for (final order in _orders) order.layer.id: order};
    final drawn = {for (final layer in _layers ?? const []) layer.id};
    for (final tile in tiles) {
      final id = tile.layout.layer.id;
      // A layer the theme no longer has is not drawn, and needs no sort.
      if (!drawn.contains(id)) continue;
      final order = byLayer[id];
      if (order == null || !order.indexOf.containsKey(tile.layout)) {
        return false;
      }
    }
    final now = _clock.elapsedMicroseconds.toDouble();
    for (final order in _orders) {
      order.deactivate(now);
    }
    for (final tile in tiles) {
      final order = byLayer[tile.layout.layer.id];
      if (order == null) continue;
      final l = order.indexOf[tile.layout]!;
      order.active[l] = 1;
      final skip = tile.skip;
      order.kept[l] =
          skip == null ? null : tile.layout.keptUnder(skip, tile.side);
    }
    return true;
  }

  /// [_sort], counted.
  void _resort(List<ExtrusionTile> tiles, {int? keepMicros}) {
    final stopwatch = Stopwatch()..start();
    _disposeLast();
    _sort(tiles, keepMicros ?? keepInactiveFor.inMicroseconds);
    _tableLight = null;
    debugRebuilds++;
    debugRebuildMicros += stopwatch.elapsedMicroseconds;
  }

  /// Notes in [_expiry] when the layouts off offer are to be sorted out.
  void _noteExpiry() {
    double? first;
    for (final order in _orders) {
      for (var l = 0; l < order.layouts.length; l++) {
        if (order.active[l] == 1) continue;
        final since = order.inactiveSince[l];
        if (first == null || since < first) first = since;
      }
    }
    _expiry = first == null ? null : first + 2 * keepInactiveFor.inMicroseconds;
  }

  /// The data tile, layer and zoom a layout draws: one on offer replaces
  /// any other of the same — laid out again under a new feature state,
  /// or from the tile decoded again.
  static (TileKey, String, int?) _drawsAs(ExtrusionLayout layout) =>
      (layout.tile, layout.layer.id, layout.zoom);

  /// Sorts [_orders] again for [tiles], keeping the layouts that left
  /// them less than [keep] microseconds ago — unless one on offer
  /// replaces them — and marks [tiles] on offer.
  void _sort(List<ExtrusionTile> tiles, int keep) {
    final now = _clock.elapsedMicroseconds.toDouble();
    final seen = Set<ExtrusionLayout>.identity();
    final offered = {for (final tile in tiles) _drawsAs(tile.layout)};
    // Since when each layout kept from the old orders has been off.
    final offSince = Map<ExtrusionLayout, double>.identity();
    final layouts = <ExtrusionTile>[
      for (final tile in tiles)
        if (seen.add(tile.layout)) (layout: tile.layout, skip: null, side: 1),
    ];
    for (final order in _orders) {
      for (var l = 0; l < order.layouts.length; l++) {
        final layout = order.layouts[l];
        // On offer until now, or off for less than the grace period.
        final since = order.active[l] == 1 ? now : order.inactiveSince[l];
        if (now - since < keep &&
            !offered.contains(_drawsAs(layout)) &&
            seen.add(layout)) {
          layouts.add((layout: layout, skip: null, side: 1));
          offSince[layout] = since;
        }
      }
    }
    _orders = _order(layouts..sort(_byTile), _layers ?? const []);
    for (final order in _orders) {
      for (var l = 0; l < order.layouts.length; l++) {
        order.inactiveSince[l] = offSince[order.layouts[l]] ?? now;
      }
    }
    _activate(tiles);
    _noteExpiry();
  }

  static bool _sameTiles(List<ExtrusionTile> a, List<ExtrusionTile> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if (!identical(x.layout, y.layout) || x.side != y.side) return false;
      final xs = x.skip, ys = y.skip;
      if (xs == null || ys == null) {
        if (!identical(xs, ys)) return false;
        continue;
      }
      for (var j = 0; j < xs.length; j++) {
        if (xs[j] != ys[j]) return false;
      }
    }
    return true;
  }

  /// This frame's candidate gathering, for [debugFrameCullMicros].
  var _cullMicros = 0;

  void _count(Stopwatch stopwatch, int vertices0) {
    final micros = stopwatch.elapsedMicroseconds;
    debugFrames++;
    debugMicros += micros;
    debugFrameLog?.add(micros);
    debugFrameVertices?.add(debugVertices - vertices0);
    debugFrameCullMicros?.add(_cullMicros);
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

  void _drawLayer(_LayerOrder order, double styleZoom, double d, double ppm,
      double maxLift, double hx, double hy) {
    final layouts = order.layouts;
    final tables = order.tables;
    final levels = _levels;
    final tx = order.tx, ty = order.ty, ts = order.scale;
    final entryLayout = order.layout, entryBuilding = order.building;
    final active = order.active, kept = order.kept;
    final candidates = order.candidates;
    final pos = _positions;
    final col = _colors;
    var idx = _indices;
    _vertexCount = 0;
    _indexCount = 0;

    for (var c = 0; c < order.candidateCount; c++) {
      final e = candidates[c];
      final li = entryLayout[e];
      // Off offer, or left out by its tile's skip mask.
      if (active[li] == 0) continue;
      final bi = entryBuilding[e];
      final keep = kept[li];
      if (keep != null && keep[bi] == 0) continue;
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
      var lift = layout.heightAt(bi, styleZoom) * ppm;
      if (lift > maxLift) lift = maxLift;
      final kt = d / (d - lift);
      final floor0 = layout.baseAt(bi, styleZoom);
      var baseLift = floor0 * ppm;
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
      // A building too big for one draw even on its own — a polygon of
      // tens of thousands of vertices, the builder takes up to
      // [_maxVertices] — goes out over several, split between walls and
      // before its roof: a draw's indices are 16-bit.
      final split = needVertices > _maxVertices;
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
        final coveredBy = layout.wallCoveredBy;
        final height = layout.heightAt(bi, styleZoom);
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
          // A wall shared with a neighbour shows above its roof only.
          var kf = kb;
          if (coveredBy != null) {
            final cover = coveredBy[w >> 1];
            if (cover >= 0) {
              final floor = layout.heightAt(cover, styleZoom);
              if (floor >= height) {
                openEnd = -1;
                continue;
              }
              if (floor > floor0) {
                var floorLift = floor * ppm;
                if (floorLift > maxLift) floorLift = maxLift;
                kf = d / (d - floorLift);
              }
            }
          }
          if (split && v + 4 > _maxVertices) {
            _vertexCount = v;
            _indexCount = k;
            order.add(_build());
            v = 0;
            k = 0;
            // The corner to share went out with the last draw.
            openEnd = -1;
          }
          int footA, headA;
          if (share && openEnd == ra && kf == kb) {
            // Continue the strip from the last wall's end corner.
            footA = v - 2;
            headA = v - 1;
          } else {
            final o = v * 2;
            pos[o] = ax * kf;
            pos[o + 1] = ay * kf;
            pos[o + 2] = ax * kt;
            pos[o + 3] = ay * kt;
            col[v] = foot;
            col[v + 1] = head;
            footA = v;
            headA = v + 1;
            v += 2;
          }
          final o = v * 2;
          pos[o] = cx * kf;
          pos[o + 1] = cy * kf;
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
          openEnd = share && kf == kb ? rc : -1;
        }
        _vertexCount = v;
        _indexCount = k;
      }

      // The roof.
      if (split && _vertexCount + vn > _maxVertices) order.add(_build());
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

  /// Every building of [layouts] — their skip masks are not applied
  /// here but marked on the orders (see [_activate]) — per layer in the
  /// order of [layers], lowest roof first. A layer [layers] does not
  /// hold is left out.
  ///
  /// Layers are told apart by id: a result cached for a style read
  /// again carries the earlier reading's layer objects — the same style,
  /// so the same layers — and its buildings must sort, and composite,
  /// with the fresh tiles' as one layer, the one [layers] holds.
  static List<_LayerOrder> _order(
      Iterable<ExtrusionTile> layouts, List<FillThemeLayer> layers) {
    final byLayer = <String, List<ExtrusionTile>>{};
    for (final tile in layouts) {
      (byLayer[tile.layout.layer.id] ??= []).add(tile);
    }
    return [
      for (final layer in layers)
        if (byLayer[layer.id] case final tiles?)
          _LayerOrder.sorted(layer, tiles),
    ];
  }

  /// [orders] matched to [layers] by id: in their order, drawn with
  /// their layer objects, an order of a layer they do not hold left out.
  static List<_LayerOrder> _matched(
      List<_LayerOrder> orders, List<FillThemeLayer> layers) {
    if (orders.isEmpty) return orders;
    final byId = {for (final order in orders) order.layer.id: order};
    return [
      for (final layer in layers)
        if (byId[layer.id] case final order?) order..layer = layer,
    ];
  }
}

/// One layer's buildings across all tiles, in drawing order.
class _LayerOrder {
  /// The theme's layer — the current theme's, whichever reading of the
  /// style the buildings were laid out under.
  FillThemeLayer layer;
  final List<ExtrusionLayout> layouts;

  /// Per entry, the layout and the building within it.
  final Int32List layout;
  final Int32List building;

  /// Per layout, scratch for the frame's tile transform.
  final Float64List tx, ty, scale;

  /// Per layout, its colour classes' colours under the current light
  /// (`ExtrusionLayout.tableFor`).
  final List<Int32List> tables;

  /// Each layout's index in [layouts].
  final Map<ExtrusionLayout, int> indexOf;

  /// Per layout, 1 while it is on offer — the painter draws only those
  /// — and which of its buildings its tile's skip mask keeps (null for
  /// all of them).
  final Uint8List active;
  final List<Uint8List?> kept;

  /// Per layout, when it was last taken off offer, in microseconds of
  /// the painter's clock; doubles, which the web has for 64-bit ints.
  final Float64List inactiveSince;

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
        tables = List.filled(layouts.length, _noTable),
        indexOf = Map.identity()
          ..addAll({for (var l = 0; l < layouts.length; l++) layouts[l]: l}),
        active = Uint8List(layouts.length),
        kept = List.filled(layouts.length, null),
        inactiveSince = Float64List(layouts.length),
        candidates = Int32List(layout.length);

  /// Takes every layout off offer, noting [now] for those that were on.
  void deactivate(double now) {
    for (var l = 0; l < layouts.length; l++) {
      if (active[l] == 1) {
        active[l] = 0;
        inactiveSince[l] = now;
      }
      kept[l] = null;
    }
  }

  /// The window a gathering covers beyond the viewport, as a share of
  /// its larger half-extent on every side.
  static const double _margin = 0.5;

  /// Gathers [candidates] again unless the viewport — [hx] by [hy]
  /// logical pixels either side of [worldCenter], at [cameraZoom] — lies
  /// within the window of the last gathering. Zooming in shrinks the
  /// viewport inside it, so that only goes on for half a level, until
  /// the window holds too much more than the screen; zooming out leaves
  /// it soon enough.
  ///
  /// Returns whether it gathered them again.
  bool cull(double cameraZoom, Offset worldCenter, double hx, double hy) {
    final window = _window;
    if (window != null && cameraZoom - window.zoom < 0.5) {
      final f = math.pow(2.0, window.zoom - cameraZoom).toDouble();
      final cx = worldCenter.dx * f, cy = worldCenter.dy * f;
      if (cx - hx * f >= window.left &&
          cx + hx * f <= window.right &&
          cy - hy * f >= window.top &&
          cy + hy * f <= window.bottom) {
        return false;
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
    return true;
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

  static final _noTable = Int32List(0);

  void fillTables(ExtrusionLight light) {
    for (var l = 0; l < layouts.length; l++) {
      tables[l] = layouts[l].tableFor(light);
    }
  }

  /// A counting sort on the roof height in decimetres — halfway through
  /// the layout's zoom band (`ExtrusionLayout.sortHeight`) — linear in
  /// the buildings, and stable, so equal heights keep tile order. Every
  /// building is entered; skip masks apply when drawing.
  factory _LayerOrder.sorted(FillThemeLayer layer, List<ExtrusionTile> tiles) {
    final layouts = [for (final tile in tiles) tile.layout];
    var total = 0;
    for (final layout in layouts) {
      total += layout.length;
    }
    const buckets = 1 << 16;
    final counts = _counts..fillRange(0, buckets + 1, 0);
    int keyOf(double height) {
      final key = (height * 10).round();
      return key < 0 ? 0 : (key >= buckets ? buckets - 1 : key);
    }

    for (final layout in layouts) {
      for (var i = 0; i < layout.length; i++) {
        counts[keyOf(layout.sortHeight(i)) + 1]++;
      }
    }
    for (var i = 1; i <= buckets; i++) {
      counts[i] += counts[i - 1];
    }
    final layoutOf = Int32List(total);
    final buildingOf = Int32List(total);
    for (var l = 0; l < layouts.length; l++) {
      final layout = layouts[l];
      for (var i = 0; i < layout.length; i++) {
        final slot = counts[keyOf(layout.sortHeight(i))]++;
        layoutOf[slot] = l;
        buildingOf[slot] = i;
      }
    }
    return _LayerOrder._(layer, layouts, layoutOf, buildingOf);
  }

  /// The counting sort's buckets, reused: 256 KB is not worth
  /// allocating per tile event.
  static final _counts = Int32List((1 << 16) + 1);
}
