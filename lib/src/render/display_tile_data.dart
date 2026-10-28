import '../core/tile_key.dart';
import '../grid/raster_tile_store.dart';
import '../pipeline/prepared_tile.dart';
import '../tile_providers.dart';

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

  /// Source id → cached descendant data tiles composing a (possibly
  /// partial) provisional cover for a source whose own tile has not
  /// arrived — the zoom-out counterpart of ancestor substitution. Only
  /// provisional renders carry any, and only for sources absent from
  /// [sources]. Geometry only: symbols are never laid out from
  /// descendants.
  final Map<String, List<PreparedTile>> descendantSources;

  /// Raster source id → descendant image tiles, under the same contract
  /// as [descendantSources]. Borrowed like [rasters].
  final Map<String, List<RasterTile>> descendantRasters;

  /// `raster-dem` source id → the decoded tiles bordering those in
  /// [rasters] / [descendantRasters], whichever were at hand. A
  /// hillshade reads a tile's slope from the elevations around each
  /// texel, so its edge texels need their neighbours' — without them it
  /// seams. Borrowed like [rasters].
  final Map<String, List<RasterTile>> neighbourRasters;

  /// `raster-dem` source id → how its pixels encode elevation. A raster
  /// source absent here is imagery.
  final Map<String, DemEncoding> demEncodings;

  const DisplayTileData({
    required this.displayKey,
    required this.sources,
    this.rasters = const {},
    this.descendantSources = const {},
    this.descendantRasters = const {},
    this.neighbourRasters = const {},
    this.demEncodings = const {},
  });

  bool get isEmpty =>
      sources.isEmpty &&
      rasters.isEmpty &&
      descendantSources.isEmpty &&
      descendantRasters.isEmpty;
}
