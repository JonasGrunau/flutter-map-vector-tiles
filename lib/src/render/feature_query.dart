import 'dart:ui';

import '../core/tile_key.dart';
import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
import '../style/feature_state.dart';
import '../style/theme.dart';
import 'display_tile_data.dart';
import 'hit_test.dart';
import 'matched_features.dart';
import 'tile_rasterizer.dart';

/// One feature a rendered-feature query found in a display tile's
/// geometry: the style layer that drew it, the source layer it came
/// from, and the feature itself.
typedef GeometryHit = ({
  int layerIndex,
  ThemeLayer layer,
  PreparedFeature feature,
});

/// Hit-testing of the geometry layers a display tile's image holds —
/// the part of `queryRenderedFeatures` that does not come from the label
/// pass.
///
/// It decides hits exactly as [TileRasterizer] draws: the same layers at
/// the tile's integer style zoom, the same filters (and the same
/// once-per-tile match lists), stroke widths and circle radii evaluated
/// at that zoom in the tile's logical pixels — which is what its image
/// scales between levels — and polygons filled with the same non-zero
/// rule. Paint opacity is not consulted, as in MapLibre: a transparent
/// layer still answers queries, the usual way to widen a tap target.
abstract final class FeatureQuery {
  /// The features of [theme]'s fill, line and circle layers drawn into
  /// [data]'s display tile at [styleZoom] that [area] — in the display
  /// tile's logical pixels, already clipped to it — touches, in draw
  /// order. Only layers in [layerIds] count when it is given.
  static List<GeometryHit> hitTile({
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
    required HitArea area,
    Set<String>? layerIds,
  }) {
    final hits = <GeometryHit>[];
    final layers = theme.layers;
    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      if (layer is! FillThemeLayer &&
          layer is! LineThemeLayer &&
          layer is! CircleThemeLayer) {
        continue;
      }
      if (layerIds != null && !layerIds.contains(layer.id)) continue;
      if (!layer.coversZoom(styleZoom)) continue;
      final source = layer.source;
      if (source == null) continue;
      final tile = data.sources[source];
      if (tile != null) {
        _hitIn(i, layer, data, tile, styleZoom, area, hits);
      } else {
        for (final descendant
            in data.descendantSources[source] ?? const <PreparedTile>[]) {
          _hitIn(i, layer, data, descendant, styleZoom, area, hits);
        }
      }
    }
    return hits;
  }

  static void _hitIn(
    int layerIndex,
    ThemeLayer layer,
    DisplayTileData data,
    PreparedTile tile,
    double styleZoom,
    HitArea area,
    List<GeometryHit> hits,
  ) {
    final sourceLayerName = layer.sourceLayer;
    if (sourceLayerName == null) return;
    final sourceLayer = tile.layers[sourceLayerName];
    if (sourceLayer == null) return;
    final t = TileRasterizer.displayTransform(
        data.displayKey, tile.key, sourceLayer.extent);
    // The query in extent units, and the slack — a stroke's half width,
    // a circle's reach — converted with it.
    var query = area
        .map((p) => Offset((p.dx - t.dx) / t.scale, (p.dy - t.dy) / t.scale));
    if (tile.key.z > data.displayKey.z) {
      // A descendant standing in on zoom-out is drawn clipped to its
      // own extent; so is what it answers for.
      final extent = sourceLayer.extent.toDouble();
      final clipped = query.clipTo(Rect.fromLTWH(0, 0, extent, extent));
      if (clipped == null) return;
      query = clipped;
    }
    final bounds = query.bounds;

    // A stroke or a circle reaching past what the bounds test below
    // allows for is drawn no further than the rasterizer's cull buffer
    // into a tile either, so that is the most a data-driven size needs.
    final double reachPx;
    switch (layer) {
      case LineThemeLayer():
        reachPx = _constant(layer.width) && _constant(layer.gapWidth)
            ? _halfWidth(layer, EvalContext(zoom: styleZoom))
            : TileRasterizer.cullBufferPx;
      case CircleThemeLayer():
        reachPx = _constant(layer.radius) && _constant(layer.strokeWidth)
            ? _circleReach(layer, EvalContext(zoom: styleZoom))
            : TileRasterizer.cullBufferPx;
      default:
        reachPx = 0;
    }
    final reach = reachPx / t.scale;
    final minX = bounds.left - reach, maxX = bounds.right + reach;
    final minY = bounds.top - reach, maxY = bounds.bottom + reach;

    final states = layer.readsFeatureState
        ? data.featureStates?.sourceLayer(layer.source, sourceLayerName)
        : null;
    final matched = MatchedFeatures.of(layer, sourceLayer, tile: tile.key);
    final readsGeometry = layer.readsGeometry;
    for (final feature in matched ?? sourceLayer.features) {
      if (feature.maxX < minX ||
          feature.minX > maxX ||
          feature.maxY < minY ||
          feature.minY > maxY) {
        continue;
      }
      final ctx = featureContext(
        zoom: styleZoom,
        properties: feature.properties,
        geometryType: feature.geometryType,
        featureId: feature.id,
        featureState: FeatureStates.stateOf(states, feature.id),
        geometry: readsGeometry
            ? featureGeometry(tile.key, sourceLayer, feature)
            : null,
      );
      if (matched == null && !layer.matches(ctx)) continue;
      final hit = switch (layer) {
        FillThemeLayer() => feature.type == PreparedGeomType.polygon &&
            query.hitsPolygon(feature.parts),
        LineThemeLayer() => feature.type != PreparedGeomType.point &&
            query.hitsLine(feature.parts, _halfWidth(layer, ctx) / t.scale,
                close: feature.type == PreparedGeomType.polygon),
        CircleThemeLayer() => feature.type == PreparedGeomType.point &&
            _hitsPoints(query, feature, _circleReach(layer, ctx) / t.scale),
        _ => false,
      };
      if (hit) {
        hits.add((layerIndex: layerIndex, layer: layer, feature: feature));
      }
    }
  }

  /// Whether display tile [displayKey], drawn from [tile], draws any
  /// feature of [sourceLayerName] whose normalized id
  /// ([FeatureStates.normalizeId]) is in [ids] — so whether a change to
  /// those features' state changes its image. Bounds-tested against
  /// the tile's window plus the rasterizer's cull buffer, so at overzoom
  /// only the display tiles the feature reaches answer yes.
  static bool drawsAny(TileKey displayKey, PreparedTile tile,
      String sourceLayerName, Iterable<Object> ids) {
    final sourceLayer = tile.layers[sourceLayerName];
    if (sourceLayer == null) return false;
    final index = _byId[sourceLayer] ??= _indexById(sourceLayer.features);
    final t = TileRasterizer.displayTransform(
        displayKey, tile.key, sourceLayer.extent);
    const buffer = TileRasterizer.cullBufferPx;
    const size = TileRasterizer.logicalTileSize;
    final minX = (-buffer - t.dx) / t.scale;
    final maxX = (size + buffer - t.dx) / t.scale;
    final minY = (-buffer - t.dy) / t.scale;
    final maxY = (size + buffer - t.dy) / t.scale;
    for (final id in ids) {
      for (final feature in index[id] ?? const <PreparedFeature>[]) {
        if (feature.maxX >= minX &&
            feature.minX <= maxX &&
            feature.maxY >= minY &&
            feature.minY <= maxY) {
          return true;
        }
      }
    }
    return false;
  }

  /// A source layer's features by normalized id, built the first time a
  /// state change asks about the tile — weakly held, like
  /// `MatchedFeatures`, so it lives exactly as long as the tile.
  static final _byId = Expando<Map<Object, List<PreparedFeature>>>();

  static Map<Object, List<PreparedFeature>> _indexById(
      List<PreparedFeature> features) {
    final index = <Object, List<PreparedFeature>>{};
    for (final feature in features) {
      final id = feature.id;
      if (id != null) {
        (index[FeatureStates.normalizeId(id)] ??= []).add(feature);
      }
    }
    return index;
  }

  static bool _constant(DoubleProp prop) => prop.isConstant || prop.zoomOnly;

  /// Half the width a line covers: with a gap, the casing on both sides
  /// of it, as MapLibre measures it.
  static double _halfWidth(LineThemeLayer layer, EvalContext ctx) {
    final width = layer.width.eval(ctx);
    if (width <= 0) return 0;
    final gap = layer.gapWidth.eval(ctx);
    return (gap > 0 ? gap + 2 * width : width) / 2;
  }

  static double _circleReach(CircleThemeLayer layer, EvalContext ctx) {
    final radius = layer.radius.eval(ctx);
    if (radius <= 0) return 0;
    final stroke = layer.strokeWidth.eval(ctx);
    return radius + (stroke > 0 ? stroke : 0);
  }

  static bool _hitsPoints(HitArea area, PreparedFeature feature, double reach) {
    if (reach <= 0) return false;
    for (final part in feature.parts) {
      for (var i = 0; i + 1 < part.length; i += 2) {
        if (area.hitsCircle(Offset(part[i], part[i + 1]), reach)) return true;
      }
    }
    return false;
  }
}
