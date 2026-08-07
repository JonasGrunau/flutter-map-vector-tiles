import '../core/tile_key.dart';

/// What the retention rules need to know about a display tile of the
/// *current* zoom level.
typedef CurrentTileStatus = ({
  TileKey key,

  /// No result has arrived yet — neither a final raster nor provisional
  /// imagery from an already-decoded ancestor.
  bool isLoading,

  /// The tile produced label candidates (possibly provisional).
  bool hasSymbols,

  /// The tile's fade-in has finished.
  bool isFadedIn,
});

/// Whether [a] and [b] cover any common ground, at equal or differing
/// zoom levels.
bool tilesOverlap(TileKey a, TileKey b) {
  if (a.z == b.z) return a.x == b.x && a.y == b.y;
  final hi = a.z > b.z ? a : b;
  final lo = a.z > b.z ? b : a;
  final shift = hi.z - lo.z;
  return (hi.x >> shift) == lo.x && (hi.y >> shift) == lo.y;
}

/// Whether the previous zoom level may now be discarded.
///
/// The old level has to survive until the new one is rasterized *and*
/// fully faded in: dropping it mid-fade exposes the background colour
/// through the half-transparent new tiles, which reads as a blink on
/// every zoom level change.
bool currentLevelReady(Iterable<CurrentTileStatus> current) =>
    current.every((tile) => !tile.isLoading && tile.isFadedIn);

/// Whether a retained tile must keep contributing its labels.
///
/// It does while some overlapping current-level tile still has no label
/// data of its own, and also when nothing of the current level overlaps
/// it at all — otherwise every label blinks out for the few frames it
/// takes the new level to arrive.
bool retainedSymbolsNeeded({
  required TileKey retainedKey,
  required bool hasSymbols,
  required Iterable<CurrentTileStatus> current,
}) {
  if (!hasSymbols) return false;
  var overlapsAny = false;
  for (final tile in current) {
    if (!tilesOverlap(retainedKey, tile.key)) continue;
    overlapsAny = true;
    if (!tile.hasSymbols && tile.isLoading) return true;
  }
  return !overlapsAny;
}
