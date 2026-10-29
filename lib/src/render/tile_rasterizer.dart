import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

import '../core/tile_key.dart';
import '../core/tile_zoom.dart';
import '../grid/raster_tile_store.dart';
import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import 'display_tile_data.dart';
import 'geometry_clipper.dart';
import 'hillshade_renderer.dart';
import 'matched_features.dart';
import 'pattern_resolver.dart';

/// Renders the geometry layers (background/fill/line/circle) of one
/// display tile into a GPU-resident [ui.Image].
///
/// Rasterization happens once per (display tile, integer zoom); the
/// per-frame cost of the map is then just drawing textures. Symbol layers
/// are *not* painted here: in `LabelMode.screen` they are drawn per frame
/// in screen space by the label pass, and in `LabelMode.tile` the layer
/// draws them over the geometry [recordSlice] recorded (and [compose]
/// stacked) before taking its [toImage].
class TileRasterizer {
  /// Logical tile size in points — the one shared constant, see
  /// `core/tile_zoom.dart`.
  static const double logicalTileSize = displayTileSize;

  /// Logical-px margin kept around the display tile when culling:
  /// covers stroke half-widths incl. casing (`gap + 2·width`) up to
  /// 128px and circle radius + stroke up to 64px, and keeps
  /// clip-boundary artifacts outside the visible canvas clip.
  static const double cullBufferPx = 64;

  /// Disables feature culling and overzoom clipping. Pixel-equivalence
  /// tests render with and without it to prove neither changes output.
  @visibleForTesting
  static bool debugDisableCulling = false;

  /// Tiles rasterized; for tests asserting that cached results are
  /// reused instead of re-rendered.
  @visibleForTesting
  static int debugRasterizeCount = 0;

  /// [recordSlice] calls, of which a tile recorded in one go makes one;
  /// for tests asserting that recordings are spread over frames.
  @visibleForTesting
  static int debugSliceCount = 0;

  /// UI-thread microseconds spent inside [rasterize] — picture recording
  /// ([record]) plus `toImageSync` ([toImage]). Accumulates forever; the
  /// bench diffs it per frame to attribute build-time spikes to their
  /// phase.
  @visibleForTesting
  static int debugRasterizeMicros = 0;

  /// UI-thread microseconds spent painting each theme layer, keyed by
  /// layer id. Accumulates forever; the bench diffs and ranks it to name
  /// the layers an expensive tile spends its recording time in.
  @visibleForTesting
  static final Map<String, int> debugLayerMicros = <String, int>{};

  /// Overzoom depth from which geometry is clipped to the display
  /// window. Below it a full-extent path is at most ~2 tiles long and
  /// clipping would be pure overhead; from shift 2 path length doubles
  /// per level and dash/stamp/tessellation cost grows with it.
  static const int _clipMinShift = 2;

  /// Records and rasterizes the tile. [devicePixelRatio] controls the
  /// backing resolution. Returns null when there is nothing to draw.
  static ui.Image? rasterize({
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
    required double devicePixelRatio,
    PatternResolver? patterns,
  }) {
    final picture = record(
      theme: theme,
      data: data,
      styleZoom: styleZoom,
      devicePixelRatio: devicePixelRatio,
      patterns: patterns,
    );
    return picture == null ? null : toImage(picture, devicePixelRatio);
  }

  /// The backing size in device pixels of a tile at [devicePixelRatio]:
  /// its rasters are square, this many pixels on a side.
  static int pixelSizeFor(double devicePixelRatio) =>
      (logicalTileSize * devicePixelRatio).ceil();

  /// The scale from logical tile units to the backing pixels: what a
  /// canvas recording a tile is scaled by, and therefore its effective
  /// device pixel ratio.
  static double pixelScaleFor(double devicePixelRatio) =>
      pixelSizeFor(devicePixelRatio) / logicalTileSize;

  /// Records the tile's geometry without rasterizing it, in backing
  /// pixels clipped to the tile — [rasterize] minus the `toImageSync`.
  /// Returns null when there is nothing to draw.
  ///
  /// For a caller that draws more on top before taking the image, as
  /// `LabelMode.tile` does with the tile's labels: nesting the picture
  /// in that recording costs one snapshot per tile instead of two.
  static ui.Picture? record({
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
    required double devicePixelRatio,
    PatternResolver? patterns,
  }) =>
      recordSlice(
        theme: theme,
        data: data,
        styleZoom: styleZoom,
        devicePixelRatio: devicePixelRatio,
        patterns: patterns,
      ).picture;

