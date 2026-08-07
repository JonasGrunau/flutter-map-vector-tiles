import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

import '../cache/disk_cache.dart';
import '../logger.dart';
import '../provider/network_vector_tile_provider.dart';
import '../provider/vector_tile_provider.dart';
import '../tile_providers.dart';
import 'sprite_atlas.dart';
import 'theme.dart';
import 'theme_reader.dart';

/// A ready-to-render style: compiled theme, tile providers, sprites and
/// the style's suggested initial camera.
class Style {
  final Theme theme;
  final TileProviders providers;
  final SpriteAtlas? sprites;
  final LatLng? center;
  final double? zoom;
  final String name;

  const Style({
    required this.theme,
    required this.providers,
    this.sprites,
    this.center,
    this.zoom,
    this.name = '',
  });

  /// Releases providers and sprite images. Call after the map using this
  /// style has been disposed.
  void dispose() {
    providers.dispose();
    sprites?.dispose();
  }
}

/// Loads a MapLibre/Mapbox GL style document and everything it
/// references (TileJSON sources, sprites) into a [Style].
///
/// Handles the URI conventions of real-world providers — MapTiler,
/// OpenFreeMap, Stadia, ArcGIS, Protomaps — including `{key}`
/// substitution, relative sprite URLs and TileJSON indirection. Designed
/// to be tolerant: anything non-essential that fails to load is skipped
/// with a warning.
class StyleReader {
  /// The style URL (`https://…/style.json?key={key}`), an
  /// `asset://path/to/style.json` URI, or `mapbox://styles/...` style id.
  final String uri;

  /// Substituted for `{key}` in the style URI and all URLs derived from
  /// the style document.
  final String? apiKey;

  final Logger logger;
  final http.Client? httpClient;

  /// Whether to cache the style bundle (style.json, TileJSON, sprites)
  /// on disk. When a cached copy exists it is served instantly —
  /// including with no network at all — and refreshed in the background
  /// once older than [refreshAfter], so the map starts offline at any
  /// place whose style was loaded before.
  final bool cache;

  /// Age past which a cached style resource is revalidated in the
  /// background. Until then it is served from disk without any request.
  final Duration refreshAfter;

  /// Resolves the style cache folder; defaults to a subdirectory of the
  /// application support directory.
  final Future<Directory> Function()? cacheFolder;

  const StyleReader({
    required this.uri,
    this.apiKey,
    this.logger = const Logger.noop(),
    this.httpClient,
    this.cache = true,
    this.refreshAfter = const Duration(hours: 12),
    this.cacheFolder,
  });

  Future<Style> read() async {
    final client = httpClient ?? http.Client();
    final ownsClient = httpClient == null;
    final loader = _Loader(client, cache ? await _openCache() : null, logger);
    try {
      final styleUrl = _substitute(uri);
      final styleJson = await loader.loadJson(styleUrl);

      final theme = ThemeReader(logger: logger).read(styleJson);

      final sources = styleJson['sources'];
      final providers = <String, VectorTileProvider>{};
      if (sources is Map) {
        for (final entry in sources.entries) {
          final id = entry.key as String;
          final source = entry.value;
          if (source is! Map) continue;
          if (source['type'] != 'vector') {
            logger.log('source "$id": type "${source['type']}" skipped '
                '(only vector sources are rendered)');
            continue;
          }
          try {
            final provider = await _createProvider(
                loader, source.cast<String, Object?>(), styleUrl);
            if (provider != null) providers[id] = provider;
          } catch (e) {
            logger.warn('source "$id" unavailable: $e');
          }
        }
      }
      if (providers.isEmpty) {
        throw const StyleReaderException(
            'style contains no usable vector sources');
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
        sprites: sprites,
        center: center,
        zoom: (styleJson['zoom'] as num?)?.toDouble(),
        name: styleJson['name'] as String? ?? '',
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

  /// Opens the on-disk style cache; failures degrade to network-only.
  Future<DiskCache?> _openCache() async {
    try {
      final dir = cacheFolder != null
          ? await cacheFolder!()
          : Directory('${(await getApplicationSupportDirectory()).path}'
              '${Platform.pathSeparator}flutter_map_vector_tiles'
              '${Platform.pathSeparator}style');
      final diskCache = DiskCache(
        directory: dir,
        ttl: refreshAfter,
        maxSizeBytes: 8 * 1024 * 1024,
        logger: logger,
      );
      await diskCache.initialize();
      return diskCache;
    } catch (e) {
      logger.warn('style cache unavailable: $e');
      return null;
    }
  }

  Future<VectorTileProvider?> _createProvider(
    _Loader loader,
    Map<String, Object?> source,
    String styleUrl,
  ) async {
    List<Object?>? tiles = source['tiles'] as List<Object?>?;
    var minZoom = (source['minzoom'] as num?)?.toInt();
    var maxZoom = (source['maxzoom'] as num?)?.toInt();

    final tileJsonUrl = source['url'] as String?;
    if (tiles == null && tileJsonUrl != null) {
      final resolved = _resolve(tileJsonUrl, styleUrl);
      final tileJson = await loader.loadJson(resolved);
      tiles = tileJson['tiles'] as List<Object?>?;
      minZoom ??= (tileJson['minzoom'] as num?)?.toInt();
      maxZoom ??= (tileJson['maxzoom'] as num?)?.toInt();
    }
    final template = tiles?.whereType<String>().firstOrNull;
    if (template == null) return null;

    return NetworkVectorTileProvider(
      urlTemplate: _substitute(_resolve(template, styleUrl)),
      minimumZoom: minZoom ?? 0,
      maximumZoom: maxZoom ?? 14,
      logger: logger,
    );
  }

  Future<SpriteAtlas?> _loadSprites(
    _Loader loader,
    String spriteBase,
    String styleUrl,
  ) async {
    final base = _substitute(_resolve(spriteBase, styleUrl));
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
  final DiskCache? cache;
  final Logger logger;

  /// In-flight background revalidations; awaited before an owned client
  /// is closed.
  final refreshes = <Future<void>>[];

  _Loader(this.client, this.cache, this.logger);

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

  Future<void> _refresh(DiskCache diskCache, String url) async {
    try {
      await diskCache.put(url, await _fetch(url));
    } catch (e) {
      logger.log(
          'style revalidation failed for ${StyleReader._redactKey(url)}: $e');
    }
  }

  Future<Uint8List> _fetch(String url) async {
    final response = await client.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw StyleReaderException('HTTP ${response.statusCode} for '
          '${StyleReader._redactKey(url)}');
    }
    return response.bodyBytes;
  }
}

class StyleReaderException implements Exception {
  final String message;
  const StyleReaderException(this.message);

  @override
  String toString() => 'StyleReaderException: $message';
}
