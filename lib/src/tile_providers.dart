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
