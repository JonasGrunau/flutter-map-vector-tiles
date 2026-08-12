import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../cache/byte_cache.dart';
import '../cache/cache_resolver.dart';
import '../logger.dart';
import '../provider/network_vector_tile_provider.dart';
import '../provider/pmtiles/pmtiles_vector_tile_provider.dart';
import '../provider/vector_tile_provider.dart';
import '../tile_providers.dart';
import 'attribution.dart';
import 'sprite_atlas.dart';
import 'theme.dart';
import 'theme_reader.dart';

/// A ready-to-render style: compiled theme, tile providers, sprites and
/// the style's suggested initial camera.
class Style {
  final Theme theme;
  final TileProviders providers;

  /// Raster sources declared in the style, referenced by its `raster`
  /// layers. Pass to `VectorTileLayer.rasterSources`.
  final Map<String, RasterTileSource> rasterSources;
  final SpriteAtlas? sprites;
  final LatLng? center;
  final double? zoom;
  final String name;

  /// Attribution declared by the style's sources (or the TileJSON they
  /// point at), in document order, deduplicated by visible text —
  /// several sources of the same provider usually repeat one string.
  ///
  /// Show it on the map: most providers' terms of use require it.
  ///
  /// ```dart
  /// SimpleAttributionWidget(
  ///   source: Text(style.attributions.map((a) => a.text).join(' · ')),
  /// )
  /// ```
  final List<StyleAttribution> attributions;

  const Style({
    required this.theme,
    required this.providers,
    this.rasterSources = const {},
    this.sprites,
    this.center,
    this.zoom,
    this.name = '',
    this.attributions = const [],
  });

  /// Releases providers and sprite images. Call after the map using this
  /// style has been disposed.
  void dispose() {
    providers.dispose();
    for (final source in rasterSources.values) {
      source.dispose();
    }
    sprites?.dispose();
  }
}

/// Loads a MapLibre/Mapbox GL style document and everything it
/// references (TileJSON sources, sprites) into a [Style].
///
/// Handles the URI conventions of real-world providers — MapTiler,
/// OpenFreeMap, Stadia, ArcGIS, Protomaps — including `{key}`
/// substitution, relative sprite URLs, TileJSON indirection and
/// `pmtiles://` archive sources. Designed to be tolerant: anything
/// non-essential that fails to load is skipped with a warning.
class StyleReader {
  /// The style URL (`https://…/style.json?key={key}`), an
  /// `asset://path/to/style.json` URI, or `mapbox://styles/...` style id.
  final String uri;

  /// Substituted for `{key}` in the style URI and all URLs derived from
  /// the style document. For `mapbox://` URIs it becomes the
  /// `access_token`.
  final String? apiKey;

  /// Extra HTTP headers sent with the style, TileJSON and sprite
  /// requests, and forwarded to the created tile providers — for
  /// header-authenticated services (e.g. `Authorization`).
  final Map<String, String> headers;

  final Logger logger;
  final http.Client? httpClient;

  /// Whether to cache the style bundle (style.json, TileJSON, sprites)
  /// on disk. When a cached copy exists it is served instantly —
  /// including with no network at all — and refreshed in the background
  /// once older than [refreshAfter], so the map starts offline at any
  /// place whose style was loaded before.
  ///
  /// On web this flag is a no-op — there is no persistent style cache;
  /// the browser HTTP cache applies instead.
  final bool cache;

  /// Age past which a cached style resource is revalidated in the
  /// background. Until then it is served from disk without any request.
  final Duration refreshAfter;

  /// Resolves the style cache directory path; defaults to a subdirectory
  /// of the application support directory. Ignored on web, which relies
  /// on the browser HTTP cache instead.
  final Future<String> Function()? cachePath;

  /// Supplies the provider for a style source, bypassing the URL the
  /// style document declares for it. Return null to fall through to
  /// normal resolution.
  ///
  /// This is how a bundled offline archive replaces a hosted source while
  /// the style still contributes its theme, sprites and attribution —
  /// useful when the archive lives at a path only known at runtime, which
  /// no style document can name:
  ///
  /// ```dart
  /// final archive = await MbTilesVectorTileProvider.open(path);
  /// final style = await StyleReader(
  ///   uri: 'asset://styles/liberty.json',
  ///   resolveProvider: (id) async => id == 'openmaptiles' ? archive : null,
  /// ).read();
  /// ```
  ///
  /// Applies to raster sources as much as vector ones. The source's own
  /// `attribution` still applies; only the TileJSON-derived fallback is
  /// unavailable, since no TileJSON is fetched.
  ///
  /// The returned provider becomes owned by the [Style]: `Style.dispose()`
  /// disposes it along with the rest. Open one per style rather than
  /// sharing a single provider between two.
  final Future<VectorTileProvider?> Function(String sourceId)? resolveProvider;

