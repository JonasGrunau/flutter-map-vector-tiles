import 'dart:typed_data';

import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
import '../style/theme.dart';
import 'display_tile_data.dart';
import 'matched_features.dart';
import 'tile_rasterizer.dart';

/// One heatmap layer's points inside one display tile, in logical tile
/// coordinates (0..256).
///
/// Each point belongs to exactly one display tile of a level: a point
/// counts only inside its data tile's own extent — never from the
/// buffer a neighbour also carries — and only in the display tile whose
/// window holds it. The density pass sums kernels across tiles, so a
/// point counted twice would read as a point of twice the weight.
class HeatmapPoints {
  final HeatmapThemeLayer layer;

  /// Interleaved x,y.
  final Float32List xy;

  /// Per point, `heatmap-weight` / `heatmap-radius` evaluated when the
  /// tile was laid out — present for a property that reads the feature
  /// but not the zoom. Null for one that reads no feature (one value per
  /// pass, from [uniformWeight] / [uniformRadius]) or that reads both
  /// (re-evaluated per pass from [_features]).
  final Float32List? _weights;
  final Float32List? _radii;

  /// Per point, the feature it came from — kept only while a property
  /// reads both the feature and the zoom.
  final List<PreparedFeature>? _features;

  /// Per point, its feature's geometry for `within` / `distance` — kept
  /// with [_features], and only for a layer that reads geometry.
  final List<FeatureGeometry>? _geometries;

  HeatmapPoints._(this.layer, this.xy, this._weights, this._radii,
      this._features, this._geometries);

  int get length => xy.length >> 1;

  /// Approximate retained size, for cache cost accounting.
  int get byteSize =>
      xy.lengthInBytes +
      (_weights?.lengthInBytes ?? 0) +
      (_radii?.lengthInBytes ?? 0) +
      (_features?.length ?? 0) * 8 +
      (_geometries?.length ?? 0) * 8 +
      64;

  bool get uniformWeight => _weights == null && !_perPass(layer.weight);
  bool get uniformRadius => _radii == null && !_perPass(layer.radius);

  static bool _perPass(DoubleProp prop) => !prop.isConstant && !prop.zoomOnly;

  double? _evaluatedAt;
  Float32List? _passWeights;
  Float32List? _passRadii;

  /// Per point weights at [zoom], or null when [uniformWeight].
  Float32List? weightsAt(double zoom) =>
      _weights ?? (_perPass(layer.weight) ? _perPassAt(zoom).$1 : null);

  /// Per point radii at [zoom], or null when [uniformRadius].
  Float32List? radiiAt(double zoom) =>
      _radii ?? (_perPass(layer.radius) ? _perPassAt(zoom).$2 : null);

  (Float32List?, Float32List?) _perPassAt(double zoom) {
    if (_evaluatedAt != zoom) {
      _evaluatedAt = zoom;
      final features = _features!;
      final weighted = _weights == null && _perPass(layer.weight);
      final sized = _radii == null && _perPass(layer.radius);
      final weights = weighted ? Float32List(length) : null;
      final radii = sized ? Float32List(length) : null;
      for (var i = 0; i < features.length; i++) {
        final ctx = _contextOf(features[i], zoom, _geometries?[i]);
        if (weights != null) weights[i] = layer.weight.eval(ctx);
        if (radii != null) radii[i] = layer.radius.eval(ctx);
      }
      _passWeights = weights;
      _passRadii = radii;
    }
    return (_passWeights, _passRadii);
  }
}

EvalContext _contextOf(
        PreparedFeature feature, double zoom, FeatureGeometry? geometry) =>
    featureContext(
      zoom: zoom,
      properties: feature.properties,
      geometryType: feature.geometryType,
      featureId: feature.id,
      geometry: geometry,
    );

/// Extracts the points of a display tile's heatmap layers — cheap next
/// to rasterizing the tile, so the render pump does it whole when the
/// tile's geometry is done.
abstract final class HeatmapLayouter {
  /// Whether [theme] has a heatmap layer at all — most styles do not,
  /// and pay nothing for this feature.
  static bool any(Theme theme) {
    for (final layer in theme.layers) {
      if (layer is HeatmapThemeLayer) return true;
    }
    return false;
  }

