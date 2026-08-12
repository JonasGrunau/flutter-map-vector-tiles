import 'dart:async';

import '../../core/cancellation.dart';
import '../../core/single_flight.dart';
import '../../core/tile_key.dart';
import '../../logger.dart';
import '../vector_tile_provider.dart';
import 'mbtiles_metadata.dart';
import 'mbtiles_reader.dart';

/// Serves tiles from a local `.mbtiles` archive — the SQLite container
/// QGIS, tilemaker, TileServer GL and the Mapbox tooling all emit.
///
/// This is how you ship a guaranteed offline region, as opposed to the
/// visited-places disk cache: bundle or download an archive, point a
/// provider at it, and the map works with no network at all.
///
/// ```dart
/// final provider = await MbTilesVectorTileProvider.open(
///   '${(await getApplicationSupportDirectory()).path}/bavaria.mbtiles',
/// );
/// // …then hand it to the layer, keyed by the style's source id:
/// VectorTileLayer(
///   theme: style.theme,
///   tileProviders: TileProviders({'openmaptiles': provider}),
/// );
/// ```
///
/// Raster archives (`png`/`jpg`/`webp`) work the same way through a
/// `RasterTileSource` — the provider is bytes per coordinate either way.
///
/// **Native only.** Archives are SQLite files read through `dart:ffi`;
/// [open] throws [UnsupportedError] on web, where PMTiles over HTTP range
/// requests is the equivalent. On Android, Windows and Linux the app must
/// also depend on `sqlite3_flutter_libs` to ship the native library;
/// iOS and macOS use the system one.
class MbTilesVectorTileProvider extends VectorTileProvider {
  final MbTilesReader _reader;
  final Logger _logger;
  final _inFlight = SingleFlight<TileKey, TileResponse>();

  @override
  final int minimumZoom;
  @override
  final int maximumZoom;
  @override
  final String cacheKey;

  /// The archive's `metadata` table — its declared name, attribution,
  /// bounds and suggested camera, plus every row verbatim.
  ///
  /// Archives routinely carry the attribution their data requires; it is
  /// not displayed automatically, so read it from here if the style does
  /// not already declare one.
  MbTilesMetadata get metadata => _reader.metadata;

  var _disposed = false;

  MbTilesVectorTileProvider._({
    required MbTilesReader reader,
    required Logger logger,
    required this.minimumZoom,
    required this.maximumZoom,
    required this.cacheKey,
  })  : _reader = reader,
        _logger = logger;

  /// Opens the archive at [path].
  ///
  /// [minimumZoom] and [maximumZoom] override what the archive declares —
  /// pass a style source's `minzoom`/`maxzoom` to narrow it. When the
  /// archive declares neither and neither is passed, the range is derived
  /// from its tile table.
  ///
  /// [cacheKey] overrides the cache identity, which otherwise combines the
  /// path with the file's size and modification time so that replacing an
  /// archive in place does not inherit the previous one's cached tiles.
  /// Pass an explicit key only to share caches between providers
  /// deliberately.
  ///
  /// Throws [MbTilesException] when the file is missing, is not a SQLite
  /// database, or has no `tiles` table or view. Throws [UnsupportedError]
  /// on web.
  static Future<MbTilesVectorTileProvider> open(
    String path, {
    int? minimumZoom,
    int? maximumZoom,
    String? cacheKey,
    Logger logger = const Logger.noop(),
  }) async {
    final reader = await MbTilesReader.open(path);
    return MbTilesVectorTileProvider._(
      reader: reader,
      logger: logger,
      minimumZoom: minimumZoom ?? reader.minZoom,
      maximumZoom: maximumZoom ?? reader.maxZoom,
      cacheKey: cacheKey ?? 'mbtiles:${reader.identity}',
    );
  }

  /// The archive *is* the local copy; mirroring it into the disk cache
  /// would store every tile twice and leave a sentinel for every
  /// coordinate it does not cover.
  @override
  bool get cacheBytesToDisk => false;

  @override
  Future<TileResponse> load(TileKey tile, {CancellationToken? cancellation}) {
    if (tile.z < minimumZoom || tile.z > maximumZoom || !tile.isValid) {
      return Future.value(const TileResponseNotFound());
    }
    return _inFlight.run(tile, (token) => _load(tile, token),
        cancellation: cancellation);
  }

  Future<TileResponse> _load(TileKey tile, CancellationToken token) async {
    if (_disposed || token.isCancelled) return const TileResponseCancelled();
    try {
      // MBTiles rows are TMS — counted from the bottom — while TileKey is
      // slippy-map XYZ, counted from the top. Nothing upstream flips it.
      final tmsY = (1 << tile.z) - 1 - tile.y;
      final bytes = await _reader.tile(tile.z, tile.x, tmsY);
      if (_disposed || token.isCancelled) return const TileResponseCancelled();
      // Empty blobs are absence, not data: the pipeline's zero-byte disk
      // sentinel relies on providers never emitting empty data responses.
      if (bytes == null || bytes.isEmpty) return const TileResponseNotFound();
      // Returned exactly as stored. `pbf` archives hold gzip per the spec,
      // and the worker isolate inflates it there — doing it here would
      // burn UI-isolate time on every tile.
      return TileResponseData(bytes);
    } catch (e) {
      if (_disposed || token.isCancelled) return const TileResponseCancelled();
      _logger.warn('mbtiles tile ${tile.z}/${tile.x}/${tile.y} failed: $e');
      return TileResponseError(e);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _inFlight.clear();
    unawaited(_reader.close());
  }
}
