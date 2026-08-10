import 'dart:typed_data';

import '../core/cancellation.dart';
import '../core/tile_key.dart';
import 'vector_tile_provider.dart';

/// Serves tiles from an in-memory map — useful for tests and for bundled
/// offline regions.
class MemoryVectorTileProvider extends VectorTileProvider {
  final Map<TileKey, Uint8List> tiles;
  @override
  final int maximumZoom;
  @override
  final int minimumZoom;

  /// Defaults to a key derived from the tile set's shape, so two
  /// providers bundling different regions never share cache entries —
  /// a constant default silently served one region's tiles inside the
  /// other. Pass an explicit stable key to share caches deliberately
  /// (or to guarantee distinctness for data sets with identical
  /// coordinates and byte lengths).
  @override
  final String cacheKey;

  MemoryVectorTileProvider({
    required this.tiles,
    this.maximumZoom = 14,
    this.minimumZoom = 0,
    String? cacheKey,
  }) : cacheKey = cacheKey ?? _shapeKey(tiles);

  /// Deterministic across runs (unlike hashCode) so the disk cache and
  /// the process-wide decoded-tile cache still get reused for the same
  /// data. Multiply/modulo stay below 2^53 — exact under dart2js.
  static String _shapeKey(Map<TileKey, Uint8List> tiles) {
    final keys = tiles.keys.toList()
      ..sort((a, b) {
        if (a.z != b.z) return a.z - b.z;
        if (a.x != b.x) return a.x - b.x;
        return a.y - b.y;
      });
    var h = 17;
    for (final key in keys) {
      for (final part in [key.z, key.x, key.y, tiles[key]!.length]) {
        h = (h * 31 + part) % 0x100000000;
      }
    }
    return 'memory:${tiles.length}:$h';
  }

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    final bytes = tiles[tile];
    return bytes == null
        ? const TileResponseNotFound()
        : TileResponseData(bytes);
  }
}