  const StyleReader({
    required this.uri,
    this.apiKey,
    this.headers = const {},
    this.logger = const Logger.noop(),
    this.httpClient,
    this.cache = true,
    this.refreshAfter = const Duration(hours: 12),
    this.cachePath,
    this.resolveProvider,
  });

  Future<Style> read() async {
    final client = httpClient ?? http.Client();
    final ownsClient = httpClient == null;
    final styleCache = cache
        ? await openStyleCache(
            cachePath: cachePath, refreshAfter: refreshAfter, logger: logger)
        : null;
    final loader = _Loader(client, styleCache, logger, headers);
    try {
      final styleUrl = _substitute(expandMapboxUri(uri));
      final styleJson = await loader.loadJson(styleUrl);

      final theme = ThemeReader(logger: logger).read(styleJson);

      final sources = styleJson['sources'];
      final providers = <String, VectorTileProvider>{};
      final rasterSources = <String, RasterTileSource>{};
      // Keyed by visible text so repeats across sources collapse even
      // when their markup differs; a LinkedHashMap keeps document order.
      final attributions = <String, StyleAttribution>{};
      if (sources is Map) {
        for (final entry in sources.entries) {
          final id = entry.key as String;
          final source = entry.value;
          if (source is! Map) continue;
          final type = source['type'];
          if (type != 'vector' && type != 'raster') {
            logger.log('source "$id": type "$type" skipped '
                '(only vector and raster sources are rendered)');
            continue;
          }
          try {
            final map = source.cast<String, Object?>();
            // The source's own attribution wins over the TileJSON's, as
            // in MapLibre — that is how a style overrides its upstream.
            final _Source? built;
            if (type == 'vector') {
              built = await _createProvider(loader, id, map, styleUrl);
              if (built != null) providers[id] = built.provider;
            } else {
              // MapLibre source default maxzoom is 22; rasters routinely
              // go deeper than the vector default of 14.
              built = await _createProvider(loader, id, map, styleUrl,
                  defaultMaxZoom: 22);
              if (built != null) {
                rasterSources[id] = RasterTileSource(
                  provider: built.provider,
                  tileSize: (map['tileSize'] as num?)?.toInt() ?? 512,
                );
              }
            }
            if (built != null) {
              final declared =
                  (map['attribution'] as String?) ?? built.attribution;
              if (declared != null && declared.trim().isNotEmpty) {
                final parsed = StyleAttribution.parse(declared);
                if (parsed.text.isNotEmpty) {
                  attributions.putIfAbsent(parsed.text, () => parsed);
                }
              }
            }
          } catch (e) {
            logger.warn('source "$id" unavailable: $e');
          }
        }
      }
      if (providers.isEmpty && rasterSources.isEmpty) {
        throw const StyleReaderException('style contains no usable sources');
      }

      SpriteAtlas? sprites;
      final spriteBase = styleJson['sprite'];
      if (spriteBase is String && spriteBase.isNotEmpty) {
        try {
          sprites = await _loadSprites(loader, spriteBase, styleUrl);
        } catch (e) {
          logger.warn('sprites unavailable: $e');
        }
      }

      final centerJson = styleJson['center'];
      LatLng? center;
      if (centerJson is List && centerJson.length >= 2) {
        final lon = (centerJson[0] as num?)?.toDouble();
        final lat = (centerJson[1] as num?)?.toDouble();
        if (lon != null && lat != null) center = LatLng(lat, lon);
      }

      return Style(
        theme: theme,
        providers: TileProviders(providers),
        rasterSources: rasterSources,
        sprites: sprites,
        center: center,
        zoom: (styleJson['zoom'] as num?)?.toDouble(),
        name: styleJson['name'] as String? ?? '',
        attributions: List.unmodifiable(attributions.values),
      );
    } finally {
      if (ownsClient) {
        // Keep the client alive until background revalidations finish.
        // NOTE: block body — an arrow body returning a future would make
        // whenComplete await it (see the whenComplete deadlock note in
        // tile_store.dart).
        unawaited(Future.wait(loader.refreshes).whenComplete(() {
          client.close();
        }));
      }
    }
  }

