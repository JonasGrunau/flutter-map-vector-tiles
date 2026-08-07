import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

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

  const StyleReader({
    required this.uri,
    this.apiKey,
    this.logger = const Logger.noop(),
    this.httpClient,
  });

  Future<Style> read() async {
    final client = httpClient ?? http.Client();
    final ownsClient = httpClient == null;
    try {
      final styleUrl = _substitute(uri);
      final styleJson = await _loadJson(client, styleUrl);

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
                client, source.cast<String, Object?>(), styleUrl);
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
          sprites = await _loadSprites(client, spriteBase, styleUrl);
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
      if (ownsClient) client.close();
    }
  }

  Future<VectorTileProvider?> _createProvider(
    http.Client client,
    Map<String, Object?> source,
    String styleUrl,
  ) async {
    List<Object?>? tiles = source['tiles'] as List<Object?>?;
    var minZoom = (source['minzoom'] as num?)?.toInt();
    var maxZoom = (source['maxzoom'] as num?)?.toInt();

    final tileJsonUrl = source['url'] as String?;
    if (tiles == null && tileJsonUrl != null) {
      final resolved = _resolve(tileJsonUrl, styleUrl);
      final tileJson = await _loadJson(client, resolved);
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
    http.Client client,
    String spriteBase,
    String styleUrl,
  ) async {
    final base = _substitute(_resolve(spriteBase, styleUrl));
    // Prefer @2x sheets on modern screens; fall back to 1x.
    for (final (suffix, ratio) in [('@2x', 2.0), ('', 1.0)]) {
      final indexUri = _appendSpriteSuffix(base, '$suffix.json');
      final imageUri = _appendSpriteSuffix(base, '$suffix.png');
      try {
        final index = await _loadJson(client, indexUri);
        final bytes = await _loadBytes(client, imageUri);
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

  Future<Map<String, Object?>> _loadJson(http.Client client, String url) async {
    final text = utf8.decode(await _loadBytes(client, url));
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw StyleReaderException('expected JSON object from $url');
    }
    return decoded.cast<String, Object?>();
  }

  Future<Uint8List> _loadBytes(http.Client client, String url) async {
    if (url.startsWith('asset://')) {
      final data = await rootBundle.load(url.substring('asset://'.length));
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    final response = await client.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw StyleReaderException('HTTP ${response.statusCode} for '
          '${_redactKey(url)}');
    }
    return response.bodyBytes;
  }

  /// Keeps API keys out of logs and exception messages.
  static String _redactKey(String url) =>
      url.replaceAll(RegExp(r'(key|api_key|access_token)=[^&]+'), r'$1=***');
}

class StyleReaderException implements Exception {
  final String message;
  const StyleReaderException(this.message);

  @override
  String toString() => 'StyleReaderException: $message';
}
