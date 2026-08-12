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

/// Provides raw tile bytes for tile coordinates — MVT data for vector
/// sources, encoded images (PNG/JPEG/WebP) when used in a
/// `RasterTileSource`.
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

  /// Whether the pipeline should mirror this provider's bytes into the
  /// on-disk tile cache.
  ///
  /// True for remote sources, where that cache is what makes a revisit
  /// instant and offline. Override to false for providers already backed
  /// by local storage: a local archive would otherwise be copied tile by
  /// tile into a second on-disk copy, and every absent tile would leave a
  /// zero-byte sentinel behind.
  ///
  /// Opting out skips the disk cache on the way *in* as well — a stale
  /// entry written before the source became local must not shadow it.
  /// Stale-while-revalidate therefore never engages for such a provider;
  /// failure throttling still does.
  bool get cacheBytesToDisk => true;

  Future<TileResponse> load(TileKey tile, {CancellationToken? cancellation});

  void dispose() {}
}
