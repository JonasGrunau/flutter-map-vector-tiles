import 'dart:math' as math;
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
/// scales between levels — polygons filled with the same non-zero rule,
/// geometry shifted by the same `*-translate` and lines moved sideways
/// by the same `line-offset`. Paint opacity is not consulted, as in
/// MapLibre: a transparent layer still answers queries, the usual way
/// to widen a tap target.
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
      final translate = _translateOf(layer, styleZoom);
      final tile = data.sources[source];
      if (tile != null) {
        _hitIn(i, layer, data, tile, styleZoom, translate, area, hits);
      } else {
        for (final descendant
            in data.descendantSources[source] ?? const <PreparedTile>[]) {
          _hitIn(i, layer, data, descendant, styleZoom, translate, area, hits);
        }
      }
    }
    return hits;
  }

  /// The `*-translate` the rasterizer draws [layer] shifted by at
  /// [styleZoom] — fills (extrusions included), lines and circles; none
  /// for any other layer.
  static Offset _translateOf(ThemeLayer layer, double styleZoom) =>
      switch (layer) {
        FillThemeLayer(:final translate) ||
        LineThemeLayer(:final translate) ||
        CircleThemeLayer(:final translate) =>
          TileRasterizer.translateOf(translate, styleZoom),
        _ => Offset.zero,
      };

  static void _hitIn(
    int layerIndex,
    ThemeLayer layer,
    DisplayTileData data,
    PreparedTile tile,
    double styleZoom,
    Offset translate,
    HitArea area,
    List<GeometryHit> hits,
  ) {
    final sourceLayerName = layer.sourceLayer;
    if (sourceLayerName == null) return;
    final sourceLayer = tile.layers[sourceLayerName];
    if (sourceLayer == null) return;
    final t = TileRasterizer.displayTransform(
        data.displayKey, tile.key, sourceLayer.extent);
    // The display transform shifted by the translate, as the rasterizer
    // draws through it.
    final dx = t.dx + translate.dx, dy = t.dy + translate.dy;
    // The query in extent units, and the slack — a stroke's half width,
    // a circle's reach — converted with it.
    final unclipped =
        area.map((p) => Offset((p.dx - dx) / t.scale, (p.dy - dy) / t.scale));
    HitArea? query = unclipped;
    // A line `line-offset` may move: its offset runs are tested in
    // pixels, against [area], clipped where the rasterizer clips them.
    final offsetLines = layer is LineThemeLayer && layer.offset != null;
    if (tile.key.z > data.displayKey.z) {
      // A descendant standing in on zoom-out is drawn clipped to its
      // own extent; so is what it answers for. The clip is in extent
      // units, so it moves with the translate, as the rasterizer's does.
      // An offset line is clipped before it moves sideways, so it may be
      // drawn outside that extent: the query outside it still counts.
      final extent = sourceLayer.extent.toDouble();
      query = unclipped.clipTo(Rect.fromLTWH(0, 0, extent, extent));
      if (query == null && !offsetLines) return;
    }
    final bounds = offsetLines ? unclipped.bounds : query!.bounds;

    // A stroke or a circle reaching past what the bounds test below
    // allows for is drawn no further than the rasterizer's cull buffer
    // into a tile either, so that is the most a data-driven size needs.
    // A data-driven `line-offset` has no such bound — the rasterizer
    // culls a line on its own bounds, then moves it any distance — so
    // only the cull window limits it.
    final double reachPx;
    switch (layer) {
      case LineThemeLayer(:final offset):
        final zoomCtx = EvalContext(zoom: styleZoom);
        reachPx = (_constant(layer.width) && _constant(layer.gapWidth)
                ? _halfWidth(layer, zoomCtx)
                : TileRasterizer.cullBufferPx) +
            (offset == null
                ? 0.0
                : _constant(offset)
                    ? offset.eval(zoomCtx).abs()
                    : double.infinity);
      case CircleThemeLayer():
        reachPx = _constant(layer.radius) && _constant(layer.strokeWidth)
            ? _circleReach(layer, EvalContext(zoom: styleZoom))
            : TileRasterizer.cullBufferPx;
      default:
        reachPx = 0;
    }
    final reach = reachPx / t.scale;
    // Nor does the rasterizer draw a feature whose bounds miss the
    // tile's cull window, however far its stroke or offset would reach:
    // the bounds test takes the narrower of the two.
    const buffer = TileRasterizer.cullBufferPx;
    const size = TileRasterizer.logicalTileSize;
    final minX = math.max(bounds.left - reach, (-buffer - dx) / t.scale);
    final maxX = math.min(bounds.right + reach, (size + buffer - dx) / t.scale);
    final minY = math.max(bounds.top - reach, (-buffer - dy) / t.scale);
    final maxY =
        math.min(bounds.bottom + reach, (size + buffer - dy) / t.scale);

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
            query!.hitsPolygon(feature.parts),
        LineThemeLayer() => feature.type != PreparedGeomType.point &&
            _hitsLine(layer, ctx, data.displayKey, tile.key, sourceLayer,
                feature, translate, query, area, t.scale),
        CircleThemeLayer() => feature.type == PreparedGeomType.point &&
            _hitsPoints(query!, feature, _circleReach(layer, ctx) / t.scale),
        _ => false,
      };
      if (hit) {
        hits.add((layerIndex: layerIndex, layer: layer, feature: feature));
      }
    }
  }

  /// Whether [layer]'s stroke of [feature] reaches [query] (extent units,
  /// translated; null where a descendant's clip leaves none of it) — or,
  /// when its `line-offset` moves it sideways, whether the offset runs
  /// the rasterizer draws reach [area] (logical px).
  static bool _hitsLine(
    LineThemeLayer layer,
    EvalContext ctx,
    TileKey displayKey,
    TileKey tileKey,
    PreparedSourceLayer sourceLayer,
    PreparedFeature feature,
    Offset translate,
    HitArea? query,
    HitArea area,
    double scale,
  ) {
    final halfWidth = _halfWidth(layer, ctx);
    final offset = layer.offset?.eval(ctx) ?? 0;
    if (offset == 0) {
      return query != null &&
          query.hitsLine(feature.parts, halfWidth / scale,
              close: feature.type == PreparedGeomType.polygon);
    }
    // An offset is a shift in logical px, at every vertex — no single
    // transform of the query matches it, so the runs go to pixels, as
    // the rasterizer takes them, clipped where it clips them.
    for (final (:run, :closed) in TileRasterizer.offsetLineRuns(
        displayKey, tileKey, sourceLayer.extent, feature,
        translate: translate, offset: offset)) {
      if (area.hitsLine([run], halfWidth, close: closed)) return true;
    }
    return false;
  }

  /// The `slackPx` [drawsAny] needs for display tiles drawn at
  /// [styleZoom] when the state of [source]'s [sourceLayer] changes: how
  /// far the rasterizer shifts those features — the largest
  /// `*-translate` component of [theme]'s fill, line and circle layers
  /// that read their state and are drawn at that zoom. It culls a
  /// feature on its bounds shifted by its translate, so that is all a
  /// state change has to allow for. `line-offset` adds nothing: the
  /// rasterizer moves a line sideways only after that test, so an offset
  /// never makes a tile draw a feature its bounds keep out of it — a
  /// data-driven one included, so none needs a conservative bound.
  ///
  /// A translate is evaluated at the zoom alone, as the rasterizer
  /// evaluates it, so the answer is exact; it is remembered per theme.
  static double stateSlackPx(
      Theme theme, String source, String sourceLayer, double styleZoom) {
    final memo = _slack[theme] ??= {};
    return memo[(source, sourceLayer, styleZoom)] ??= () {
      var slack = 0.0;
      for (final layer in theme.layers) {
        if (!layer.readsFeatureState ||
            layer.source != source ||
            layer.sourceLayer != sourceLayer ||
            !layer.coversZoom(styleZoom)) {
          continue;
        }
        final translate = _translateOf(layer, styleZoom);
        slack =
            math.max(slack, math.max(translate.dx.abs(), translate.dy.abs()));
      }
      return slack;
    }();
  }

  /// [stateSlackPx] by (source, source layer, style zoom), per theme.
  static final _slack = Expando<Map<(String, String, double), double>>();

  /// Whether display tile [displayKey], drawn from [tile], draws any
  /// feature of [sourceLayerName] whose normalized id
  /// ([FeatureStates.normalizeId]) is in [ids] — so whether a change to
  /// those features' state changes its image. Bounds-tested against
  /// the tile's window plus the rasterizer's cull buffer, so at overzoom
  /// only the display tiles the feature reaches answer yes, widened by
  /// [slackPx] for the layers that draw the features shifted
  /// ([stateSlackPx]).
  static bool drawsAny(TileKey displayKey, PreparedTile tile,
      String sourceLayerName, Iterable<Object> ids,
      {double slackPx = 0}) {
    final sourceLayer = tile.layers[sourceLayerName];
    if (sourceLayer == null) return false;
    final index = _byId[sourceLayer] ??= _indexById(sourceLayer.features);
    final t = TileRasterizer.displayTransform(
        displayKey, tile.key, sourceLayer.extent);
    final buffer = TileRasterizer.cullBufferPx + slackPx;
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
