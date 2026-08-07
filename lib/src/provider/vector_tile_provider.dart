import 'dart:typed_data';

import '../core/cancellation.dart';
import '../core/tile_key.dart';

/// Result of a tile load. Cancellation and absence are ordinary states —
/// they never surface as exceptions.
sealed class TileResponse {
  const TileResponse();
}

/// Tile bytes were retrieved.
class TileResponseData extends TileResponse {
  final Uint8List bytes;
  const TileResponseData(this.bytes);
}

/// The tile does not exist (404/204/empty body). Rendered as an empty
/// tile and cached as such.
class TileResponseNotFound extends TileResponse {
  const TileResponseNotFound();
}

/// The request was cancelled before completion.
class TileResponseCancelled extends TileResponse {
  const TileResponseCancelled();
}

/// A transient failure (network, 5xx). The pipeline may retry later.
class TileResponseError extends TileResponse {
  final Object error;
  const TileResponseError(this.error);
}

/// Provides raw vector tile (MVT) bytes for tile coordinates.
abstract class VectorTileProvider {
  /// Highest zoom the source has native tiles for. Higher display zooms
  /// are served by overzooming this level's tiles.
  int get maximumZoom;

  /// Lowest zoom the source has tiles for.
  int get minimumZoom;

  /// A stable identity for cache keys (e.g. the URL template).
  ///
  /// Both the disk cache and the process-wide decoded-tile cache key off
  /// this, so two providers sharing a [cacheKey] are taken to serve the same
  /// bytes for the same coordinates — including across layers, and after the
  /// layer that loaded them is gone. Give genuinely different sources
  /// different keys.
  String get cacheKey;

  Future<TileResponse> load(TileKey tile, {CancellationToken? cancellation});

  void dispose() {}
}