  Future<_Source?> _createProvider(
    _Loader loader,
    String sourceId,
    Map<String, Object?> source,
    String styleUrl, {
    int defaultMaxZoom = 14,
  }) async {
    // Before any URL is looked at: the caller may be serving this source
    // from somewhere the style document cannot describe, such as a local
    // archive at a path only known at runtime.
    final substitute = await resolveProvider?.call(sourceId);
    if (substitute != null) return _Source(substitute);

    List<Object?>? tiles = source['tiles'] as List<Object?>?;
    var minZoom = (source['minzoom'] as num?)?.toInt();
    var maxZoom = (source['maxzoom'] as num?)?.toInt();

    final sourceUrl = source['url'] as String?;
    if (sourceUrl != null && sourceUrl.startsWith('pmtiles://')) {
      final archive = _substitute(
          _resolve(sourceUrl.substring('pmtiles://'.length), styleUrl));
      // Archives carry attribution in their metadata, but the style's own
      // `attribution` is the only value read here.
      return _Source(await PmTilesVectorTileProvider.open(
        archive,
        headers: headers,
        minimumZoom: minZoom,
        maximumZoom: maxZoom,
        logger: logger,
        // Only a caller-supplied client outlives read(); an owned one is
        // closed after the style bundle refreshes.
        client: httpClient,
      ));
    }

    // Relative tile templates resolve against the document that declared
    // them: the style for inline `tiles`, the TileJSON document otherwise
    // (ArcGIS declares `"url": "../../"` and `tile/{z}/{y}/{x}.pbf`).
    var templateBase = styleUrl;
    String? attribution;
    final tileJsonUrl = sourceUrl;
    if (tiles == null && tileJsonUrl != null) {
      final resolved =
          _substitute(expandMapboxUri(_resolve(tileJsonUrl, styleUrl)));
      final tileJson = await loader.loadJson(resolved);
      tiles = tileJson['tiles'] as List<Object?>?;
      templateBase = resolved;
      minZoom ??= (tileJson['minzoom'] as num?)?.toInt();
      maxZoom ??= (tileJson['maxzoom'] as num?)?.toInt();
      attribution = tileJson['attribution'] as String?;
    }
    final template = tiles?.whereType<String>().firstOrNull;
    if (template == null) return null;

    return _Source(
      NetworkVectorTileProvider(
        urlTemplate: _substitute(_resolveTemplate(template, templateBase)),
        headers: headers,
        minimumZoom: minZoom ?? 0,
        maximumZoom: maxZoom ?? defaultMaxZoom,
        logger: logger,
      ),
      attribution: attribution,
    );
  }

  Future<SpriteAtlas?> _loadSprites(
    _Loader loader,
    String spriteBase,
    String styleUrl,
  ) async {
    final base = _substitute(expandMapboxUri(_resolve(spriteBase, styleUrl)));
    // Prefer @2x sheets on modern screens; fall back to 1x.
    for (final (suffix, ratio) in [('@2x', 2.0), ('', 1.0)]) {
      final indexUri = _appendSpriteSuffix(base, '$suffix.json');
      final imageUri = _appendSpriteSuffix(base, '$suffix.png');
      try {
        final index = await loader.loadJson(indexUri);
        final bytes = await loader.loadBytes(imageUri);
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        codec.dispose();
        return SpriteAtlas(
          image: frame.image,
          sprites: SpriteAtlas.parseIndex(index),
          pixelRatio: ratio,
          cacheKey: imageUri,
        );
      } catch (e) {
        logger.log('sprite sheet $indexUri not usable: $e');
      }
    }
    return null;
  }

  /// Sprite URLs carry query parameters (`…/sprite?key=x`); the suffix
  /// must be inserted before the query.
  static String _appendSpriteSuffix(String base, String suffix) {
    final q = base.indexOf('?');
    return q < 0
        ? '$base$suffix'
        : '${base.substring(0, q)}$suffix${base.substring(q)}';
  }

  String _substitute(String url) => url.replaceAll('{key}', apiKey ?? '');

