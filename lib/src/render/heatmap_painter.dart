import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../core/tile_key.dart';
import '../core/tile_zoom.dart';
import '../grid/grid_layout.dart';
import '../style/expression.dart';
import '../style/sprite_packer.dart' show decodeRgbaPixels;
import '../style/theme.dart';
import 'heatmap_density.dart';
import 'heatmap_layouter.dart';
import 'heatmap_worker.dart';

/// A tile offering heatmap points to a density pass.
///
/// [include], when set, is asked per point — with its position in world
/// pixels at the pass's camera zoom — whether the point still counts: a
/// tile of the level a zoom crossing is leaving counts only where the
/// arriving level has no points yet, or the two would add up.
typedef HeatmapTile = ({
  TileKey key,
  List<HeatmapPoints> heatmap,
  bool Function(double worldX, double worldY)? include,
});

/// Draws `heatmap` layers in screen space, as MapLibre does: one density
/// over every visible tile's points — a kernel reaches across tile seams
/// — coloured through `heatmap-color`, over the tile rasters.
///
/// The density is not recomputed per frame. A *pass* gathers the points
/// whose kernels reach the viewport plus a margin, hands the density and
/// its colouring to a [HeatmapWorker] (an isolate on native platforms),
/// uploads the pixels as an image, and the frames after it draw that
/// image under the camera transform: panning and rotating are exact, and
/// a zoom scales the kernels with the map until the next pass. A pass
/// runs when the zoom, the tiles or the screen changed and [interval]
/// has passed since the last one started — at once when the viewport
/// left the image or there is none — and never while one is in flight.
/// `heatmap-opacity` and the layer's zoom range are applied per frame.
class HeatmapPainter {
  /// Called when a pass's image has landed, or a deferred pass is due —
  /// either needs a repaint.
  final void Function() onChanged;

  HeatmapPainter({required this.onChanged});

  /// The least time between the starts of two passes, unless the
  /// viewport outgrows the image.
  static const interval = Duration(milliseconds: 100);

  /// The logical pixels a pass covers beyond each edge of the viewport,
  /// so a pan has some way to go before it needs a pass of its own.
  static const double margin = 64;

  /// Passes started, and the UI-thread time they took — gathering the
  /// points and building the jobs; the density itself runs on the
  /// worker. For tests and benchmarks.
  static int debugPassCount = 0;
  static int debugPassMicros = 0;

  final _images = <HeatmapThemeLayer, _HeatmapImage>{};
  final _ramps = <HeatmapThemeLayer, Uint32List>{};
  HeatmapWorker? _worker;

  /// What the last pass was run for.
  ({int generation, double zoom, double dpr, Size viewport})? _passInputs;
  ({double left, double top, double right, double bottom})? _passCover;
  final _sincePass = Stopwatch();
  var _sequence = 0;
  var _inFlight = 0;
  Timer? _due;
  var _disposed = false;

