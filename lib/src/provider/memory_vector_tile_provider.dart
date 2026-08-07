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
  @override
  final String cacheKey;

  MemoryVectorTileProvider({
    required this.tiles,
    this.maximumZoom = 14,
    this.minimumZoom = 0,
    this.cacheKey = 'memory',
  });

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) async {
    final bytes = tiles[tile];
    return bytes == null
        ? const TileResponseNotFound()
        : TileResponseData(bytes);
  }
}
