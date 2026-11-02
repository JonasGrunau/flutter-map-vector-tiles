@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_map_vector_tiles/src/style/style_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/glyph_pbf_builder.dart';

/// `StyleReader` and a style's `glyphs`: the source it builds, the
/// ranges it asks for up front, and those ranges working offline from
/// the style cache.

const _glyphs = 'https://fonts.example.com/{fontstack}/{range}.pbf?key={key}';

Map<String, Object?> _style({String? glyphs = _glyphs}) => {
      'version': 8,
      if (glyphs != null) 'glyphs': glyphs,
      'sources': {
        'openmaptiles': {
          'type': 'vector',
          'tiles': ['https://tiles.example.com/{z}/{x}/{y}.pbf'],
        },
      },
      'layers': [
        {
          'id': 'label',
          'type': 'symbol',
          'source': 'openmaptiles',
          'source-layer': 'place',
          'layout': {
            'text-field': '{name}',
            'text-font': ['Noto Sans Regular'],
          },
        },
        {
          'id': 'data-driven',
          'type': 'symbol',
          'source': 'openmaptiles',
          'source-layer': 'poi',
          'layout': {
            'text-field': '{name}',
            'text-font': [
              'case',
              ['has', 'bold'],
              [
                'literal',
                ['Noto Sans Bold']
              ],
              [
                'literal',
                ['Noto Sans Italic']
              ],
            ],
          },
        },
      ],
    };

/// Serves the style and any glyph range, recording every URL asked for.
MockClient _serving(List<String> requests, {Map<String, Object?>? style}) =>
    MockClient((request) async {
      final url = request.url.toString();
      requests.add(url);
      if (url.contains('fonts.example.com')) {
        return http.Response.bytes(
            GlyphPbfBuilder()
                .stack('Noto Sans Regular', '0-255', [TestGlyph(0x41)]).build(),
            200);
      }
      return http.Response(jsonEncode(style ?? _style()), 200,
          headers: {'content-type': 'application/json'});
    });

MockClient get _offline =>
    MockClient((request) async => http.Response('unavailable', 503));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fmvt_glyphs');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  StyleReader reader(http.Client client) => StyleReader(
        uri: 'https://styles.example.com/streets/style.json?key={key}',
        apiKey: 'test-key',
        httpClient: client,
        cachePath: () async => dir.path,
      );

  /// Waits until [requests] holds a glyph URL, since the up-front range
  /// is asked for without holding up `read()`.
  Future<List<String>> glyphRequests(List<String> requests) async {
    for (var i = 0; i < 100; i++) {
      final found = requests.where((u) => u.contains('fonts.')).toList();
      if (found.isNotEmpty) return found;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return const [];
  }

  test('a style with glyphs gets a source, keyed by its template', () async {
    final requests = <String>[];
    final style = await reader(_serving(requests)).read();
    expect(style.glyphs, isNotNull);
    expect(style.glyphs!.signature,
        'https://fonts.example.com/{fontstack}/{range}.pbf?key=test-key');
    // Range 0 of the one constant `text-font`, asked for while loading;
    // the data-driven stack waits until a label needs it.
    expect(await glyphRequests(requests), [
      'https://fonts.example.com/Noto%20Sans%20Regular/0-255.pbf?key=test-key',
    ]);
    style.dispose();
  });

  test('a style without glyphs gets none', () async {
    final style =
        await reader(_serving([], style: _style(glyphs: null))).read();
    expect(style.glyphs, isNull);
    style.dispose();
  });

  test('glyph ranges come from the style cache when offline', () async {
    final requests = <String>[];
    final online = await reader(_serving(requests)).read();
    await online.glyphs!.ensure([('Noto Sans Regular', 0)]);
    expect(online.glyphs!.rangeOf('Noto Sans Regular', 0), isNotNull);
    online.dispose();

    final offline = await reader(_offline).read();
    await offline.glyphs!.ensure([('Noto Sans Regular', 0)]);
    expect(offline.glyphs!.rangeOf('Noto Sans Regular', 0), isNotNull,
        reason: 'served from disk with no network');
    // A range never fetched before has nothing to fall back on.
    await offline.glyphs!.ensure([('Noto Sans Regular', 256)]);
    expect(offline.glyphs!.rangeOf('Noto Sans Regular', 256), isNull);
    expect(offline.glyphs!.isLoading('Noto Sans Regular', 256), isFalse);
    offline.dispose();
  });

  test('mapbox:// glyph templates expand to the fonts API', () {
    expect(
        StyleReader.expandMapboxUri(
            'mapbox://fonts/mapbox/{fontstack}/{range}.pbf'),
        'https://api.mapbox.com/fonts/v1/mapbox/{fontstack}/{range}.pbf'
        '?access_token={key}');
  });
}