  /// Paints every visible heatmap layer of [theme], after starting a
  /// density pass if one is due. [canvas] is in world pixels at
  /// [cameraZoom] relative to [worldCenter] — the tile rasters' space.
  /// [tiles] is asked for the contributing tiles only when a pass runs,
  /// with the camera zoom their [HeatmapTile.include] will be asked at.
  /// [generation] changes whenever those tiles or their points do.
  void paint(
    Canvas canvas, {
    required Theme theme,
    required double cameraZoom,
    required double styleZoom,
    required Offset worldCenter,
    required Size viewport,
    required double rotation,
    required double devicePixelRatio,
    required int generation,
    required Iterable<HeatmapTile> Function(double cameraZoom) tiles,
  }) {
    if (_disposed) return;
    final layers = [
      for (final layer in theme.layers)
        if (layer is HeatmapThemeLayer && layer.coversZoom(styleZoom)) layer,
    ];
    if (layers.isEmpty) return;
    _maybePass(
      layers,
      cameraZoom: cameraZoom,
      styleZoom: styleZoom,
      worldCenter: worldCenter,
      viewport: viewport,
      rotation: rotation,
      devicePixelRatio: devicePixelRatio,
      generation: generation,
      tiles: tiles,
    );
    final zoomCtx = EvalContext(zoom: styleZoom);
    for (final layer in layers) {
      final shown = _images[layer];
      if (shown == null) continue;
      final opacity = layer.opacity.eval(zoomCtx).clamp(0.0, 1.0);
      if (opacity <= 0) continue;
      final s = math.pow(2.0, cameraZoom - shown.zoom).toDouble();
      final image = shown.image;
      _paint.color = Color.fromRGBO(255, 255, 255, opacity);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(
          shown.left * s - worldCenter.dx,
          shown.top * s - worldCenter.dy,
          shown.width * s,
          shown.height * s,
        ),
        _paint,
      );
    }
  }

  static final _paint = Paint()
    ..filterQuality = FilterQuality.low
    ..isAntiAlias = false;

  /// The viewport's world-axis-aligned half extents under [rotation].
  static ({double x, double y}) _halfExtents(Size viewport, double rotation) {
    final c = math.cos(rotation).abs();
    final s = math.sin(rotation).abs();
    return (
      x: (viewport.width * c + viewport.height * s) / 2,
      y: (viewport.width * s + viewport.height * c) / 2,
    );
  }

  void _maybePass(
    List<HeatmapThemeLayer> layers, {
    required double cameraZoom,
    required double styleZoom,
    required Offset worldCenter,
    required Size viewport,
    required double rotation,
    required double devicePixelRatio,
    required int generation,
    required Iterable<HeatmapTile> Function(double cameraZoom) tiles,
  }) {
    if (_inFlight > 0) return; // its landing repaints, and asks again
    final inputs = (
      generation: generation,
      zoom: cameraZoom,
      dpr: devicePixelRatio,
      viewport: viewport,
    );
    final half = _halfExtents(viewport, rotation);
    final cover = _passCover;
    final last = _passInputs;
    var urgent = cover == null ||
        last == null ||
        last.dpr != devicePixelRatio ||
        last.viewport != viewport;
    if (!urgent) {
      // The viewport, in world pixels at the pass's zoom.
      final s = math.pow(2.0, last.zoom - cameraZoom).toDouble();
      urgent = (worldCenter.dx - half.x) * s < cover.left ||
          (worldCenter.dy - half.y) * s < cover.top ||
          (worldCenter.dx + half.x) * s > cover.right ||
          (worldCenter.dy + half.y) * s > cover.bottom;
    }
    if (!urgent && inputs == last) return;
    if (!urgent && _sincePass.elapsed < interval) {
      _due ??= Timer(interval - _sincePass.elapsed, () {
        _due = null;
        if (!_disposed) onChanged();
      });
      return;
    }
    _due?.cancel();
    _due = null;
    _passInputs = inputs;
    _passCover = (
      left: worldCenter.dx - half.x - margin,
      top: worldCenter.dy - half.y - margin,
      right: worldCenter.dx + half.x + margin,
      bottom: worldCenter.dy + half.y + margin,
    );
    _sincePass
      ..reset()
      ..start();
    _pass(layers, cameraZoom, styleZoom, devicePixelRatio, tiles(cameraZoom));
  }

  void _pass(List<HeatmapThemeLayer> layers, double cameraZoom,
      double styleZoom, double dpr, Iterable<HeatmapTile> tiles) {
    developer.Timeline.startSync('VT heatmap');
    final stopwatch = Stopwatch()..start();
    final sequence = ++_sequence;
    final cover = _passCover!;
    final tileList = tiles.toList(growable: false);
    final zoomCtx = EvalContext(zoom: styleZoom);
    for (final layer in layers) {
      final points = _gather(layer, tileList, cameraZoom, styleZoom, cover);
      if (points.count == 0) {
        _images.remove(layer)?.image.dispose();
        continue;
      }
      final (:cell, :upsampling) = HeatmapGrid.cellFor(points.minRadius, dpr);
      // Snapped to the cell lattice, so that passes at one zoom sample
      // the density at the same places and a pan does not shimmer it.
      final left = (cover.left / cell).floorToDouble() * cell;
      final top = (cover.top / cell).floorToDouble() * cell;
      final width = ((cover.right - left) / cell).ceil();
      final height = ((cover.bottom - top) / cell).ceil();
      final job = HeatmapJob(
        width: width,
        height: height,
        cell: cell,
        upsampling: upsampling,
        ramp: _rampOf(layer, styleZoom),
        batches: points.batches(
          dx: cover.left - left,
          dy: cover.top - top,
          peakScale: math.max(0.0, layer.intensity.eval(zoomCtx)) *
              HeatmapGrid.peakFactor,
        ),
      );
      _inFlight++;
      unawaited(_render(job).then((image) {
        _inFlight--;
        if (_disposed || sequence != _sequence) {
          image?.dispose();
          // A reset dropped this pass; the next paint owes a new one.
          if (!_disposed && _inFlight == 0) onChanged();
          return;
        }
        if (image == null) return;
        _images.remove(layer)?.image.dispose();
        _images[layer] = _HeatmapImage(
          image,
          zoom: cameraZoom,
          left: left,
          top: top,
          width: width * cell,
          height: height * cell,
        );
        onChanged();
      }));
    }
    // Layers the theme no longer has, or that left their zoom range.
    _images.removeWhere((layer, shown) {
      if (layers.contains(layer)) return false;
      shown.image.dispose();
      return true;
    });
    debugPassCount++;
    debugPassMicros += stopwatch.elapsedMicroseconds;
    developer.Timeline.finishSync();
  }

  /// [job] rendered on the worker and uploaded; null if either failed.
  /// The upload goes through [decodeRgbaPixels], not
  /// `ImageDescriptor.raw` — see there.
  Future<ui.Image?> _render(HeatmapJob job) async {
    final pixels = await (_worker ??= HeatmapWorker()).render(job);
    if (pixels == null || _disposed) return null;
    try {
      return await decodeRgbaPixels(pixels, job.outputWidth, job.outputHeight);
    } catch (_) {
      return null;
    }
  }

  /// The ramp as 256 premultiplied colours for densities 0..1.
  /// `heatmap-color` may not read the zoom, per spec, so it is evaluated
  /// once per layer.
  Uint32List _rampOf(HeatmapThemeLayer layer, double styleZoom) =>
      _ramps[layer] ??= () {
        final ramp = Uint32List(256);
        for (var i = 0; i < 256; i++) {
          final c = layer.color
              .eval(EvalContext(zoom: styleZoom, heatmapDensity: i / 255));
          ramp[i] = HeatmapGrid.packRgba(c.r, c.g, c.b, c.a);
        }
        return ramp;
      }();

  /// Every point of [layer] whose kernel reaches into [cover], positioned
  /// relative to its top-left corner.
  static _GatheredPoints _gather(
    HeatmapThemeLayer layer,
    List<HeatmapTile> tiles,
    double cameraZoom,
    double styleZoom,
    ({double left, double top, double right, double bottom}) cover,
  ) {
    final out = _GatheredPoints();
    final zoomCtx = EvalContext(zoom: styleZoom);
    final width = cover.right - cover.left;
    final height = cover.bottom - cover.top;
    for (final tile in tiles) {
      HeatmapPoints? points;
      for (final p in tile.heatmap) {
        if (identical(p.layer, layer)) points = p;
      }
      if (points == null || points.length == 0) continue;
      final rect = displayTileRect(tile.key, cameraZoom);
      final scale = rect.width / displayTileSize;
      final ox = rect.left - cover.left;
      final oy = rect.top - cover.top;
      final weights = points.weightsAt(styleZoom);
      final radii = points.radiiAt(styleZoom);
      final uniformWeight = weights == null ? layer.weight.eval(zoomCtx) : 0.0;
      if (weights == null && !(uniformWeight > 0)) continue;
      final uniformRadius = radii == null ? layer.radius.eval(zoomCtx) : 0.0;
      if (radii == null && !(uniformRadius > 0)) continue;
      final include = tile.include;
      final xy = points.xy;
      var batch = radii == null ? out.batchFor(uniformRadius) : null;
      var reach = HeatmapGrid.reachInRadii * uniformRadius;
      for (var i = 0; i < points.length; i++) {
        final weight = weights == null ? uniformWeight : weights[i];
        if (!(weight > 0)) continue;
        if (radii != null) {
          final radius = radii[i];
          if (!(radius > 0)) continue;
          batch = out.batchFor(radius);
          reach = HeatmapGrid.reachInRadii * radius;
        }
        final x = ox + xy[i * 2] * scale;
        final y = oy + xy[i * 2 + 1] * scale;
        if (x < -reach ||
            x > width + reach ||
            y < -reach ||
            y > height + reach) {
          continue;
        }
        if (include != null && !include(x + cover.left, y + cover.top)) {
          continue;
        }
        batch!.add(x, y, weight);
        out.count++;
      }
    }
    return out;
  }

  /// Disposes every image, for a theme change or a cleared screen.
  void reset() {
    _sequence++;
    for (final shown in _images.values) {
      shown.image.dispose();
    }
    _images.clear();
    _ramps.clear();
    _passInputs = null;
    _passCover = null;
    _due?.cancel();
    _due = null;
  }

  void dispose() {
    reset();
    _disposed = true;
    _worker?.dispose();
    _worker = null;
  }
}

