import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../core/cancellation.dart';
import '../core/tile_key.dart';
import '../logger.dart';
import 'vector_tile_provider.dart';

/// Loads tiles over HTTP from a `{z}/{x}/{y}` URL template.
///
/// * concurrent requests for the same tile are coalesced;
/// * transient failures are retried with backoff;
/// * cancellation never throws.
class NetworkVectorTileProvider extends VectorTileProvider {
  /// URL template containing `{z}`, `{x}` and `{y}` placeholders.
  final String urlTemplate;
  final Map<String, String> headers;
  @override
  final int maximumZoom;
  @override
  final int minimumZoom;
  final int maxRetries;
  final Logger logger;

  final http.Client _client;
  final bool _ownsClient;
  final _inFlight = <String, Future<TileResponse>>{};
  var _disposed = false;

  NetworkVectorTileProvider({
    required this.urlTemplate,
    this.headers = const {},
    this.maximumZoom = 14,
    this.minimumZoom = 0,
    this.maxRetries = 2,
    this.logger = const Logger.noop(),
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  @override
  String get cacheKey => urlTemplate;

  String _url(TileKey tile) => urlTemplate
      .replaceAll('{z}', tile.z.toString())
      .replaceAll('{x}', tile.x.toString())
      .replaceAll('{y}', tile.y.toString());

  @override
  Future<TileResponse> load(TileKey tile,
      {CancellationToken? cancellation}) {
    final url = _url(tile);
    final pending = _inFlight[url];
    if (pending != null) return pending;
    // NOTE: block body — an arrow body would return the removed value,
    // which is this very future, and whenComplete awaits a returned
    // future: the future would deadlock waiting on itself.
    final future =
        _load(url, cancellation ?? CancellationToken.none).whenComplete(() {
      _inFlight.remove(url);
    });
    _inFlight[url] = future;
    return future;
  }

  Future<TileResponse> _load(String url, CancellationToken token) async {
    for (var attempt = 0;; attempt++) {
      if (_disposed || token.isCancelled) {
        return const TileResponseCancelled();
      }
      Object error;
      try {
        final response =
            await _client.get(Uri.parse(url), headers: headers);
        if (_disposed || token.isCancelled) {
          return const TileResponseCancelled();
        }
        final status = response.statusCode;
        if (status == 200) {
          final bytes = response.bodyBytes;
          return bytes.isEmpty
              ? const TileResponseNotFound()
              : TileResponseData(Uint8List.fromList(bytes));
        }
        if (status == 204 || status == 404 || status == 410) {
          return const TileResponseNotFound();
        }
        if (status == 401 || status == 403) {
          logger.warn('tile request unauthorized ($status): $url');
          return TileResponseError(http.ClientException('HTTP $status'));
        }
        error = http.ClientException('HTTP $status');
      } catch (e) {
        error = e;
      }
      if (attempt >= maxRetries) {
        logger.warn('tile request failed: $url ($error)');
        return TileResponseError(error);
      }
      await Future<void>.delayed(
          Duration(milliseconds: 250 * (1 << attempt)));
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _inFlight.clear();
    if (_ownsClient) _client.close();
  }
}
