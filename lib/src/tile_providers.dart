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

/// A raster tile source declared inside a vector style: imagery for
/// `raster` layers (satellite/hybrid, pre-rendered hillshading), or —
/// with an [encoding] — elevations for `hillshade` layers (a
/// `raster-dem` source).
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

  /// How the source's pixels encode elevation, for a `raster-dem`
  /// source; null for imagery.
  final DemEncoding? encoding;

  const RasterTileSource({
    required this.provider,
    this.tileSize = 512,
    this.encoding,
  });

  void dispose() => provider.dispose();
}

/// How a `raster-dem` source packs an elevation into a pixel's red,
/// green and blue channels (each 0–255): metres = r·[redFactor] +
/// g·[greenFactor] + b·[blueFactor] − [baseShift].
class DemEncoding {
  final double redFactor;
  final double greenFactor;
  final double blueFactor;
  final double baseShift;

  /// A `custom` encoding, with the factors the source declares.
  const DemEncoding({
    this.redFactor = 1,
    this.greenFactor = 1,
    this.blueFactor = 1,
    this.baseShift = 0,
  });

  /// Mapbox Terrain-RGB (the style spec's default), also MapTiler's.
  static const mapbox = DemEncoding(
      redFactor: 6553.6, greenFactor: 25.6, blueFactor: 0.1, baseShift: 10000);

  /// Mapzen Terrarium, as served from AWS's open terrain tiles.
  static const terrarium = DemEncoding(
      redFactor: 256, greenFactor: 1, blueFactor: 1 / 256, baseShift: 32768);

  /// The elevation in metres of a pixel with these channel values.
  double elevation(int r, int g, int b) =>
      r * redFactor + g * greenFactor + b * blueFactor - baseShift;

  @override
  bool operator ==(Object other) =>
      other is DemEncoding &&
      other.redFactor == redFactor &&
      other.greenFactor == greenFactor &&
      other.blueFactor == blueFactor &&
      other.baseShift == baseShift;

  @override
  int get hashCode =>
      Object.hash(redFactor, greenFactor, blueFactor, baseShift);

  @override
  String toString() => 'DemEncoding($redFactor, $greenFactor, $blueFactor, '
      '$baseShift)';
}
