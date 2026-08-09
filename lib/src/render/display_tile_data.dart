import '../core/tile_key.dart';
import '../grid/raster_tile_store.dart';
import '../pipeline/prepared_tile.dart';

/// The prepared data backing one *display* tile, per style source.
///
/// The data tile may be an ancestor of the display tile (overzoom or
/// temporary parent substitution); the rasterizer renders the correct
/// sub-region.
class DisplayTileData {
  final TileKey displayKey;

  /// Source id → prepared data tile covering [displayKey].
  final Map<String, PreparedTile> sources;

  /// Raster source id → decoded image tile covering [displayKey]. The
  /// tiles are borrowed for the duration of the paint; ownership stays
  /// with the caller.
  final Map<String, RasterTile> rasters;

  const DisplayTileData({
    required this.displayKey,
    required this.sources,
    this.rasters = const {},
  });

  bool get isEmpty => sources.isEmpty && rasters.isEmpty;
}