  /// Expands Mapbox's proprietary `mapbox://` scheme to api.mapbox.com
  /// URLs: style ids, sprite bases and bare tileset ids (as sources
  /// reference them). The inserted `{key}` placeholder is filled by
  /// [apiKey] — Mapbox calls it the access token.
  static String expandMapboxUri(String url) {
    if (!url.startsWith('mapbox://')) return url;
    final path = url.substring('mapbox://'.length);
    if (path.startsWith('styles/')) {
      final id = path.substring('styles/'.length);
      return 'https://api.mapbox.com/styles/v1/$id?access_token={key}';
    }
    if (path.startsWith('sprites/')) {
      final id = path.substring('sprites/'.length);
      return 'https://api.mapbox.com/styles/v1/$id/sprite?access_token={key}';
    }
    // A bare tileset id (`mapbox://mapbox.mapbox-streets-v8`) — its
    // TileJSON lives under /v4/.
    return 'https://api.mapbox.com/v4/$path.json?secure&access_token={key}';
  }

  /// Like [_resolve] for tile URL templates: `Uri.resolve` percent-encodes
  /// the `{z}`/`{x}`/`{y}` braces, which would defeat placeholder
  /// substitution, so they are restored after resolution.
  static String _resolveTemplate(String url, String baseUrl) =>
      _resolve(url, baseUrl).replaceAll('%7B', '{').replaceAll('%7D', '}');

  /// Resolves relative and scheme-relative URLs against the style URL.
  static String _resolve(String url, String baseUrl) {
    if (url.startsWith('http://') ||
        url.startsWith('https://') ||
        url.startsWith('asset://')) {
      return url;
    }
    if (url.startsWith('//')) return 'https:$url';
    final base = Uri.tryParse(baseUrl);
    if (base == null) return url;
    return base.resolve(url).toString();
  }

  /// Keeps API keys out of logs and exception messages.
  static String _redactKey(String url) =>
      url.replaceAll(RegExp(r'(key|api_key|access_token)=[^&]+'), r'$1=***');
}

/// Fetches style resources with stale-while-revalidate disk caching:
/// fresh cache entries skip the network entirely; stale entries are
/// served instantly (they are the offline path) while a background
/// request rewrites them for the next start; misses hit the network.
class _Loader {
  final http.Client client;
  final ByteCache? cache;
  final Logger logger;
  final Map<String, String> headers;

  /// In-flight background revalidations; awaited before an owned client
  /// is closed.
  final refreshes = <Future<void>>[];

  _Loader(this.client, this.cache, this.logger, this.headers);

  Future<Map<String, Object?>> loadJson(String url) async {
    final text = utf8.decode(await loadBytes(url));
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw StyleReaderException('expected JSON object from $url');
    }
    return decoded.cast<String, Object?>();
  }

  Future<Uint8List> loadBytes(String url) async {
    if (url.startsWith('asset://')) {
      final data = await rootBundle.load(url.substring('asset://'.length));
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    final diskCache = cache;
    if (diskCache == null) return _fetch(url);
    final fresh = await diskCache.get(url);
    if (fresh != null) return fresh;
    final stale = await diskCache.getStale(url);
    if (stale != null) {
      refreshes.add(_refresh(diskCache, url));
      return stale;
    }
    final bytes = await _fetch(url);
    // Awaited so the bundle is durably cached once read() returns —
    // style resources are small, and put() never throws.
    await diskCache.put(url, bytes);
    return bytes;
  }

  Future<void> _refresh(ByteCache diskCache, String url) async {
    try {
      await diskCache.put(url, await _fetch(url));
    } catch (e) {
      logger.log(
          'style revalidation failed for ${StyleReader._redactKey(url)}: $e');
    }
  }

  Future<Uint8List> _fetch(String url) async {
    final response = await client.get(Uri.parse(url), headers: headers);
    if (response.statusCode != 200) {
      throw StyleReaderException('HTTP ${response.statusCode} for '
          '${StyleReader._redactKey(url)}');
    }
    return response.bodyBytes;
  }
}

/// A built provider plus the attribution its TileJSON declared, if it
/// went through one.
class _Source {
  final VectorTileProvider provider;
  final String? attribution;

  const _Source(this.provider, {this.attribution});
}

class StyleReaderException implements Exception {
  final String message;
  const StyleReaderException(this.message);

  @override
  String toString() => 'StyleReaderException: $message';
}
