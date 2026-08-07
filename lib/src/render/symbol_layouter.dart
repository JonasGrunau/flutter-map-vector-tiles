import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import 'display_tile_data.dart';
import 'tile_rasterizer.dart';

/// A polyline in logical display-tile coordinates with precomputed
/// cumulative distances, shared by all anchors placed along it.
class SymbolPath {
  /// Interleaved x,y vertex coordinates.
  final Float32List points;

  /// Distance from the path start to each vertex.
  final Float32List cumulative;

  const SymbolPath(this.points, this.cumulative);

  double get length => cumulative[cumulative.length - 1];

  /// Index of the segment containing distance [d] (clamped).
  int segmentAt(double d) {
    var lo = 0, hi = cumulative.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (cumulative[mid] <= d) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  Offset pointAt(double d) {
    final i = segmentAt(d);
    final segment = cumulative[i + 1] - cumulative[i];
    final f = segment <= 0
        ? 0.0
        : ((d - cumulative[i]) / segment).clamp(0.0, 1.0);
    return Offset(
      points[i * 2] + (points[i * 2 + 2] - points[i * 2]) * f,
      points[i * 2 + 1] + (points[i * 2 + 3] - points[i * 2 + 1]) * f,
    );
  }

  /// Baseline angle (radians) of the segment containing distance [d].
  double angleAt(double d) {
    final i = segmentAt(d);
    return math.atan2(points[i * 2 + 3] - points[i * 2 + 1],
        points[i * 2 + 2] - points[i * 2]);
  }
}

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

  /// The line this anchor sits on (for curved text); null for point
  /// placements.
  final SymbolPath? path;

  /// Distance of [anchor] along [path], in logical pixels.
  final double pathDistance;
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
    this.path,
    this.pathDistance = 0,
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

        void add(Offset anchor, double angle, bool alongLine,
            {SymbolPath? path, double pathDistance = 0}) {
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
            path: path,
            pathDistance: pathDistance,
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
    void Function(Offset anchor, double angle, bool alongLine,
            {SymbolPath? path, double pathDistance})
        add,
  ) {
    if (part.length < 4) return;
    // Transform into logical display-tile coordinates once; the path is
    // shared by every anchor placed on it (and by the curved-text pass).
    final n = part.length ~/ 2;
    final points = Float32List(n * 2);
    final cumulative = Float32List(n);
    var total = 0.0;
    for (var i = 0; i < n; i++) {
      points[i * 2] = part[i * 2] * scale + offsetX;
      points[i * 2 + 1] = part[i * 2 + 1] * scale + offsetY;
      if (i > 0) {
        final dx = points[i * 2] - points[i * 2 - 2];
        final dy = points[i * 2 + 1] - points[i * 2 - 1];
        total += math.sqrt(dx * dx + dy * dy);
      }
      cumulative[i] = total;
    }
    if (total < 1) return;
    final path = SymbolPath(points, cumulative);

    final targets = <double>[];
    if (!spacing.isFinite || spacing <= 0 || total < spacing) {
      targets.add(total / 2);
    } else {
      for (var d = spacing / 2; d < total; d += spacing) {
        targets.add(d);
      }
    }

    for (final d in targets) {
      add(path.pointAt(d), path.angleAt(d), true,
          path: path, pathDistance: d);
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
