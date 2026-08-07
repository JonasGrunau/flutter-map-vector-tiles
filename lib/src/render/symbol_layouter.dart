import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import 'display_tile_data.dart';
import 'tile_rasterizer.dart';

/// A single label/icon placement candidate within a display tile,
/// in logical tile coordinates (0..256).
class SymbolInstance {
  final SymbolThemeLayer layer;

  /// Index of the layer in the theme, for stable ordering.
  final int layerIndex;
  final Offset anchor;

  /// Baseline angle in tile space (radians); only meaningful when
  /// [alongLine] is true.
  final double angle;
  final bool alongLine;
  final String text;
  final String? iconName;
  final double sortKey;
  final Map<String, Object?> properties;
  final String geometryType;
  final Object? featureId;

  const SymbolInstance({
    required this.layer,
    required this.layerIndex,
    required this.anchor,
    required this.angle,
    required this.alongLine,
    required this.text,
    required this.iconName,
    required this.sortKey,
    required this.properties,
    required this.geometryType,
    required this.featureId,
  });
}

/// Extracts symbol placement candidates from a display tile's prepared
/// data at a given style zoom. Runs once per (display tile, integer
/// zoom); results are cached by the tile model.
class SymbolLayouter {
  /// Ignore symbols anchored outside the tile (with a small buffer):
  /// neighbouring tiles will place them, avoiding duplicates at seams.
  static const double _buffer = 0.5;

  static List<SymbolInstance> layout({
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
  }) {
    final instances = <SymbolInstance>[];
    for (var i = 0; i < theme.layers.length; i++) {
      final layer = theme.layers[i];
      if (layer is! SymbolThemeLayer || !layer.coversZoom(styleZoom)) {
        continue;
      }
      final source = layer.source;
      final sourceLayerName = layer.sourceLayer;
      if (source == null || sourceLayerName == null) continue;
      final tile = data.sources[source];
      final sourceLayer = tile?.layers[sourceLayerName];
      if (tile == null || sourceLayer == null) continue;

      final frac = data.displayKey.fractionOf(tile.key);
      final scale =
          TileRasterizer.logicalTileSize / (sourceLayer.extent * frac.scale);
      final offsetX =
          -frac.dx * TileRasterizer.logicalTileSize / frac.scale;
      final offsetY =
          -frac.dy * TileRasterizer.logicalTileSize / frac.scale;

      for (final feature in sourceLayer.features) {
        final ctx = EvalContext(
          zoom: styleZoom,
          properties: feature.properties,
          geometryType: feature.geometryType,
          featureId: feature.id,
        );
        if (!layer.matches(ctx)) continue;

        var text = layer.textField.eval(ctx).trim();
        if (text.isNotEmpty) {
          text = switch (layer.textTransform.eval(ctx)) {
            'uppercase' => text.toUpperCase(),
            'lowercase' => text.toLowerCase(),
            _ => text,
          };
        }
        final iconName = layer.iconImage?.eval(ctx);
        if (text.isEmpty && (iconName == null || iconName.isEmpty)) {
          continue;
        }

        final placement = layer.placement.eval(ctx);
        final sortKey = layer.sortKey.eval(ctx);

        void add(Offset anchor, double angle, bool alongLine) {
          if (anchor.dx < -_buffer ||
              anchor.dy < -_buffer ||
              anchor.dx >= TileRasterizer.logicalTileSize + _buffer ||
              anchor.dy >= TileRasterizer.logicalTileSize + _buffer) {
            return;
          }
          instances.add(SymbolInstance(
            layer: layer,
            layerIndex: i,
            anchor: anchor,
            angle: angle,
            alongLine: alongLine,
            text: text,
            iconName:
                (iconName == null || iconName.isEmpty) ? null : iconName,
            sortKey: sortKey,
            properties: feature.properties,
            geometryType: feature.geometryType,
            featureId: feature.id,
          ));
        }

        if (placement == 'point' ||
            feature.type == PreparedGeomType.point) {
          for (final part in feature.parts) {
            if (feature.type == PreparedGeomType.polygon) {
              // Label polygons at their centroid (first exterior ring).
              final centroid = _centroid(part);
              add(
                  Offset(centroid.dx * scale + offsetX,
                      centroid.dy * scale + offsetY),
                  0,
                  false);
              break;
            }
            if (feature.type == PreparedGeomType.line) {
              // point placement on a line: use the midpoint.
              final mid = _midpoint(part);
              add(Offset(mid.dx * scale + offsetX, mid.dy * scale + offsetY),
                  0, false);
              continue;
            }
            for (var p = 0; p + 1 < part.length; p += 2) {
              add(
                  Offset(part[p] * scale + offsetX,
                      part[p + 1] * scale + offsetY),
                  0,
                  false);
            }
          }
        } else {
          // line / line-center placement
          final spacing =
              placement == 'line-center' ? double.infinity : layer.spacing.eval(ctx);
          for (final part in feature.parts) {
            _placeAlongLine(part, scale, offsetX, offsetY, spacing, add);
          }
        }
      }
    }
    return instances;
  }

