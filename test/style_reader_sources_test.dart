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

  test('mapbox:// style and source URIs expand to api.mapbox.com', () async {
    // Regression: the doc always claimed mapbox://styles/... support,
    // but nothing translated the scheme — the URI went straight to
    // http.Client.get and failed.
    final provider = await _readProvider(
      'mapbox://styles/acme/streets-v1',
      {
        'https://api.mapbox.com/styles/v1/acme/streets-v1?access_token=tok': {
          'version': 8,
          'sources': {
            'v': {'type': 'vector', 'url': 'mapbox://acme.tileset-v8'},
          },
          'layers': _minimalLayers,
        },
        'https://api.mapbox.com/v4/acme.tileset-v8.json'
            '?secure&access_token=tok': {
          'tiles': [
            'https://api.mapbox.com/v4/acme.tileset-v8'
                '/{z}/{x}/{y}.vector.pbf?access_token=tok'
          ],
          'maxzoom': 14,
        },
      },
      apiKey: 'tok',
    );
    expect(
      provider.urlTemplate,
      'https://api.mapbox.com/v4/acme.tileset-v8'
      '/{z}/{x}/{y}.vector.pbf?access_token=tok',
    );
    expect(provider.maximumZoom, 14);
  });

  test('expandMapboxUri covers styles, sprites and tileset ids', () {
    expect(
      StyleReader.expandMapboxUri('mapbox://styles/u/s'),
      'https://api.mapbox.com/styles/v1/u/s?access_token={key}',
    );
    expect(
      StyleReader.expandMapboxUri('mapbox://sprites/u/s'),
      'https://api.mapbox.com/styles/v1/u/s/sprite?access_token={key}',
    );
    expect(
      StyleReader.expandMapboxUri('mapbox://mapbox.streets-v8'),
      'https://api.mapbox.com/v4/mapbox.streets-v8.json'
      '?secure&access_token={key}',
    );
    expect(StyleReader.expandMapboxUri('https://a.example/style.json'),
        'https://a.example/style.json');
  });

  test('custom headers reach style fetches and the tile providers', () async {
    const styleUrl = 'https://maps.example.com/style.json';
    final routes = <String, Object?>{
      styleUrl: {
        'version': 8,
        'sources': {
          'v': {
            'type': 'vector',
            'url': 'https://maps.example.com/tiles.json',
          },
        },
        'layers': _minimalLayers,
      },
      'https://maps.example.com/tiles.json': {
        'tiles': ['https://maps.example.com/{z}/{x}/{y}.pbf'],
      },
    };
    final authSeen = <String, String?>{};
    final client = MockClient((request) async {
      authSeen[request.url.toString()] = request.headers['authorization'];
      final body = routes[request.url.toString()];
      if (body == null) return http.Response('not found', 404);
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    });

    final style = await StyleReader(
      uri: styleUrl,
      headers: const {'authorization': 'Bearer t'},
      httpClient: client,
      cache: false,
    ).read();
    addTearDown(style.dispose);

    expect(authSeen, hasLength(2)); // style + TileJSON
    expect(authSeen.values, everyElement('Bearer t'));
    final provider =
        style.providers.providers['v']! as NetworkVectorTileProvider;
    expect(provider.headers, const {'authorization': 'Bearer t'});
  });
}