class _HeatmapImage {
  final ui.Image image;

  /// The camera zoom of the pass, and the world-pixel rectangle at that
  /// zoom the image covers.
  final double zoom;
  final double left, top, width, height;

  _HeatmapImage(
    this.image, {
    required this.zoom,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });
}

/// A pass's points for one layer, in batches by kernel radius — the
/// separable blur takes one radius per batch. A data-driven radius is
/// bucketed in 5 % steps, a difference no ramp shows.
class _GatheredPoints {
  final _batches = <int, _PointBuffer>{};
  _PointBuffer? _last;
  var count = 0;
  var minRadius = double.infinity;

  static final _logStep = math.log(1.05);

  _PointBuffer batchFor(double radius) {
    final last = _last;
    if (last != null && last.radius == radius) return last;
    if (radius < minRadius) minRadius = radius;
    final bucket = (math.log(radius) / _logStep).round();
    return _last = _batches[bucket] ??= _PointBuffer(radius);
  }

  /// The batches for a grid whose origin lies ([dx], [dy]) pixels up and
  /// left of the points' origin; [peakScale] turns a weight into the
  /// kernel's peak.
  List<HeatmapBatch> batches({
    required double dx,
    required double dy,
    required double peakScale,
  }) =>
      [
        for (final buffer in _batches.values)
          if (buffer.length > 0) buffer.toBatch(dx, dy, peakScale),
      ];
}

/// Growable typed storage for one batch's points: a plain `List<double>`
/// would box every coordinate.
class _PointBuffer {
  final double radius;
  var _xs = Float32List(256);
  var _ys = Float32List(256);
  var _weights = Float32List(256);
  var length = 0;

  _PointBuffer(this.radius);

  void add(double x, double y, double weight) {
    if (length == _xs.length) {
      _xs = _grow(_xs);
      _ys = _grow(_ys);
      _weights = _grow(_weights);
    }
    _xs[length] = x;
    _ys[length] = y;
    _weights[length] = weight;
    length++;
  }

  static Float32List _grow(Float32List list) =>
      Float32List(list.length * 2)..setRange(0, list.length, list);

  HeatmapBatch toBatch(double dx, double dy, double peakScale) {
    final xs = Float32List(length);
    final ys = Float32List(length);
    final peaks = Float32List(length);
    for (var i = 0; i < length; i++) {
      xs[i] = _xs[i] + dx;
      ys[i] = _ys[i] + dy;
      peaks[i] = _weights[i] * peakScale;
    }
    return HeatmapBatch(radius, xs, ys, peaks);
  }
}
