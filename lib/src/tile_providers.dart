import 'provider/vector_tile_provider.dart';

/// Vector tile providers keyed by style source id (the keys of the
/// style's `sources` object).
class TileProviders {
  final Map<String, VectorTileProvider> providers;

  const TileProviders(this.providers);

  VectorTileProvider? operator [](String source) => providers[source];

  void dispose() {
    for (final provider in providers.values) {
      provider.dispose();
    }
  }
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