  /// Places anchors along a polyline every [spacing] logical pixels
  /// (or a single anchor at the middle when spacing is infinite).
  static void _placeAlongLine(
    Float32List part,
    double scale,
    double offsetX,
    double offsetY,
    double spacing,
    void Function(Offset anchor, double angle, bool alongLine) add,
  ) {
    if (part.length < 4) return;
    // Total length in logical px.
    var total = 0.0;
    for (var i = 0; i + 3 < part.length; i += 2) {
      final dx = (part[i + 2] - part[i]) * scale;
      final dy = (part[i + 3] - part[i + 1]) * scale;
      total += math.sqrt(dx * dx + dy * dy);
    }
    if (total < 1) return;

    final targets = <double>[];
    if (!spacing.isFinite || spacing <= 0 || total < spacing) {
      targets.add(total / 2);
    } else {
      for (var d = spacing / 2; d < total; d += spacing) {
        targets.add(d);
      }
    }

    var travelled = 0.0;
    var t = 0;
    for (var i = 0; i + 3 < part.length && t < targets.length; i += 2) {
      final x0 = part[i] * scale + offsetX;
      final y0 = part[i + 1] * scale + offsetY;
      final x1 = part[i + 2] * scale + offsetX;
      final y1 = part[i + 3] * scale + offsetY;
      final segment = math.sqrt(
          (x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
      while (t < targets.length &&
          targets[t] <= travelled + segment &&
          segment > 0) {
        final f = (targets[t] - travelled) / segment;
        final angle = math.atan2(y1 - y0, x1 - x0);
        add(
          Offset(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f),
          angle,
          true,
        );
        t++;
      }
      travelled += segment;
    }
  }

  static Offset _centroid(Float32List ring) {
    var areaSum = 0.0, cx = 0.0, cy = 0.0;
    final n = ring.length;
    for (var i = 0; i + 1 < n; i += 2) {
      final x0 = ring[i], y0 = ring[i + 1];
      final j = (i + 2) % n;
      final x1 = ring[j], y1 = ring[j + 1];
      final cross = x0 * y1 - x1 * y0;
      areaSum += cross;
      cx += (x0 + x1) * cross;
      cy += (y0 + y1) * cross;
    }
    if (areaSum.abs() < 1e-7) return Offset(ring[0], ring[1]);
    return Offset(cx / (3 * areaSum), cy / (3 * areaSum));
  }

  static Offset _midpoint(Float32List part) {
    var total = 0.0;
    for (var i = 0; i + 3 < part.length; i += 2) {
      final dx = part[i + 2] - part[i];
      final dy = part[i + 3] - part[i + 1];
      total += math.sqrt(dx * dx + dy * dy);
    }
    var travelled = 0.0;
    final half = total / 2;
    for (var i = 0; i + 3 < part.length; i += 2) {
      final dx = part[i + 2] - part[i];
      final dy = part[i + 3] - part[i + 1];
      final segment = math.sqrt(dx * dx + dy * dy);
      if (travelled + segment >= half && segment > 0) {
        final f = (half - travelled) / segment;
        return Offset(part[i] + dx * f, part[i + 1] + dy * f);
      }
      travelled += segment;
    }
    return Offset(part[0], part[1]);
  }
}
