import '../core/tile_key.dart';
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

  const DisplayTileData({required this.displayKey, required this.sources});

  bool get isEmpty => sources.isEmpty;
}