  /// Whether [data] holds the source of any heatmap layer of [theme].
  static bool hasSource(Theme theme, DisplayTileData data) {
    for (final layer in theme.layers) {
      if (layer is HeatmapThemeLayer &&
          data.sources.containsKey(layer.source)) {
        return true;
      }
    }
    return false;
  }

  /// The points of every heatmap layer of [theme] visible somewhere in
  /// the band [styleZoom, styleZoom + 1) — the density pass gates each
  /// layer at the exact zoom — in theme order; an entry for every such
  /// layer, possibly empty. Only point features count, as with circle
  /// layers. Descendant sources are ignored: they only stand in for
  /// geometry while a zoom-out loads.
  static List<HeatmapPoints> layout({
    required Theme theme,
    required DisplayTileData data,
    required double styleZoom,
  }) {
    final out = <HeatmapPoints>[];
    for (final layer in theme.layers) {
      if (layer is! HeatmapThemeLayer || !layer.coversZoomBand(styleZoom)) {
        continue;
      }
      out.add(_layoutLayer(layer, data, styleZoom));
    }
    return out;
  }

  static HeatmapPoints _layoutLayer(
      HeatmapThemeLayer layer, DisplayTileData data, double styleZoom) {
    final xy = <double>[];
    final features = <PreparedFeature>[];
    final readsGeometry = layer.readsGeometry;
    final geometries = readsGeometry ? <FeatureGeometry>[] : null;
    final source = layer.source;
    final sourceLayerName = layer.sourceLayer;
    final tile = source == null ? null : data.sources[source];
    final sourceLayer =
        sourceLayerName == null ? null : tile?.layers[sourceLayerName];
    if (tile != null && sourceLayer != null) {
      final frac = data.displayKey.fractionOf(tile.key);
      final extent = sourceLayer.extent.toDouble();
      // The display tile's window in extent units, intersected with the
      // data tile's own extent: half-open, so that a point on a seam
      // belongs to one side only.
      final minX = frac.dx * extent;
      final minY = frac.dy * extent;
      final maxX = minX + frac.scale * extent;
      final maxY = minY + frac.scale * extent;
      final scale = TileRasterizer.logicalTileSize / (extent * frac.scale);
      final matched = MatchedFeatures.of(layer, sourceLayer, tile: tile.key);
      for (final feature in matched ?? sourceLayer.features) {
        if (feature.type != PreparedGeomType.point ||
            feature.maxX < minX ||
            feature.minX >= maxX ||
            feature.maxY < minY ||
            feature.minY >= maxY) {
          continue;
        }
        final geometry = readsGeometry
            ? featureGeometry(tile.key, sourceLayer, feature)
            : null;
        if (matched == null &&
            !layer.matches(_contextOf(feature, styleZoom, geometry))) {
          continue;
        }
        for (final part in feature.parts) {
          for (var i = 0; i + 1 < part.length; i += 2) {
            final x = part[i];
            final y = part[i + 1];
            if (x < minX || x >= maxX || y < minY || y >= maxY) continue;
            xy
              ..add((x - minX) * scale)
              ..add((y - minY) * scale);
            features.add(feature);
            geometries?.add(geometry!);
          }
        }
      }
    }
    final weightByFeature =
        HeatmapPoints._perPass(layer.weight) && !layer.weightReadsZoom;
    final radiusByFeature =
        HeatmapPoints._perPass(layer.radius) && !layer.radiusReadsZoom;
    Float32List? evaluate(DoubleProp prop) {
      final values = Float32List(features.length);
      PreparedFeature? last;
      var value = 0.0;
      for (var i = 0; i < features.length; i++) {
        final feature = features[i];
        // A multipoint feature's points share one evaluation.
        if (!identical(feature, last)) {
          last = feature;
          value = prop.eval(_contextOf(feature, styleZoom, geometries?[i]));
        }
        values[i] = value;
      }
      return values;
    }

    final keepFeatures =
        (HeatmapPoints._perPass(layer.weight) && layer.weightReadsZoom) ||
            (HeatmapPoints._perPass(layer.radius) && layer.radiusReadsZoom);
    return HeatmapPoints._(
      layer,
      Float32List.fromList(xy),
      weightByFeature ? evaluate(layer.weight) : null,
      radiusByFeature ? evaluate(layer.radius) : null,
      keepFeatures ? features : null,
      keepFeatures ? geometries : null,
    );
  }
}
