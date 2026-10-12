/// Where `VectorTileLayer` draws labels and icons.
///
/// Geometry is rasterized once per display tile in both modes. The modes
/// differ only in what happens to text and icons, and they trade frame
/// cost against label quality:
///
/// | | [screen] (default) | [tile] |
/// |---|---|---|
/// | Per-frame label work | one collision pass and every label drawn, each frame | none — tiles are plain images |
/// | Collision | global, across tile seams | within each tile; labels that cross a tile edge are dropped |
/// | Under rotation | text stays upright | text rotates with the map |
/// | Between zoom levels | sized for the exact zoom | scales with the tile, up to 2× before the next level replaces it |
/// | Fades | per label | with the tile |
///
/// [tile] is what `vector_map_tiles` calls raster mode.
enum LabelMode {
  /// Labels and icons are laid out per tile but drawn every frame in
  /// screen space, with one collision pass across all tiles. Text stays
  /// crisp at fractional zoom and upright under rotation, labels never
  /// duplicate or clip at tile seams, and each label fades on its own.
  /// The price is UI-thread work on every frame the map moves.
  screen,

  /// Labels and icons are placed per tile and drawn into the tile's
  /// raster, so a moving map costs no label work at all.
  ///
  /// The trade-offs are those of any pre-rendered tile: collision is
  /// resolved within each tile, so a label that would cross a tile edge
  /// is dropped (gaps along tile seams); text rotates with the map
  /// instead of staying upright; text is sized for the tile's zoom level
  /// and scales with the map until the next level's tiles replace it;
  /// and labels appear and fade with their tile.
  /// `VectorTileLayer.labelFadeDuration` has no effect.
  tile,
}
