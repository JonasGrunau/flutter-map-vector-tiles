import 'tile_key.dart';

/// Logical display-tile size in points (the slippy-map convention).
///
/// Grid layout, rasterization and the label pass must all agree on this;
/// referencing one constant makes disagreement impossible instead of a
/// silent runtime misalignment.
const double displayTileSize = 256;

/// Resolves the data tile key serving [displayKey] at
/// `displayKey.z + dataZoomDelta`, clamped to the source's zoom range.
/// Returns null when the source cannot serve this display zoom at all
/// (its minimum zoom lies above it).
///
/// [capAtDisplayZoom] is the raster rule: 256px sources fetch one level
/// deeper for the same visual scale, but never *under*zoom (several
/// data tiles per display tile) — the tile is upscaled instead.
TileKey? dataKeyForDisplay(
  TileKey displayKey,
  int dataZoomDelta, {
  required int minimumZoom,
  required int maximumZoom,
  bool capAtDisplayZoom = false,
}) {
  var dataZoom = displayKey.z + dataZoomDelta;
  if (capAtDisplayZoom && dataZoom > displayKey.z) dataZoom = displayKey.z;
  dataZoom = dataZoom.clamp(minimumZoom, maximumZoom);
  if (dataZoom > displayKey.z) return null;
  return TileKey.wrapped(
    dataZoom,
    displayKey.x >> (displayKey.z - dataZoom),
    displayKey.y >> (displayKey.z - dataZoom),
  );
}

/// Returns [dataKey]'s entry or its nearest ancestor's, walking at most
/// five levels up — used to render provisional imagery instantly while
/// the real tile loads (fast zoom-in never shows blank tiles).
T? findWithAncestors<T>(
  TileKey dataKey,
  int minimumZoom,
  T? Function(TileKey key) lookup,
) {
  var key = dataKey;
  for (var i = 0; i <= 5; i++) {
    final found = lookup(key);
    if (found != null) return found;
    if (key.z == 0 || key.z <= minimumZoom) return null;
    key = key.parent;
  }
  return null;
}

/// Collects [dataKey]'s cached descendants, walking at most two levels
/// down — the zoom-out counterpart of [findWithAncestors]. A found
/// child stands in whole; a missing one is searched a level deeper, so
/// the cover may be partial. A partial cover of sharp pixels still
/// beats the background a cold zoom-out would otherwise show.
List<T> findDescendants<T>(
  TileKey dataKey,
  int maximumZoom,
  T? Function(TileKey key) lookup,
) {
  final found = <T>[];
  void collect(TileKey key, int levelsLeft) {
    if (levelsLeft == 0 || key.z >= maximumZoom) return;
    for (var dy = 0; dy <= 1; dy++) {
      for (var dx = 0; dx <= 1; dx++) {
        final child = TileKey(key.z + 1, key.x * 2 + dx, key.y * 2 + dy);
        final entry = lookup(child);
        if (entry != null) {
          found.add(entry);
        } else {
          collect(child, levelsLeft - 1);
        }
      }
    }
  }

  collect(dataKey, 2);
  return found;
}
