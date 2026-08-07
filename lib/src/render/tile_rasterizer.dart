import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../core/tile_key.dart';
import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import 'display_tile_data.dart';

/// Renders the geometry layers (background/fill/line/circle) of one
/// display tile into a GPU-resident [ui.Image].
///
/// Rasterization happens once per (display tile, integer zoom); the
/// per-frame cost of the map is then just drawing textures. Symbol layers
/// are *not* rasterized here — they are drawn per-frame in screen space
/// by the label pass.
class TileRasterizer {
  /// Logical tile size in points (the slippy-map convention).
  static const double logicalTileSize = 256;

  /// Records and rasterizes the tile. [devicePixelRatio] controls the
  /// backing resolution. Returns null when there is nothing to draw.
  static ui.Image? rasterize({
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
    required double devicePixelRatio,
  }) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final pixelSize = (logicalTileSize * devicePixelRatio).ceil();
    canvas.clipRect(
        Rect.fromLTWH(0, 0, pixelSize.toDouble(), pixelSize.toDouble()));
    canvas.scale(pixelSize / logicalTileSize);

    final painted = paint(
      canvas: canvas,
      theme: theme,
      data: data,
      styleZoom: styleZoom,
    );

    final picture = recorder.endRecording();
    if (!painted) {
      picture.dispose();
      return null;
    }
    final image = picture.toImageSync(pixelSize, pixelSize);
    picture.dispose();
    return image;
  }

  /// Paints geometry layers onto [canvas] in logical tile coordinates
  /// (0..256). Returns whether anything was drawn.
  static bool paint({
    required Canvas canvas,
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
  }) {
    var painted = false;
    final zoomCtx = EvalContext(zoom: styleZoom);

    for (final layer in theme.layers) {
      if (!layer.coversZoom(styleZoom)) continue;
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
          painted |= _paintFill(canvas, layer, data, styleZoom);
        case LineThemeLayer():
          painted |= _paintLine(canvas, layer, data, styleZoom);
        case CircleThemeLayer():
          painted |= _paintCircle(canvas, layer, data, styleZoom);
        case SymbolThemeLayer():
          break; // screen-space label pass
      }
    }
    return painted;
  }

  /// Iterates the features of [layer]'s source-layer, calling [visit]
  /// with the feature and its tile-to-logical-pixels transform.
  static void _eachFeature(
    ThemeLayer layer,
    DisplayTileData data,
    double styleZoom,
    PreparedGeomType? typeFilter,
    void Function(PreparedFeature feature, _TileTransform transform) visit,
  ) {
    final source = layer.source;
    final sourceLayerName = layer.sourceLayer;
    if (source == null || sourceLayerName == null) return;
    final tile = data.sources[source];
    if (tile == null) return;
    final sourceLayer = tile.layers[sourceLayerName];
    if (sourceLayer == null) return;

    final transform = _TileTransform.forDisplay(
        data.displayKey, tile.key, sourceLayer.extent);

    for (final feature in sourceLayer.features) {
      if (typeFilter != null && feature.type != typeFilter) continue;
      final ctx = EvalContext(
        zoom: styleZoom,
        properties: feature.properties,
        geometryType: feature.geometryType,
        featureId: feature.id,
      );
      if (!layer.matches(ctx)) continue;
      visit(feature, transform);
    }
  }

  static bool _paintFill(
    Canvas canvas,
    FillThemeLayer layer,
    DisplayTileData data,
    double styleZoom,
  ) {
    var painted = false;
    final zoomCtx = EvalContext(zoom: styleZoom);
    final constant = layer.color.isConstant && layer.opacity.isConstant;
    Paint? fillPaint;
    if (constant) {
      final color = _withOpacity(layer.color.eval(zoomCtx),
          layer.opacity.eval(zoomCtx).clamp(0.0, 1.0));
      if (color.a == 0 && layer.outlineColor == null) return false;
      fillPaint = Paint()
        ..color = color
        ..isAntiAlias = layer.antialias;
    }

    _eachFeature(layer, data, styleZoom, PreparedGeomType.polygon,
        (feature, transform) {
      final path = _polygonPath(feature, transform);
      final ctx = EvalContext(
        zoom: styleZoom,
        properties: feature.properties,
        geometryType: feature.geometryType,
        featureId: feature.id,
      );
      final paint = fillPaint ??
          (Paint()
            ..color = _withOpacity(layer.color.eval(ctx),
                layer.opacity.eval(ctx).clamp(0.0, 1.0))
            ..isAntiAlias = layer.antialias);
      if (paint.color.a > 0) {
        canvas.drawPath(path, paint);
        painted = true;
      }
      final outline = layer.outlineColor;
      if (outline != null) {
        final color = outline.eval(ctx);
        if (color.a > 0) {
          canvas.drawPath(
            path,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.6
              ..isAntiAlias = layer.antialias,
          );
          painted = true;
        }
      }
    });
    return painted;
  }

  static bool _paintLine(
    Canvas canvas,
    LineThemeLayer layer,
    DisplayTileData data,
    double styleZoom,
  ) {
    var painted = false;
    _eachFeature(layer, data, styleZoom, null, (feature, transform) {
      if (feature.type == PreparedGeomType.point) return;
      final ctx = EvalContext(
        zoom: styleZoom,
        properties: feature.properties,
        geometryType: feature.geometryType,
        featureId: feature.id,
      );
      final width = layer.width.eval(ctx);
      if (width <= 0) return;
      final opacity = layer.opacity.eval(ctx).clamp(0.0, 1.0);
      final color = _withOpacity(layer.color.eval(ctx), opacity);
      if (color.a == 0) return;

      var path = _linePath(feature, transform);
      final dashArray = layer.dashArray?.eval(ctx);
      if (dashArray != null && dashArray.length >= 2) {
        path = _dashPath(path, dashArray, width);
      }

      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = _cap(layer.cap.eval(ctx))
        ..strokeJoin = _join(layer.join.eval(ctx));

      final gapWidth = layer.gapWidth.eval(ctx);
      if (gapWidth > 0) {
        // Two parallel casing strokes: outer stroke minus inner gap.
        final outer = gapWidth + 2 * width;
        canvas.saveLayer(null, Paint());
        canvas.drawPath(path, paint..strokeWidth = outer);
        canvas.drawPath(
          path,
          Paint()
            ..blendMode = BlendMode.clear
            ..style = PaintingStyle.stroke
            ..strokeWidth = gapWidth
            ..strokeCap = paint.strokeCap
            ..strokeJoin = paint.strokeJoin,
        );
        canvas.restore();
      } else {
        canvas.drawPath(path, paint);
      }
      painted = true;
    });
    return painted;
  }

  static bool _paintCircle(
    Canvas canvas,
    CircleThemeLayer layer,
    DisplayTileData data,
    double styleZoom,
  ) {
    var painted = false;
    _eachFeature(layer, data, styleZoom, PreparedGeomType.point,
        (feature, transform) {
      final ctx = EvalContext(
        zoom: styleZoom,
        properties: feature.properties,
        geometryType: feature.geometryType,
        featureId: feature.id,
      );
      final radius = layer.radius.eval(ctx);
      if (radius <= 0) return;
      final fill = _withOpacity(layer.color.eval(ctx),
          layer.opacity.eval(ctx).clamp(0.0, 1.0));
      final strokeWidth = layer.strokeWidth.eval(ctx);
      final stroke = strokeWidth > 0
          ? _withOpacity(layer.strokeColor.eval(ctx),
              layer.strokeOpacity.eval(ctx).clamp(0.0, 1.0))
          : null;
      for (final part in feature.parts) {
        for (var i = 0; i + 1 < part.length; i += 2) {
          final center = transform.map(part[i], part[i + 1]);
          if (fill.a > 0) {
            canvas.drawCircle(center, radius, Paint()..color = fill);
            painted = true;
          }
          if (stroke != null && stroke.a > 0) {
            canvas.drawCircle(
              center,
              radius,
              Paint()
                ..color = stroke
                ..style = PaintingStyle.stroke
                ..strokeWidth = strokeWidth,
            );
            painted = true;
          }
        }
      }
    });
    return painted;
  }

  static Path _polygonPath(PreparedFeature feature, _TileTransform t) {
    final path = Path()..fillType = PathFillType.nonZero;
    for (final ring in feature.parts) {
      _addRun(path, ring, t, close: true);
    }
    return path;
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

  static Path _dashPath(Path source, List<double> pattern, double width) {
    // Dash lengths are specified in multiples of line width.
    final dashes = pattern.map((d) => (d * width).clamp(0.01, 4096.0)).toList();
    final result = Path();
    for (final metric in source.computeMetrics()) {
      var distance = 0.0;
      var draw = true;
      var i = 0;
      while (distance < metric.length) {
        final len = dashes[i % dashes.length];
        if (draw) {
          result.addPath(
            metric.extractPath(distance, distance + len),
            Offset.zero,
          );
        }
        distance += len;
        draw = !draw;
        i++;
      }
    }
    return result;
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

/// Maps tile-extent coordinates of a data tile to logical pixels of a
/// display tile (which may be a descendant of the data tile).
class _TileTransform {
  final double scale;
  final double offsetX;
  final double offsetY;

  _TileTransform(this.scale, this.offsetX, this.offsetY);

  factory _TileTransform.forDisplay(
      TileKey display, TileKey data, int extent) {
    final frac = display.fractionOf(data);
    // logical = ((coord/extent) - dx) / fracScale * tileSize
    final scale =
        TileRasterizer.logicalTileSize / (extent * frac.scale);
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
