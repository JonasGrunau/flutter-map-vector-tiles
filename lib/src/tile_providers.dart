import 'provider/vector_tile_provider.dart';

/// Vector tile providers keyed by style source id (the keys of the
/// style's `sources` object).
class TileProviders {
  final Map<String, VectorTileProvider> providers;

  /// The sources' `promoteId`, keyed by style source id: which feature
  /// property stands in for the feature id. `StyleReader` fills it from
  /// the style document; sources without one use their tiles' own ids.
  final Map<String, PromoteId> promoteIds;

  const TileProviders(this.providers, {this.promoteIds = const {}});

  VectorTileProvider? operator [](String source) => providers[source];

  void dispose() {
    for (final provider in providers.values) {
      provider.dispose();
    }
  }
}

/// A vector source's `promoteId`: the feature property used as the
/// feature id — by the `id` expression, by feature state, and in
/// `VectorTileLayerController.queryRenderedFeatures` results — instead
/// of the id the tile encodes. For tiles whose features carry no id,
/// or ids that are not stable across tiles.
///
/// The style spec allows one property for every source layer
/// (`"promoteId": "osm_id"`) or one per source layer
/// (`"promoteId": {"building": "osm_id"}`); a source layer the map does
/// not name keeps its encoded ids. A feature whose property is absent,
/// or not a number, string or boolean, has no id.
class PromoteId {
  /// The property promoted in every source layer, unless
  /// [bySourceLayer] names one for it.
  final String? property;

  /// Source layer → the property promoted there.
  final Map<String, String> bySourceLayer;

  const PromoteId(String this.property) : bySourceLayer = const {};

  const PromoteId.bySourceLayer(this.bySourceLayer) : property = null;

  /// Parses a style document's `promoteId` value; null when it is
  /// neither a string nor an object of strings.
  static PromoteId? parse(Object? json) {
    if (json is String && json.isNotEmpty) return PromoteId(json);
    if (json is Map) {
      final bySourceLayer = <String, String>{
        for (final entry in json.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
      if (bySourceLayer.isNotEmpty) {
        return PromoteId.bySourceLayer(bySourceLayer);
      }
    }
    return null;
  }

  /// The property promoted in [sourceLayer], or null for none.
  String? propertyFor(String sourceLayer) =>
      bySourceLayer[sourceLayer] ?? property;

  @override
  bool operator ==(Object other) =>
      other is PromoteId &&
      other.property == property &&
      other.bySourceLayer.length == bySourceLayer.length &&
      bySourceLayer.entries.every((e) => other.bySourceLayer[e.key] == e.value);

  @override
  int get hashCode => Object.hash(
      property,
      Object.hashAllUnordered(
          bySourceLayer.entries.map((e) => Object.hash(e.key, e.value))));

  @override
  String toString() => property != null
      ? 'PromoteId($property)'
      : 'PromoteId.bySourceLayer($bySourceLayer)';
}

/// A raster tile source declared inside a vector style, referenced by
/// `raster` layers (satellite/hybrid imagery, pre-rendered hillshading).
///
/// The [provider] serves encoded image bytes (PNG/JPEG/WebP) instead of
/// MVT data — the [VectorTileProvider] interface is just bytes per tile
/// coordinate, so `NetworkVectorTileProvider` works unchanged.
class RasterTileSource {
  final VectorTileProvider provider;

  /// The source's `tileSize` (256 or 512). MapLibre's default is 512;
  /// 256px sources are fetched one zoom level deeper for the same visual
  /// scale.
  final int tileSize;

  const RasterTileSource({required this.provider, this.tileSize = 512});

  void dispose() => provider.dispose();
}