  /// [record] spread over several calls: records the theme layers from
  /// [from] on, and stops at the first layer boundary at which
  /// [outOfBudget] returns true — always after at least one layer, so
  /// every call makes progress. A dense tile's recording costs tens of
  /// milliseconds on a phone, all of it on the UI thread, and the only
  /// place it can be cut without changing the result is between two
  /// layers: each one is drawn whole, in order, with its own paints.
  ///
  /// Returns the slice's picture (null when it drew nothing) and the
  /// index to resume from, which is `theme.layers.length` once the tile
  /// is done. Each slice is clipped and scaled like [record]'s picture,
  /// so [compose] stacks them into exactly the picture [record] would
  /// have made.
  static ({ui.Picture? picture, int next}) recordSlice({
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
    required double devicePixelRatio,
    PatternResolver? patterns,
    int from = 0,
    bool Function()? outOfBudget,
  }) {
    if (from == 0) debugRasterizeCount++;
    debugSliceCount++;
    final stopwatch = Stopwatch()..start();
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final pixelSize = pixelSizeFor(devicePixelRatio);
      canvas.clipRect(
          Rect.fromLTWH(0, 0, pixelSize.toDouble(), pixelSize.toDouble()));
      final pixelScale = pixelScaleFor(devicePixelRatio);
      canvas.scale(pixelScale);

      final (:painted, :next) = _paintLayers(
        canvas: canvas,
        theme: theme,
        data: data,
        styleZoom: styleZoom,
        pixelScale: pixelScale,
        patterns: patterns,
        from: from,
        outOfBudget: outOfBudget,
      );

      final picture = recorder.endRecording();
      if (!painted) {
        picture.dispose();
        return (picture: null, next: next);
      }
      return (picture: picture, next: next);
    } finally {
      debugRasterizeMicros += stopwatch.elapsedMicroseconds;
    }
  }

  /// One picture of [parts] — [recordSlice]'s pictures in the order
  /// they were recorded — which takes ownership of them: they are
  /// disposed here unless a single part is returned as it is. Null when
  /// there are none.
  static ui.Picture? compose(List<ui.Picture> parts) {
    if (parts.length <= 1) return parts.isEmpty ? null : parts.single;
    final stopwatch = Stopwatch()..start();
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (final part in parts) {
        canvas.drawPicture(part);
      }
      final picture = recorder.endRecording();
      for (final part in parts) {
        part.dispose();
      }
      return picture;
    } finally {
      debugRasterizeMicros += stopwatch.elapsedMicroseconds;
    }
  }

  /// Rasterizes [picture] — recorded in backing pixels, as [record]
  /// does — into a tile image at [devicePixelRatio], and disposes it.
  static ui.Image toImage(ui.Picture picture, double devicePixelRatio) {
    final stopwatch = Stopwatch()..start();
    try {
      final pixelSize = pixelSizeFor(devicePixelRatio);
      final image = picture.toImageSync(pixelSize, pixelSize);
      picture.dispose();
      return image;
    } finally {
      debugRasterizeMicros += stopwatch.elapsedMicroseconds;
    }
  }

  /// Paints geometry layers onto [canvas] in logical tile coordinates
  /// (0..256). [pixelScale] is what [canvas] scales those by to reach
  /// device pixels, so that fill outlines come out one pixel wide.
  /// Returns whether anything was drawn.
  static bool paint({
    required Canvas canvas,
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
    double pixelScale = 1,
    PatternResolver? patterns,
  }) =>
      _paintLayers(
        canvas: canvas,
        theme: theme,
        data: data,
        styleZoom: styleZoom,
        pixelScale: pixelScale,
        patterns: patterns,
      ).painted;

  /// [paint] from layer [from] on, stopping before the next layer that
  /// would draw once [outOfBudget] says so — after at least one such
  /// layer. Returns whether anything was drawn, and where to resume:
  /// `theme.layers.length` when every layer is done.
  static ({bool painted, int next}) _paintLayers({
    required Canvas canvas,
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
    required double pixelScale,
    PatternResolver? patterns,
    int from = 0,
    bool Function()? outOfBudget,
  }) {
    var painted = false;
    var drewLayer = false;
    final zoomCtx = EvalContext(zoom: styleZoom);

    final layers = theme.layers;
    final layerStopwatch = Stopwatch();
    for (var i = from; i < layers.length; i++) {
      final layer = layers[i];
      // Skipped before the budget check, so that a slice never ends on —
      // and the next one never starts with — a layer that draws nothing.
      if (layer is SymbolThemeLayer || !layer.coversZoom(styleZoom)) continue;
      if (drewLayer && (outOfBudget?.call() ?? false)) {
        return (painted: painted, next: i);
      }
      drewLayer = true;
      layerStopwatch
        ..reset()
        ..start();
      switch (layer) {
        case BackgroundThemeLayer():
          final opacity = layer.opacity.eval(zoomCtx).clamp(0.0, 1.0);
          final color = _withOpacity(layer.color.eval(zoomCtx), opacity);
          if (color.a == 0) continue;
          canvas.drawRect(
            const Rect.fromLTWH(
                -4, -4, logicalTileSize + 8, logicalTileSize + 8),
            Paint()..color = color,
          );
          painted = true;
        case FillThemeLayer():
          painted |=
              _paintFill(canvas, layer, data, styleZoom, patterns, pixelScale);
        case LineThemeLayer():
          painted |= _paintLine(canvas, layer, data, styleZoom, patterns);
        case RasterThemeLayer():
          painted |= _paintRaster(canvas, layer, data, zoomCtx);
        case HillshadeThemeLayer():
          painted |= HillshadeRenderer.paint(canvas, layer, data, zoomCtx);
        case CircleThemeLayer():
          painted |= _paintCircle(canvas, layer, data, styleZoom);
        case SymbolThemeLayer():
          break; // skipped above: the label pass, in screen or tile space
      }
      debugLayerMicros[layer.id] = (debugLayerMicros[layer.id] ?? 0) +
          layerStopwatch.elapsedMicroseconds;
    }
    return (painted: painted, next: layers.length);
  }

  /// Iterates the features of [layer]'s source-layer, calling [visit]
  /// with the feature, its evaluation context (already used for the
  /// layer filter — visitors must not rebuild it), the
  /// tile-to-logical-pixels transform, and — at overzoom, for features
  /// not fully inside the buffered display window — the clip window in
  /// tile-extent units.
  static void _eachFeature(
    ThemeLayer layer,
    DisplayTileData data,
    double styleZoom,
    PreparedGeomType? typeFilter,
    void Function(PreparedFeature feature, EvalContext ctx,
            _TileTransform transform, ClipRect? clip)
        visit,
  ) {
    final source = layer.source;
    final sourceLayerName = layer.sourceLayer;
    if (source == null || sourceLayerName == null) return;
    final tile = data.sources[source];
    if (tile != null) {
      _eachFeatureIn(
          layer, data, tile, sourceLayerName, styleZoom, typeFilter, visit);
      return;
    }
    // Zoom-out substitution: no tile of its own, but cached descendants
    // composing a (possibly partial) provisional cover. Iterating them
    // here — inside the theme-layer loop — keeps layer ordering intact
    // across the whole display tile.
    final descendants = data.descendantSources[source];
    if (descendants == null) return;
    for (final descendant in descendants) {
      _eachFeatureIn(layer, data, descendant, sourceLayerName, styleZoom,
          typeFilter, visit);
    }
  }

  static void _eachFeatureIn(
    ThemeLayer layer,
    DisplayTileData data,
    PreparedTile tile,
    String sourceLayerName,
    double styleZoom,
    PreparedGeomType? typeFilter,
    void Function(PreparedFeature feature, EvalContext ctx,
            _TileTransform transform, ClipRect? clip)
        visit,
  ) {
    final sourceLayer = tile.layers[sourceLayerName];
    if (sourceLayer == null) return;

    final transform = _TileTransform.forDisplay(
        data.displayKey, tile.key, sourceLayer.extent);

    // The display tile's sub-rect in tile-extent units, expanded by
    // [cullBufferPx]. At overzoom each display tile shows a tiny window
    // of the data tile; rejecting features on their decode-time bounds
    // before any expression work is what keeps deep zooms affordable.
    final cull = !debugDisableCulling;
    final cullMinX = (-cullBufferPx - transform.offsetX) / transform.scale;
    final cullMaxX =
        (logicalTileSize + cullBufferPx - transform.offsetX) / transform.scale;
    final cullMinY = (-cullBufferPx - transform.offsetY) / transform.scale;
    final cullMaxY =
        (logicalTileSize + cullBufferPx - transform.offsetY) / transform.scale;

    final shift = data.displayKey.z - tile.key.z;
    // At deep overzoom, clip to the display window (see [_clipMinShift]).
    // A descendant (shift < 0) is clipped to its own extent instead: its
    // buffer geometry must not spill into the sub-square a neighbouring
    // — possibly missing — descendant owns. That clip is semantic, not
    // an optimisation, so [debugDisableCulling] leaves it on.
    final clip = shift < 0
        ? ClipRect(
            0, 0, sourceLayer.extent.toDouble(), sourceLayer.extent.toDouble())
        : cull && shift >= _clipMinShift
            ? ClipRect(cullMinX, cullMinY, cullMaxX, cullMaxY)
            : null;

    // A zoom-free filter was resolved once for the whole prepared tile;
    // only a zoom-reading one is still tested here, per display tile.
    final matched = MatchedFeatures.of(layer, sourceLayer, tile: tile.key);
    final readsGeometry = layer.readsGeometry;
    for (final feature in matched ?? sourceLayer.features) {
      if (typeFilter != null && feature.type != typeFilter) continue;
      if (cull &&
          (feature.maxX < cullMinX ||
              feature.minX > cullMaxX ||
              feature.maxY < cullMinY ||
              feature.minY > cullMaxY)) {
        continue;
      }
      final ctx = featureContext(
        zoom: styleZoom,
        properties: feature.properties,
        geometryType: feature.geometryType,
        featureId: feature.id,
        geometry: readsGeometry
            ? featureGeometry(tile.key, sourceLayer, feature)
            : null,
      );
      if (matched == null && !layer.matches(ctx)) continue;
      // Fully-contained geometry takes the exact unclipped path.
      final featureClip = clip != null &&
              !clip.containsBounds(
                  feature.minX, feature.minY, feature.maxX, feature.maxY)
          ? clip
          : null;
      visit(feature, ctx, transform, featureClip);
    }
  }

  static bool _paintFill(
    Canvas canvas,
    FillThemeLayer layer,
    DisplayTileData data,
    double styleZoom,
    PatternResolver? patterns,
    double pixelScale,
  ) {
    if (layer.extrusion) {
      return _paintExtrusion(canvas, layer, data, styleZoom, patterns);
    }
    var painted = false;
    final zoomCtx = EvalContext(zoom: styleZoom);
    final patternProp = layer.pattern;
    // MapLibre's outline is its antialiasing pass, one device pixel wide
    // at any zoom, and `fill-antialias: false` turns it off.
    final outline = layer.antialias ? layer.outlineColor : null;
    // The fill paint is per-layer when neither the colour nor the opacity
    // reads the feature, which makes both constant across this tile. It
    // has to be asked of each one: `["id"]` and `["geometry-type"]` read
    // the feature without naming a property.
    final constant = patternProp == null &&
        (layer.color.isConstant || layer.color.zoomOnly) &&
        (layer.opacity.isConstant || layer.opacity.zoomOnly);
    Paint? fillPaint;
    double? sharedOpacity;
    if (constant) {
      final opacity = layer.opacity.eval(zoomCtx).clamp(0.0, 1.0);
      sharedOpacity = opacity;
      final color = _withOpacity(layer.color.eval(zoomCtx), opacity);
      if (color.a == 0 && (outline == null || opacity == 0)) {
        return false;
      }
      fillPaint = Paint()
        ..color = color
        ..isAntiAlias = layer.antialias;
    }

    _eachFeature(layer, data, styleZoom, PreparedGeomType.polygon,
        (feature, ctx, transform, clip) {
      final path = _polygonPath(feature, transform, clip);
      if (path == null) return;
      if (patternProp != null && patterns != null) {
        final name = patternProp.eval(ctx);
        final image = name.isEmpty ? null : patterns.imageFor(name);
        if (image != null) {
          final opacity = layer.opacity.eval(ctx).clamp(0.0, 1.0);
          if (opacity > 0) {
            canvas.drawPath(
              path,
              _patternPaint(image, patterns.pixelRatio, opacity,
                  data.displayKey, layer.antialias),
            );
            painted = true;
          }
          // Per spec, fill-pattern disables fill-color and outline.
          return;
        }
        // Sprite missing: fall through to the color fill.
      }
      final opacity = sharedOpacity ?? layer.opacity.eval(ctx).clamp(0.0, 1.0);
      final paint = fillPaint ??
          (Paint()
            ..color = _withOpacity(layer.color.eval(ctx), opacity)
            ..isAntiAlias = layer.antialias);
      if (paint.color.a > 0) {
        canvas.drawPath(path, paint);
        painted = true;
      }
      // `fill-opacity` dims the outline too, as MapLibre's outline shader
      // multiplies it in; only the alpha of `fill-color` leaves it alone.
      if (outline != null && opacity > 0) {
        final color = _withOpacity(outline.eval(ctx), opacity);
        if (color.a > 0) {
          canvas.drawPath(
            path,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1 / pixelScale,
          );
          painted = true;
        }
      }
    });
    return painted;
  }

  /// [_paintFill] for a `fill-extrusion` layer, drawn flat from above.
  ///
  /// `fill-extrusion-opacity` is the opacity of the whole layer, which
  /// MapLibre renders to one buffer and blends once: where a building
  /// part overlaps its outline, the overlap is no darker than either.
  /// It is also the only translucency an extrusion has — the spec
  /// ignores the alpha of `fill-extrusion-color` — so every building is
  /// drawn opaque into that buffer. With one colour for the whole layer
  /// the buffer is a single path, drawn with the opacity in its paint:
  /// the non-zero rule fills the union once, given MVT's winding, and
  /// one call is cheaper than a path per building. A colour that varies
  /// by feature, or a pattern, needs a layer to composite instead; the
  /// opacity itself never varies by feature, the spec forbids it.
  static bool _paintExtrusion(
    Canvas canvas,
    FillThemeLayer layer,
    DisplayTileData data,
    double styleZoom,
    PatternResolver? patterns,
  ) {
    final zoomCtx = EvalContext(zoom: styleZoom);
    final opacity = layer.opacity.eval(zoomCtx).clamp(0.0, 1.0);
    if (opacity == 0) return false;
    final patternProp = layer.pattern;
    // Asked of the colour itself, as for fills: `["id"]` and
    // `["geometry-type"]` read the feature without naming a property.
    final oneColour =
        patternProp == null && (layer.color.isConstant || layer.color.zoomOnly);
    if (oneColour) {
      final union = Path()..fillType = PathFillType.nonZero;
      var any = false;
      _eachFeature(layer, data, styleZoom, PreparedGeomType.polygon,
          (feature, ctx, transform, clip) {
        any |= _addPolygon(union, feature, transform, clip);
      });
      if (!any) return false;
      canvas.drawPath(
          union,
          Paint()
            ..color = layer.color.eval(zoomCtx).withValues(alpha: opacity)
            ..isAntiAlias = layer.antialias);
      return true;
    }

    var painted = false;
    if (opacity < 1) {
      canvas.saveLayer(null, Paint()..color = Color.fromRGBO(0, 0, 0, opacity));
    }
    _eachFeature(layer, data, styleZoom, PreparedGeomType.polygon,
        (feature, ctx, transform, clip) {
      final path = _polygonPath(feature, transform, clip);
      if (path == null) return;
      if (patternProp != null && patterns != null) {
        final name = patternProp.eval(ctx);
        final image = name.isEmpty ? null : patterns.imageFor(name);
        if (image != null) {
          canvas.drawPath(
            path,
            _patternPaint(image, patterns.pixelRatio, 1, data.displayKey,
                layer.antialias),
          );
          painted = true;
          return;
        }
        // Sprite missing: fall through to the colour, as a fill does.
      }
      canvas.drawPath(
          path,
          Paint()
            ..color = layer.color.eval(ctx).withValues(alpha: 1)
            ..isAntiAlias = layer.antialias);
      painted = true;
    });
    if (opacity < 1) canvas.restore();
    return painted;
  }

  static bool _paintLine(
    Canvas canvas,
    LineThemeLayer layer,
    DisplayTileData data,
    double styleZoom,
    PatternResolver? patterns,
  ) {
    var painted = false;
    final patternProp = layer.pattern;

    // A stroke style none of whose properties reads the feature is
    // constant across the whole tile, so resolve it once instead of
    // re-evaluating 5-7 expressions per feature. Asked of each property,
    // as for fills: `["id"]` and `["geometry-type"]` read the feature
    // without naming a property.
    final dashProp = layer.dashArray;
    _LineStyle? shared;
    if (patternProp == null &&
        (layer.color.isConstant || layer.color.zoomOnly) &&
        (layer.width.isConstant || layer.width.zoomOnly) &&
        (layer.opacity.isConstant || layer.opacity.zoomOnly) &&
        (layer.gapWidth.isConstant || layer.gapWidth.zoomOnly) &&
        (dashProp == null || dashProp.isConstant || dashProp.zoomOnly) &&
        (layer.cap.isConstant || layer.cap.zoomOnly) &&
        (layer.join.isConstant || layer.join.zoomOnly)) {
      shared = _lineStyle(layer, EvalContext(zoom: styleZoom));
      if (shared == null) return false; // invisible at this zoom
    }

    _eachFeature(layer, data, styleZoom, null, (feature, ctx, transform, clip) {
      if (feature.type == PreparedGeomType.point) return;

      final closeRuns = feature.type == PreparedGeomType.polygon;

      if (patternProp != null && patterns != null) {
        final width = layer.width.eval(ctx);
        if (width <= 0) return;
        final opacity = layer.opacity.eval(ctx).clamp(0.0, 1.0);
        if (opacity <= 0) return;
        final name = patternProp.eval(ctx);
        final image = name.isEmpty ? null : patterns.imageFor(name);
        if (image != null) {
          if (clip == null) {
            painted |= _stampLinePattern(
                canvas, _linePath(feature, transform), image, width, opacity);
          } else {
            for (final part in feature.parts) {
              final clipped = clipPolyline(part, clip, close: closeRuns);
              for (var r = 0; r < clipped.runs.length; r++) {
                final sub = Path();
                _addRun(sub, clipped.runs[r], transform,
                    close: clipped.closed[r]);
                painted |= _stampLinePattern(canvas, sub, image, width, opacity,
                    phaseLogicalPx:
                        clipped.startDistances[r] * transform.scale);
              }
            }
          }
          // Per spec, line-pattern disables line-color and dashes.
          return;
        }
        // Sprite missing: fall through to the color stroke.
      }

      final style = shared ?? _lineStyle(layer, ctx);
      if (style == null) return;

      final dashArray = style.dash;
      final dash =
          dashArray != null && dashArray.length >= 2 ? dashArray : null;
      // Dash lengths are specified in multiples of line width.
      final dashes = dash
          ?.map((d) => (d * style.width).clamp(0.01, 4096.0))
          .toList(growable: false);
      Path path;
      if (clip == null) {
        if (dashes != null) {
          path = Path();
          for (final part in feature.parts) {
            _dashRun(path, part, transform, dashes, close: closeRuns);
          }
        } else {
          path = _linePath(feature, transform);
        }
      } else {
        path = Path();
        for (final part in feature.parts) {
          final clipped = clipPolyline(part, clip, close: closeRuns);
          for (var r = 0; r < clipped.runs.length; r++) {
            if (dashes != null) {
              _dashRun(path, clipped.runs[r], transform, dashes,
                  close: clipped.closed[r],
                  phaseLogicalPx: clipped.startDistances[r] * transform.scale);
            } else {
              _addRun(path, clipped.runs[r], transform,
                  close: clipped.closed[r]);
            }
          }
        }
      }

      if (style.gapWidth > 0) {
        // Two parallel casing strokes: outer stroke minus inner gap.
        // Fresh paints — the shared style's Paint must not be mutated.
        // The BlendMode.clear must only ever erase this feature's own
        // outer stroke (another feature's casing crossing the gap must
        // survive, as in MapLibre), so each feature needs its own
        // layer — but bounded to the stroked path rather than the whole
        // tile: an unbounded saveLayer allocates a full-tile offscreen
        // per casing feature. Inflate by 2·outer: miter joins reach up
        // to miterLimit/2 (= 2) stroke widths past a vertex.
        final outer = style.gapWidth + 2 * style.width;
        canvas.saveLayer(path.getBounds().inflate(outer * 2), Paint());
        canvas.drawPath(
          path,
          Paint()
            ..color = style.paint.color
            ..style = PaintingStyle.stroke
            ..strokeWidth = outer
            ..strokeCap = style.paint.strokeCap
            ..strokeJoin = style.paint.strokeJoin,
        );
        canvas.drawPath(
          path,
          Paint()
            ..blendMode = BlendMode.clear
            ..style = PaintingStyle.stroke
            ..strokeWidth = style.gapWidth
            ..strokeCap = style.paint.strokeCap
            ..strokeJoin = style.paint.strokeJoin,
        );
        canvas.restore();
      } else {
        canvas.drawPath(path, style.paint);
      }
      painted = true;
    });
    return painted;
  }

  /// The resolved stroke style for one evaluation context, or null when
  /// nothing would be visible.
  static _LineStyle? _lineStyle(LineThemeLayer layer, EvalContext ctx) {
    final width = layer.width.eval(ctx);
    if (width <= 0) return null;
    final opacity = layer.opacity.eval(ctx).clamp(0.0, 1.0);
    if (opacity <= 0) return null;
    final color = _withOpacity(layer.color.eval(ctx), opacity);
    if (color.a == 0) return null;
    return _LineStyle(
      width: width,
      gapWidth: layer.gapWidth.eval(ctx),
      dash: layer.dashArray?.eval(ctx),
      paint: Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = _cap(layer.cap.eval(ctx))
        ..strokeJoin = _join(layer.join.eval(ctx)),
    );
  }

  /// Draws `line-pattern` by stamping the sprite along the path, scaled
  /// so the sprite height matches the line width (aspect ratio kept) and
  /// rotated to the local line direction — MapLibre semantics.
  ///
  /// [phaseLogicalPx] is how far along the *original* (un-clipped)
  /// geometry this path starts; stamp positions are offset so they land
  /// exactly where the full path would put them, keeping stamps aligned
  /// across clip boundaries and display-tile seams.
  static bool _stampLinePattern(
    Canvas canvas,
    Path path,
    ui.Image image,
    double width,
    double opacity, {
    double phaseLogicalPx = 0,
  }) {
    final scale = width / image.height;
    final stampLength = image.width * scale;
    if (stampLength < 0.5) return false;
    // Dart's % is non-negative for a positive divisor, so this is the
    // first global stamp center at or past the path start.
    final firstStamp = (stampLength / 2 - phaseLogicalPx) % stampLength;
    final src =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final anchorX = image.width / 2;
    final anchorY = image.height / 2;
    final transforms = <ui.RSTransform>[];
    final rects = <Rect>[];
    for (final metric in path.computeMetrics()) {
      for (var d = firstStamp; d < metric.length; d += stampLength) {
        final tangent = metric.getTangentForOffset(d);
        if (tangent == null) continue;
        transforms.add(ui.RSTransform.fromComponents(
          // Tangent.angle is measured y-up; canvas rotation is y-down.
          rotation: -tangent.angle,
          scale: scale,
          anchorX: anchorX,
          anchorY: anchorY,
          translateX: tangent.position.dx,
          translateY: tangent.position.dy,
        ));
        rects.add(src);
      }
    }
    if (transforms.isEmpty) return false;
    canvas.drawAtlas(
      image,
      transforms,
      rects,
      opacity < 1
          ? List.filled(
              transforms.length, Color.fromRGBO(255, 255, 255, opacity))
          : null,
      opacity < 1 ? BlendMode.modulate : null,
      null,
      Paint()..filterQuality = FilterQuality.medium,
    );
    return true;
  }

  static bool _paintRaster(
    Canvas canvas,
    RasterThemeLayer layer,
    DisplayTileData data,
    EvalContext zoomCtx,
  ) {
    final primary = data.rasters[layer.source];
    // Zoom-out substitution mirrors the vector path: with no tile of
    // its own, cached descendants compose a (possibly partial) cover.
    final tiles = primary != null
        ? [primary]
        : data.descendantRasters[layer.source] ?? const <RasterTile>[];
    if (tiles.isEmpty) return false;
    final opacity = layer.opacity.eval(zoomCtx).clamp(0.0, 1.0);
    if (opacity <= 0) return false;
    final paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = false
      ..color = Color.fromRGBO(255, 255, 255, opacity)
      ..colorFilter = _rasterColorFilter(layer, zoomCtx);
    for (final raster in tiles) {
      final image = raster.image;
      if (raster.key.z <= data.displayKey.z) {
        // The data tile may be an ancestor (overzoom / 512px
        // convention): draw the sub-region covering this display tile.
        final frac = data.displayKey.fractionOf(raster.key);
        final src = Rect.fromLTWH(
          frac.dx * image.width,
          frac.dy * image.height,
          frac.scale * image.width,
          frac.scale * image.height,
        );
        canvas.drawImageRect(image, src,
            const Rect.fromLTWH(0, 0, logicalTileSize, logicalTileSize), paint);
      } else {
        // A descendant standing in on zoom-out: draw it whole into its
        // sub-square of the display tile.
        final frac = raster.key.fractionOf(data.displayKey);
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromLTWH(
            frac.dx * logicalTileSize,
            frac.dy * logicalTileSize,
            frac.scale * logicalTileSize,
            frac.scale * logicalTileSize,
          ),
          paint,
        );
      }
    }
    return true;
  }

  /// Builds a color matrix replicating MapLibre's raster fragment shader:
  /// hue-rotate (spin), then saturation, then contrast, then the
  /// brightness-min/max mix — including MapLibre's exact factor formulas.
  /// Returns null when every property is at its default.
  static ui.ColorFilter? _rasterColorFilter(
      RasterThemeLayer layer, EvalContext ctx) {
    final hueRotate = layer.hueRotate.eval(ctx) % 360;
    final saturation = layer.saturation.eval(ctx).clamp(-1.0, 1.0);
    final contrast = layer.contrast.eval(ctx).clamp(-1.0, 1.0);
    final brightnessMin = layer.brightnessMin.eval(ctx).clamp(0.0, 1.0);
    final brightnessMax = layer.brightnessMax.eval(ctx).clamp(0.0, 1.0);
    if (hueRotate == 0 &&
        saturation == 0 &&
        contrast == 0 &&
        brightnessMin == 0 &&
        brightnessMax == 1) {
      return null;
    }

    List<double>? m;
    List<double> apply(List<double> next) {
      final current = m;
      return current == null ? next : _multiplyColorMatrix(next, current);
    }

    if (hueRotate != 0) {
      final rad = hueRotate * math.pi / 180;
      final s = math.sin(rad);
      final c = math.cos(rad);
      // MapLibre's spin weights: an RGB rotation about the gray axis.
      final w0 = (2 * c + 1) / 3;
      final w1 = (-math.sqrt(3) * s - c + 1) / 3;
      final w2 = (math.sqrt(3) * s - c + 1) / 3;
      m = apply([
        w0, w1, w2, 0, 0, //
        w2, w0, w1, 0, 0, //
        w1, w2, w0, 0, 0, //
        0, 0, 0, 1, 0,
      ]);
    }
    if (saturation != 0) {
      // rgb += (average - rgb) * f, with MapLibre's factor curve.
      final f = saturation > 0 ? 1 - 1 / (1.001 - saturation) : -saturation;
      final d = 1 - f;
      final a = f / 3;
      m = apply([
        d + a, a, a, 0, 0, //
        a, d + a, a, 0, 0, //
        a, a, d + a, 0, 0, //
        0, 0, 0, 1, 0,
      ]);
    }
    if (contrast != 0) {
      // rgb = (rgb - 0.5) * f + 0.5, with MapLibre's factor curve.
      final f =
          (contrast > 0 ? 1 / (1 - contrast) : 1 + contrast).clamp(0.0, 1000.0);
      final offset = (0.5 - 0.5 * f) * 255;
      m = apply([
        f, 0, 0, 0, offset, //
        0, f, 0, 0, offset, //
        0, 0, f, 0, offset, //
        0, 0, 0, 1, 0,
      ]);
    }
    if (brightnessMin != 0 || brightnessMax != 1) {
      // rgb = mix(min, max, rgb).
      final scale = brightnessMax - brightnessMin;
      final offset = brightnessMin * 255;
      m = apply([
        scale, 0, 0, 0, offset, //
        0, scale, 0, 0, offset, //
        0, 0, scale, 0, offset, //
        0, 0, 0, 1, 0,
      ]);
    }
    return ui.ColorFilter.matrix(m!);
  }

  /// Composes two 4x5 color matrices: the result applies [b] first,
  /// then [a].
  static List<double> _multiplyColorMatrix(List<double> a, List<double> b) {
    final out = List<double>.filled(20, 0);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 5; col++) {
        var v = col == 4 ? a[row * 5 + 4] : 0.0;
        for (var k = 0; k < 4; k++) {
          v += a[row * 5 + k] * b[k * 5 + col];
        }
        out[row * 5 + col] = v;
      }
    }
    return out;
  }

  static bool _paintCircle(
    Canvas canvas,
    CircleThemeLayer layer,
    DisplayTileData data,
    double styleZoom,
  ) {
    var painted = false;
    _eachFeature(layer, data, styleZoom, PreparedGeomType.point,
        (feature, ctx, transform, clip) {
      final radius = layer.radius.eval(ctx);
      if (radius <= 0) return;
      final fill = _withOpacity(
          layer.color.eval(ctx), layer.opacity.eval(ctx).clamp(0.0, 1.0));
      final strokeWidth = layer.strokeWidth.eval(ctx);
      final stroke = strokeWidth > 0
          ? _withOpacity(layer.strokeColor.eval(ctx),
              layer.strokeOpacity.eval(ctx).clamp(0.0, 1.0))
          : null;
      // One pair of paints per feature, not per point — multipoint
      // features used to allocate two paints in the innermost loop.
      final fillPaint = fill.a > 0 ? (Paint()..color = fill) : null;
      final strokePaint = stroke != null && stroke.a > 0
          ? (Paint()
            ..color = stroke
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth)
          : null;
      if (fillPaint == null && strokePaint == null) return;
      // Per-point rejection: a multipoint feature that straddles the
      // cull rect can still carry thousands of far-away points at deep
      // overzoom.
      final reach = radius + strokeWidth;
      for (final part in feature.parts) {
        for (var i = 0; i + 1 < part.length; i += 2) {
          final center = transform.map(part[i], part[i + 1]);
          if (!debugDisableCulling &&
              (center.dx < -reach ||
                  center.dy < -reach ||
                  center.dx > logicalTileSize + reach ||
                  center.dy > logicalTileSize + reach)) {
            continue;
          }
          if (fillPaint != null) {
            canvas.drawCircle(center, radius, fillPaint);
            painted = true;
          }
          if (strokePaint != null) {
            canvas.drawCircle(center, radius, strokePaint);
            painted = true;
          }
        }
      }
    });
    return painted;
  }

  /// Builds the fill path, clipping each ring to [clip] when set.
  /// Returns null when every ring clips away entirely.
  static Path? _polygonPath(
      PreparedFeature feature, _TileTransform t, ClipRect? clip) {
    final path = Path()..fillType = PathFillType.nonZero;
    return _addPolygon(path, feature, t, clip) ? path : null;
  }

  /// Adds [feature]'s rings to [path]; whether any survived [clip].
  static bool _addPolygon(
      Path path, PreparedFeature feature, _TileTransform t, ClipRect? clip) {
    var any = false;
    for (final ring in feature.parts) {
      if (clip == null) {
        _addRun(path, ring, t, close: true);
        any = true;
      } else {
        final clipped = clipRing(ring, clip);
        if (clipped != null) {
          _addRun(path, clipped, t, close: true);
          any = true;
        }
      }
    }
    return any;
  }

  static Path _linePath(PreparedFeature feature, _TileTransform t) {
    final path = Path();
    for (final run in feature.parts) {
      _addRun(path, run, t, close: feature.type == PreparedGeomType.polygon);
    }
    return path;
  }

  static void _addRun(Path path, Float32List run, _TileTransform t,
      {required bool close}) {
    if (run.length < 4) return;
    path.moveTo(t.mapX(run[0]), t.mapY(run[1]));
    for (var i = 2; i + 1 < run.length; i += 2) {
      path.lineTo(t.mapX(run[i]), t.mapY(run[i + 1]));
    }
    if (close) path.close();
  }

  /// Appends the drawn dash segments of one polyline [run] to [result],
  /// walking the coordinates directly. Tile geometry is pure polylines,
  /// so `PathMetrics.extractPath` — a generic curve-capable engine call
  /// that allocates a `Path` per dash — is pure overhead here, and for
  /// the ~1px dashes of a footpath layer it was thousands of engine
  /// calls per tile: the z15–16 zoom-crossing jank (see `bench/`).
  ///
  /// [dashes] are the pattern lengths already scaled to logical px.
  /// [phaseLogicalPx] is how far along the *original* (un-clipped)
  /// geometry this run starts: the dash walk resumes mid-pattern there,
  /// so clipped sub-runs render exactly the dashes the full path would —
  /// keeping the pattern aligned across clip boundaries and
  /// display-tile seams. A dash spanning a vertex continues as one
  /// contiguous sub-path, so stroke joins inside a dash render exactly
  /// as they did under `extractPath`.
  static void _dashRun(
    Path result,
    Float32List run,
    _TileTransform t,
    List<double> dashes, {
    required bool close,
    double phaseLogicalPx = 0,
  }) {
    if (run.length < 4) return;
    var draw = true;
    var i = 0;
    var remaining = dashes[0];
    if (phaseLogicalPx > 0) {
      // With an odd dash count the draw/gap roles swap every cycle
      // (the draw flag flips per dash, not per cycle), so the visual
      // period is twice the pattern sum.
      var sum = 0.0;
      for (final d in dashes) {
        sum += d;
      }
      var p = phaseLogicalPx % (dashes.length.isEven ? sum : sum * 2);
      while (p >= remaining) {
        p -= remaining;
        i++;
        draw = !draw;
        remaining = dashes[i % dashes.length];
      }
      remaining -= p;
    }

    final points = run.length ~/ 2;
    final segments = close ? points : points - 1;
    var penDown = false;
    var ax = t.mapX(run[0]);
    var ay = t.mapY(run[1]);
    for (var s = 0; s < segments; s++) {
      final j = ((s + 1) % points) * 2;
      final bx = t.mapX(run[j]);
      final by = t.mapY(run[j + 1]);
      final dx = bx - ax;
      final dy = by - ay;
      final length = math.sqrt(dx * dx + dy * dy);
      var pos = 0.0;
      while (pos < length) {
        final take = math.min(remaining, length - pos);
        if (draw) {
          if (!penDown) {
            final f = pos / length;
            result.moveTo(ax + dx * f, ay + dy * f);
            penDown = true;
          }
          final f = (pos + take) / length;
          result.lineTo(ax + dx * f, ay + dy * f);
        }
        pos += take;
        remaining -= take;
        if (remaining <= 0) {
          i++;
          draw = !draw;
          remaining = dashes[i % dashes.length];
          // A gap starts: the next dash opens its own sub-path.
          if (!draw) penDown = false;
        }
      }
      ax = bx;
      ay = by;
    }
  }

  /// A paint that tiles [image] as a repeating pattern, anchored to the
  /// world grid at the display zoom so patterns line up across tile
  /// seams. The pattern keeps the sprite's logical size regardless of
  /// overzoom.
  static Paint _patternPaint(
    ui.Image image,
    double pixelRatio,
    double opacity,
    TileKey displayKey,
    bool antialias,
  ) {
    final s = 1.0 / pixelRatio;
    final w = image.width * s;
    final h = image.height * s;
    final tx = -((displayKey.x * logicalTileSize) % w);
    final ty = -((displayKey.y * logicalTileSize) % h);
    final matrix = Float64List.fromList(
        [s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1]);
    return Paint()
      ..shader = ui.ImageShader(
          image, ui.TileMode.repeated, ui.TileMode.repeated, matrix)
      ..color = Color.fromRGBO(255, 255, 255, opacity)
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = antialias;
  }

  static StrokeCap _cap(String value) => switch (value) {
        'round' => StrokeCap.round,
        'square' => StrokeCap.square,
        _ => StrokeCap.butt,
      };

  static StrokeJoin _join(String value) => switch (value) {
        'round' => StrokeJoin.round,
        'bevel' => StrokeJoin.bevel,
        _ => StrokeJoin.miter,
      };

  static Color _withOpacity(Color color, double opacity) =>
      opacity >= 1 ? color : color.withValues(alpha: color.a * opacity);
}

