import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../cache/lru_cache.dart';
import '../../core/cancellation.dart';
import '../../core/single_flight.dart';
import '../../core/tile_key.dart';
import '../../logger.dart';
import '../vector_tile_provider.dart';
import 'pmtiles_format.dart';
import 'pmtiles_gunzip_web.dart' if (dart.library.io) 'pmtiles_gunzip_io.dart';

/// Serves tiles from a single-file PMTiles v3 archive over HTTP range
/// requests — the format behind `pmtiles://` sources in MapLibre styles
/// (Protomaps).
///
/// The 127-byte header and root directory are fetched once by [open];
/// each tile then costs at most two range requests (a cached leaf
/// directory plus the tile blob). Directories and tiles compressed with
/// gzip are decompressed transparently; brotli/zstd archives are
/// rejected at [open].
///
/// Works like every other provider in this package: cancellation is a
/// state ([TileResponseCancelled]), never an exception; concurrent
/// requests for the same tile are coalesced; transient failures retry
/// with backoff.
class PmTilesVectorTileProvider extends VectorTileProvider {
  /// The archive URL (`https://…/tiles.pmtiles`, without the
  /// `pmtiles://` prefix).
  final String archiveUrl;
  final Map<String, String> headers;
  final PmTilesHeader header;
  final int maxRetries;
  final Logger logger;
  @override
  final int minimumZoom;
  @override
  final int maximumZoom;

  final http.Client _client;
  final bool _ownsClient;
  final PmTilesDirectory _root;
  final _leafDirectories = LruCache<int, PmTilesDirectory>(maxEntries: 32);
  final _leafInFlight = SingleFlight<int, PmTilesDirectory>();
  final _inFlight = SingleFlight<int, TileResponse>();
  var _disposed = false;

  PmTilesVectorTileProvider._({
    required this.archiveUrl,
    required this.headers,
    required this.header,
    required this.maxRetries,
    required this.logger,
    required this.minimumZoom,
    required this.maximumZoom,
    required http.Client client,
    required bool ownsClient,
    required PmTilesDirectory root,
  })  : _client = client,
        _ownsClient = ownsClient,
        _root = root;

  /// Fetches the header and root directory of the archive at [url] and
  /// returns a ready provider. Throws [PmTilesException] on a malformed
  /// or unsupported archive and [http.ClientException] on network
  /// failure.
  ///
  /// [minimumZoom]/[maximumZoom] override the archive header (a style's
  /// source `minzoom`/`maxzoom`). A passed [client] is shared and not
  /// closed on [dispose]; otherwise the provider owns one.
  static Future<PmTilesVectorTileProvider> open(
    String url, {
    Map<String, String> headers = const {},
    int? minimumZoom,
    int? maximumZoom,
    int maxRetries = 2,
    Logger logger = const Logger.noop(),
    http.Client? client,
  }) async {
    final ownsClient = client == null;
    final effectiveClient = client ?? http.Client();
    try {
      // The spec requires header + root directory within the first
      // 16 KiB, so one range request covers both.
      final prefix = await _fetch(effectiveClient, url, headers, 0, 16384,
          tolerateShort: true);
      final header = PmTilesHeader.parse(prefix);
      for (final compression in [
        header.internalCompression,
        header.tileCompression
      ]) {
        if (compression != PmTilesCompression.none &&
            compression != PmTilesCompression.gzip) {
          throw PmTilesException(
              'unsupported compression $compression (only none and gzip)');
        }
      }
      final rootEnd = header.rootDirectoryOffset + header.rootDirectoryLength;
      final rootBytes = rootEnd <= prefix.length
          ? Uint8List.sublistView(prefix, header.rootDirectoryOffset, rootEnd)
          : await _fetch(effectiveClient, url, headers,
              header.rootDirectoryOffset, header.rootDirectoryLength);
      final root = PmTilesDirectory.decode(
          header.internalCompression == PmTilesCompression.gzip
              ? await gunzip(rootBytes)
              : rootBytes);
      return PmTilesVectorTileProvider._(
        archiveUrl: url,
        headers: headers,
        header: header,
        maxRetries: maxRetries,
        logger: logger,
        minimumZoom: minimumZoom ?? header.minZoom,
        maximumZoom: maximumZoom ?? header.maxZoom,
        client: effectiveClient,
        ownsClient: ownsClient,
        root: root,
      );
    } catch (_) {
      if (ownsClient) effectiveClient.close();
      rethrow;
    }
  }

  @override
  String get cacheKey => 'pmtiles:$archiveUrl';

