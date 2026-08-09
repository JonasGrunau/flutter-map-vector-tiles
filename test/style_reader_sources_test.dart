import 'dart:convert';

import 'package:flutter_map_vector_tiles/src/provider/network_vector_tile_provider.dart';
import 'package:flutter_map_vector_tiles/src/style/style_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

MockClient _serving(Map<String, Object?> routes) => MockClient((request) async {
      final body = routes[request.url.toString()];
      if (body == null) return http.Response('not found', 404);
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    });

List<Object?> get _minimalLayers => [
      {
        'id': 'bg',
        'type': 'background',
        'paint': {'background-color': '#ffffff'},
      },
    ];

Future<NetworkVectorTileProvider> _readProvider(
  String styleUrl,
  Map<String, Object?> routes, {
  String sourceId = 'v',
  String? apiKey,
}) async {
  final style = await StyleReader(
    uri: styleUrl,
    apiKey: apiKey,
    httpClient: _serving(routes),
    cache: false,
  ).read();
  addTearDown(style.dispose);
  return style.providers.providers[sourceId]! as NetworkVectorTileProvider;
}

void main() {
  test(
      'ArcGIS root.json: relative TileJSON and tile template '
      'resolve against the service root', () async {
    const styleUrl = 'https://example.com/arcgis/rest/services/World'
        '/VectorTileServer/resources/styles/root.json';
    final provider = await _readProvider(
      styleUrl,
      {
        styleUrl: {
          'version': 8,
          'sources': {
            'esri': {'type': 'vector', 'url': '../../'},
          },
          'layers': _minimalLayers,
        },
        'https://example.com/arcgis/rest/services/World/VectorTileServer/': {
          'tiles': ['tile/{z}/{y}/{x}.pbf'],
          'maxzoom': 22,
        },
      },
      sourceId: 'esri',
    );
    expect(
      provider.urlTemplate,
      'https://example.com/arcgis/rest/services/World/VectorTileServer'
      '/tile/{z}/{y}/{x}.pbf',
    );
    expect(provider.maximumZoom, 22);
  });

  test('relative inline tile template resolves against the style URL',
      () async {
    const styleUrl = 'https://maps.example.com/styles/basic/style.json';
    final provider = await _readProvider(styleUrl, {
      styleUrl: {
        'version': 8,
        'sources': {
          'v': {
            'type': 'vector',
            'tiles': ['../../data/{z}/{x}/{y}.pbf'],
            'maxzoom': 14,
          },
        },
        'layers': _minimalLayers,
      },
    });
    expect(
        provider.urlTemplate, 'https://maps.example.com/data/{z}/{x}/{y}.pbf');
  });

  test('{key} is substituted in TileJSON source URLs', () async {
    const styleUrl =
        'https://api.example.com/maps/streets/style.json?key={key}';
    final provider = await _readProvider(
      styleUrl,
      {
        'https://api.example.com/maps/streets/style.json?key=k123': {
          'version': 8,
          'sources': {
            'v': {
              'type': 'vector',
              'url': 'https://api.example.com/tiles/v3/tiles.json?key={key}',
            },
          },
          'layers': _minimalLayers,
        },
        'https://api.example.com/tiles/v3/tiles.json?key=k123': {
          'tiles': [
            'https://api.example.com/tiles/v3/{z}/{x}/{y}.pbf?key={key}'
          ],
          'minzoom': 0,
          'maxzoom': 14,
        },
      },
      apiKey: 'k123',
    );
    expect(
      provider.urlTemplate,
      'https://api.example.com/tiles/v3/{z}/{x}/{y}.pbf?key=k123',
    );
  });
}
