import '../pipeline/prepared_tile.dart';
import '../style/expression.dart';
import '../style/theme.dart';

/// The features of a prepared source layer that a style layer's filter
/// selects, resolved once per prepared tile instead of once per display
/// tile.
///
/// The rasterizer and the symbol layouter test every feature of a source
/// layer against every style layer reading it — a MapTiler-style theme
/// runs 60+ line layers over `transportation` alone, about 45 filter
/// tests per match — and at overzoom one data tile serves many display
/// tiles: up to 64 of them in the z15.5–17.5 band where this was
/// measured, more beyond it. A filter that never reads the zoom
/// ([ThemeLayer.filterReadsZoom]) gives the same answer on every one of
/// them, so its matches are computed on first use and attached to the
/// source layer: the entry lives exactly as long as the prepared tile,
/// and keys are layer identities, so a different theme's layers simply
/// miss. Both levels are weak: a theme that is swapped out — a light
/// and a dark style taking turns, say — is not kept alive by the
/// decoded tiles it was drawn from, nor are its match lists. They are
/// lists of references into the tile, not counted in
/// `VectorTileLayer.memoryCacheMaxBytes`.
abstract final class MatchedFeatures {
  static final _cache = Expando<Expando<List<PreparedFeature>>>();

  /// The features of [sourceLayer] that [layer]'s filter matches, in
  /// source order; null when the filter reads the zoom and has to be
  /// evaluated per display tile.
  static List<PreparedFeature>? of(
      ThemeLayer layer, PreparedSourceLayer sourceLayer) {
    if (layer.filterReadsZoom) return null;
    final byLayer = _cache[sourceLayer] ??= Expando();
    return byLayer[layer] ??= _match(layer, sourceLayer.features);
  }

  static List<PreparedFeature> _match(
      ThemeLayer layer, List<PreparedFeature> features) {
    final matched = <PreparedFeature>[
      for (final feature in features)
        // The zoom is never read: the filter is zoom-free.
        if (layer.matches(EvalContext(
          zoom: 0,
          properties: feature.properties,
          geometryType: feature.geometryType,
          featureId: feature.id,
        )))
          feature,
    ];
    // An unfiltered layer keeps every feature; share the source list
    // instead of holding a copy of it.
    return matched.length == features.length ? features : matched;
  }
}