/// A per-layer or per-feature resolved line stroke.
class _LineStyle {
  final double width;
  final double gapWidth;
  final List<double>? dash;
  final Paint paint;

  _LineStyle({
    required this.width,
    required this.gapWidth,
    required this.dash,
    required this.paint,
  });
}

/// Maps tile-extent coordinates of a data tile to logical pixels of a
/// display tile — a descendant of the data tile at overzoom, or an
/// ancestor of it under zoom-out substitution.
class _TileTransform {
  final double scale;
  final double offsetX;
  final double offsetY;

  _TileTransform(this.scale, this.offsetX, this.offsetY);

  factory _TileTransform.forDisplay(TileKey display, TileKey data, int extent) {
    if (data.z > display.z) {
      // Descendant substitution: [data] covers a sub-square of the
      // display tile — shrink its geometry into place.
      final frac = data.fractionOf(display);
      return _TileTransform(
        TileRasterizer.logicalTileSize * frac.scale / extent,
        frac.dx * TileRasterizer.logicalTileSize,
        frac.dy * TileRasterizer.logicalTileSize,
      );
    }
    final frac = display.fractionOf(data);
    // logical = ((coord/extent) - dx) / fracScale * tileSize
    final scale = TileRasterizer.logicalTileSize / (extent * frac.scale);
    return _TileTransform(
      scale,
      -frac.dx * TileRasterizer.logicalTileSize / frac.scale,
      -frac.dy * TileRasterizer.logicalTileSize / frac.scale,
    );
  }

  double mapX(double x) => x * scale + offsetX;
  double mapY(double y) => y * scale + offsetY;
  Offset map(double x, double y) => Offset(mapX(x), mapY(y));
}
