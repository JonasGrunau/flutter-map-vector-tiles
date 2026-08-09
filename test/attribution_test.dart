import 'dart:convert';

import 'package:flutter_map_vector_tiles/src/style/attribution.dart';
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

Future<Style> _read(String styleUrl, Map<String, Object?> routes) async {
  final style = await StyleReader(
    uri: styleUrl,
    httpClient: _serving(routes),
    cache: false,
  ).read();
  addTearDown(style.dispose);
  return style;
}

void main() {
  group('StyleAttribution.parse', () {
    test('flattens links into text and keeps them as spans', () {
      final attribution = StyleAttribution.parse(
        '<a href="https://protomaps.com">Protomaps</a> '
        '&copy; <a href="https://openstreetmap.org">OpenStreetMap</a>',
      );

      expect(attribution.text, 'Protomaps © OpenStreetMap');
      expect(attribution.spans, [
        const AttributionSpan('Protomaps', url: 'https://protomaps.com'),
        const AttributionSpan('©'),
        const AttributionSpan('OpenStreetMap',
            url: 'https://openstreetmap.org'),
      ]);
    });

    test('keeps trailing words and punctuation tight against the link', () {
      final attribution = StyleAttribution.parse(
        '&copy; <a href="https://www.openstreetmap.org/copyright" '
        'target="_blank">OpenStreetMap</a> contributors, '
        '<a href=\'https://carto.com\'>CARTO</a>.',
      );

      expect(attribution.text, '© OpenStreetMap contributors, CARTO.');
      expect(attribution.spans.map((s) => s.url).toList(), [
        null,
        'https://www.openstreetmap.org/copyright',
        null,
        'https://carto.com',
        null
      ]);
    });

    test('plain text passes through and strips stray markup', () {
      expect(StyleAttribution.parse('© MapTiler').text, '© MapTiler');
      expect(StyleAttribution.parse('a<br/>b &amp; c').text, 'a b & c');
    });

    test('an anchor without an href stays plain text', () {
      final attribution = StyleAttribution.parse('<a>Tiles</a> by me');
      expect(attribution.text, 'Tiles by me');
      expect(attribution.spans.first.url, isNull);
    });

    test('the raw declaration is preserved', () {
      const html = '<a href="https://example.com">Example</a>';
      expect(StyleAttribution.parse(html).html, html);
    });
  });

  group('StyleReader', () {
    test('reads attribution from the source', () async {
      const styleUrl = 'https://example.com/style.json';
      final style = await _read(styleUrl, {
        styleUrl: {
          'version': 8,
          'sources': {
            'v': {
              'type': 'vector',
              'tiles': ['https://example.com/{z}/{x}/{y}.pbf'],
              'attribution': '&copy; <a href="https://osm.org">OSM</a>',
            },
          },
          'layers': _minimalLayers,
        },
      });

      expect(style.attributions.single.text, '© OSM');
      expect(style.attributions.single.spans.last.url, 'https://osm.org');
    });

    test('falls back to the TileJSON attribution', () async {
      const styleUrl = 'https://example.com/style.json';
      const tileJsonUrl = 'https://example.com/tiles.json';
      final style = await _read(styleUrl, {
        styleUrl: {
          'version': 8,
          'sources': {
            'v': {'type': 'vector', 'url': tileJsonUrl},
          },
          'layers': _minimalLayers,
        },
        tileJsonUrl: {
          'tiles': ['https://example.com/{z}/{x}/{y}.pbf'],
          'attribution': '© MapTiler',
        },
      });

      expect(style.attributions.single.text, '© MapTiler');
    });

    test('the source overrides the TileJSON, as in MapLibre', () async {
      const styleUrl = 'https://example.com/style.json';
      const tileJsonUrl = 'https://example.com/tiles.json';
      final style = await _read(styleUrl, {
        styleUrl: {
          'version': 8,
          'sources': {
            'v': {
              'type': 'vector',
              'url': tileJsonUrl,
              'attribution': '© the style',
            },
          },
          'layers': _minimalLayers,
        },
        tileJsonUrl: {
          'tiles': ['https://example.com/{z}/{x}/{y}.pbf'],
          'attribution': '© the tilejson',
        },
      });

      expect(style.attributions.single.text, '© the style');
    });

    test('repeated attribution across sources is listed once, in order',
        () async {
      // The raster repeat differs in markup but not in what the user
      // reads, so it must still collapse.
      const styleUrl = 'https://example.com/style.json';
      final style = await _read(styleUrl, {
        styleUrl: {
          'version': 8,
          'sources': {
            'v': {
              'type': 'vector',
              'tiles': ['https://example.com/{z}/{x}/{y}.pbf'],
              'attribution': '© both',
            },
            'sat': {
              'type': 'raster',
              'tiles': ['https://example.com/sat/{z}/{x}/{y}.jpg'],
              'attribution': '&copy;  both',
            },
            'hill': {
              'type': 'raster',
              'tiles': ['https://example.com/hill/{z}/{x}/{y}.png'],
              'attribution': '© hillshade',
            },
          },
          'layers': _minimalLayers,
        },
      });

      expect(style.attributions.map((a) => a.text).toList(),
          ['© both', '© hillshade']);
    });

    test('a style without attribution reports none', () async {
      const styleUrl = 'https://example.com/style.json';
      final style = await _read(styleUrl, {
        styleUrl: {
          'version': 8,
          'sources': {
            'v': {
              'type': 'vector',
              'tiles': ['https://example.com/{z}/{x}/{y}.pbf'],
            },
          },
          'layers': _minimalLayers,
        },
      });

      expect(style.attributions, isEmpty);
    });

    test('a source that failed to build contributes no attribution', () async {
      const styleUrl = 'https://example.com/style.json';
      final style = await _read(styleUrl, {
        styleUrl: {
          'version': 8,
          'sources': {
            // No tiles and no url: unusable, but it must not take its
            // attribution into the list either.
            'broken': {'type': 'vector', 'attribution': '© nothing'},
            'v': {
              'type': 'vector',
              'tiles': ['https://example.com/{z}/{x}/{y}.pbf'],
              'attribution': '© real',
            },
          },
          'layers': _minimalLayers,
        },
      });

      expect(style.attributions.map((a) => a.text).toList(), ['© real']);
    });
  });
}