  @override
  Future<TileResponse> load(TileKey tile, {CancellationToken? cancellation}) {
    if (tile.z < minimumZoom ||
        tile.z > maximumZoom ||
        tile.z > pmTilesMaxAddressableZoom) {
      return Future.value(const TileResponseNotFound());
    }
    final tileId = zxyToTileId(tile.z, tile.x, tile.y);
    // Coalesced per tile id; the shared request polls a token joined over
    // every caller, so one cancelled caller never aborts a response
    // other callers still await.
    return _inFlight.run(tileId, (token) => _load(tileId, token),
        cancellation: cancellation);
  }

  Future<TileResponse> _load(int tileId, CancellationToken token) async {
    try {
      var directory = _root;
      // The spec discourages more than one level of leaf directories;
      // tolerate a second level anyway.
      for (var depth = 0; depth < 3; depth++) {
        if (_disposed || token.isCancelled) {
          return const TileResponseCancelled();
        }
        final entry = directory.find(tileId);
        if (entry == null) return const TileResponseNotFound();
        if (!entry.isLeaf) {
          final bytes = await _fetchRetrying(
              header.tileDataOffset + entry.offset, entry.length, token);
          if (bytes == null) return const TileResponseCancelled();
          if (bytes.isEmpty) return const TileResponseNotFound();
          return TileResponseData(
              header.tileCompression == PmTilesCompression.gzip
                  ? await gunzip(bytes)
                  : bytes);
        }
        directory = await _leafDirectory(entry, token) ?? directory;
        if (_disposed || token.isCancelled) {
          return const TileResponseCancelled();
        }
      }
      return const TileResponseNotFound();
    } catch (e) {
      if (_disposed || token.isCancelled) return const TileResponseCancelled();
      logger.warn('pmtiles tile $tileId failed: $e');
      return TileResponseError(e);
    }
  }

  Future<PmTilesDirectory?> _leafDirectory(
      PmTilesEntry entry, CancellationToken token) async {
    final cached = _leafDirectories.get(entry.offset);
    if (cached != null) return cached;
    // No caller token is joined: a leaf serves many tiles — always finish.
    return _leafInFlight.run(entry.offset, (_) async {
      final bytes = await _fetchRetrying(
          header.leafDirectoriesOffset + entry.offset,
          entry.length,
          CancellationToken.none);
      if (bytes == null) {
        throw const PmTilesException('leaf directory fetch cancelled');
      }
      final directory = PmTilesDirectory.decode(
          header.internalCompression == PmTilesCompression.gzip
              ? await gunzip(bytes)
              : bytes);
      _leafDirectories.put(entry.offset, directory);
      return directory;
    });
  }

  /// Range fetch with the same retry/backoff behaviour as
  /// `NetworkVectorTileProvider`. Returns null when cancelled.
  Future<Uint8List?> _fetchRetrying(
      int offset, int length, CancellationToken token) async {
    for (var attempt = 0;; attempt++) {
      if (_disposed || token.isCancelled) return null;
      Object error;
      try {
        return await _fetch(_client, archiveUrl, headers, offset, length);
      } on http.ClientException catch (e) {
        error = e;
      } on _RangeNotSupportedException catch (e) {
        logger.warn('pmtiles range request rejected: ${e.message}');
        rethrow; // permanent — the host cannot serve this archive
      }
      if (attempt >= maxRetries) throw error;
      await Future<void>.delayed(Duration(milliseconds: 250 * (1 << attempt)));
    }
  }

  static Future<Uint8List> _fetch(
    http.Client client,
    String url,
    Map<String, String> headers,
    int offset,
    int length, {
    bool tolerateShort = false,
  }) async {
    final response = await client.get(Uri.parse(url), headers: {
      ...headers,
      'range': 'bytes=$offset-${offset + length - 1}',
    });
    final status = response.statusCode;
    if (status == 206) return response.bodyBytes;
    if (status == 200) {
      // The host ignored the range header. Serving whole planet-scale
      // archives per tile is not workable — only accept a full body
      // when it actually covers the requested slice.
      final body = response.bodyBytes;
      if (offset == 0 && tolerateShort && body.length <= length) return body;
      if (body.length >= offset + length) {
        return Uint8List.sublistView(body, offset, offset + length);
      }
      throw const _RangeNotSupportedException(
          'host returned 200 with a short body for a range request');
    }
    if (tolerateShort && status == 416) {
      // Requested past the end of a tiny archive; retry unbounded.
      final retry = await client.get(Uri.parse(url), headers: headers);
      if (retry.statusCode == 200) return retry.bodyBytes;
    }
    throw http.ClientException(
        'HTTP $status for range request', Uri.parse(url));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _inFlight.clear();
    _leafInFlight.clear();
    if (_ownsClient) _client.close();
  }
}

class _RangeNotSupportedException implements Exception {
  final String message;
  const _RangeNotSupportedException(this.message);

  @override
  String toString() => 'RangeNotSupported: $message';
}
