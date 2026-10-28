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
/// [skip], when set, leaves out part of the tile — see
/// [HeatmapTileInput.skip]: a tile of the level a zoom crossing is
/// leaving counts only where the arriving level has no points yet, or
/// the two would add up.
typedef HeatmapTile = ({
  TileKey key,
  List<HeatmapPoints> heatmap,
  Uint8List? skip,
});

/// Draws `heatmap` layers in screen space, as MapLibre does: one density
/// over every visible tile's points — a kernel reaches across tile seams
/// — coloured through `heatmap-color`, over the tile rasters.
///
/// The density is not recomputed per frame. A *pass* lists the tiles
/// and their points for a [HeatmapWorker] (an isolate on native
/// platforms), which places, culls and sums every point whose kernel
/// reaches the viewport plus a margin and colours the result; the pass
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

  /// Passes started, and the UI-thread time they took — listing the
  /// tiles and evaluating weights that read the zoom; everything per
  /// point runs on the worker. For tests and benchmarks.
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
  /// [tiles] is asked for the contributing tiles only when a pass runs.
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
    required Iterable<HeatmapTile> Function() tiles,
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
    required Iterable<HeatmapTile> Function() tiles,
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
    _pass(layers, cameraZoom, styleZoom, devicePixelRatio, tiles());
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
      final job = HeatmapJob(
        coverLeft: cover.left,
        coverTop: cover.top,
        coverWidth: cover.right - cover.left,
        coverHeight: cover.bottom - cover.top,
        devicePixelRatio: dpr,
        peakScale: math.max(0.0, layer.intensity.eval(zoomCtx)) *
            HeatmapGrid.peakFactor,
        ramp: _rampOf(layer, styleZoom),
        tiles: _inputs(layer, tileList, cameraZoom, styleZoom, cover),
      );
      _inFlight++;
      unawaited(_render(job).then((rendered) {
        _inFlight--;
        if (_disposed || sequence != _sequence) {
          rendered?.image.dispose();
          // A reset dropped this pass; the next paint owes a new one.
          if (!_disposed && _inFlight == 0) onChanged();
          return;
        }
        _images.remove(layer)?.image.dispose();
        if (rendered != null) {
          final (:image, :result) = rendered;
          _images[layer] = _HeatmapImage(
            image,
            zoom: cameraZoom,
            left: result.left,
            top: result.top,
            width: result.coverWidth,
            height: result.coverHeight,
          );
        }
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

  /// [job] rendered on the worker and uploaded; null when no point
  /// counted, or either step failed. The upload goes through
  /// [decodeRgbaPixels], not `ImageDescriptor.raw` — see there.
  Future<({ui.Image image, HeatmapResult result})?> _render(
      HeatmapJob job) async {
    final result = await (_worker ??= HeatmapWorker()).render(job);
    if (result == null || _disposed) return null;
    try {
      final image =
          await decodeRgbaPixels(result.pixels, result.width, result.height);
      return (image: image, result: result);
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
          final c = layer.color.eval(
              FeatureEvalContext(zoom: styleZoom, heatmapDensity: i / 255));
          ramp[i] = HeatmapGrid.packRgba(c.r, c.g, c.b, c.a);
        }
        return ramp;
      }();

  /// [layer]'s points in each of [tiles], placed relative to [cover] —
  /// one entry per tile, its weights and radii evaluated at [styleZoom].
  static List<HeatmapTileInput> _inputs(
    HeatmapThemeLayer layer,
    List<HeatmapTile> tiles,
    double cameraZoom,
    double styleZoom,
    ({double left, double top, double right, double bottom}) cover,
  ) {
    final zoomCtx = EvalContext(zoom: styleZoom);
    final out = <HeatmapTileInput>[];
    for (final tile in tiles) {
      HeatmapPoints? points;
      for (final p in tile.heatmap) {
        if (identical(p.layer, layer)) points = p;
      }
      if (points == null || points.length == 0) continue;
      final weights = points.weightsAt(styleZoom);
      final weight = weights == null ? layer.weight.eval(zoomCtx) : 0.0;
      if (weights == null && !(weight > 0)) continue;
      final radii = points.radiiAt(styleZoom);
      final radius = radii == null ? layer.radius.eval(zoomCtx) : 0.0;
      if (radii == null && !(radius > 0)) continue;
      final rect = displayTileRect(tile.key, cameraZoom);
      out.add(HeatmapTileInput(
        left: rect.left - cover.left,
        top: rect.top - cover.top,
        scale: rect.width / displayTileSize,
        xy: points.xy,
        weights: weights,
        weight: weight,
        radii: radii,
        radius: radius,
        skip: tile.skip,
      ));
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
