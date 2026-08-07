/// Relates the map's display zoom to the data/style zoom.
///
/// MapLibre renders 512px tiles: at the same visual scale, a MapLibre
/// zoom is one lower than flutter_map's. Styles authored for MapLibre
/// (MapTiler, Mapbox, OpenMapTiles, Protomaps) therefore render exactly
/// as designed with [TileOffset.maplibre] — text sizes, road widths and
/// layer zoom ranges all match the style author's intent. This is the
/// recommended setting (and the default) for such styles.
///
/// [TileOffset.none] evaluates the style at flutter_map's zoom directly,
/// making everything appear one zoom level earlier/larger — matching the
/// legacy behaviour of `vector_map_tiles`' default.
class TileOffset {
  /// Added to the display zoom to obtain the data/style zoom. Zero or
  /// negative.
  final int zoomOffset;

  const TileOffset({required this.zoomOffset}) : assert(zoomOffset <= 0);

  /// Style zoom == flutter_map zoom.
  static const none = TileOffset(zoomOffset: 0);

  /// Style zoom == flutter_map zoom - 1 (512px tile convention).
  /// Matches MapLibre GL rendering of the same style.
  static const maplibre = TileOffset(zoomOffset: -1);
}
