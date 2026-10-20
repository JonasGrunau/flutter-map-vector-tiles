import 'dart:convert';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/label_language.dart';
import 'package:flutter_map_vector_tiles/src/style/style_reader.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/mvt_builder.dart';

/// `["coalesce", name:de, name_de, original]` — what a wrapped reference
/// looks like.
List<Object?> _de(Object? original) => [
      'coalesce',
      ['get', 'name:de'],
      ['get', 'name_de'],
      original,
    ];

/// OpenFreeMap Liberty's place and road labels, as served on 2026-10-14.
List<Object?> _liberty(String separator) => [
      'case',
      ['has', 'name:nonlatin'],
      [
        'concat',
        ['get', 'name:latin'],
        separator,
        ['get', 'name:nonlatin'],
      ],
      [
        'coalesce',
        ['get', 'name_en'],
        ['get', 'name'],
      ],
    ];

Map<String, Object?> _symbolStyle(Object? textField,
        {Object? filter, String type = 'symbol'}) =>
    {
      'version': 8,
      'name': 'test',
      'layers': [
        {
          'id': 'label',
          'type': type,
          'source': 'v',
          'source-layer': 'place',
          if (filter != null) 'filter': filter,
          'layout': {'text-field': textField},
        },
      ],
    };

SymbolThemeLayer _compile(Object? textField) =>
    const ThemeReader().read(_symbolStyle(textField)).layers.single
        as SymbolThemeLayer;

String _label(SymbolThemeLayer layer, Map<String, Object?> properties,
        {double zoom = 14}) =>
    layer.textField.eval(EvalContext(zoom: zoom, properties: properties));

void main() {
  group('localizeStyle', () {
    final style = _symbolStyle(_liberty('\n'), filter: [
      '==',
      [
        'resolved-locale',
        ['collator', <String, Object?>{}]
      ],
      'de',
    ]);

    test('without a language, the style comes back untouched', () {
      final before = jsonEncode(style);
      expect(identical(localizeStyle(style, null), style), isTrue);
      expect(identical(localizeStyle(style, ''), style), isTrue);
      expect(jsonEncode(style), before);
    });

    test('a style without names or locales comes back untouched', () {
      final plain = _symbolStyle('{ref}');
      expect(identical(localizeStyle(plain, 'de'), plain), isTrue);
    });

    test('never modifies its argument', () {
      final before = jsonEncode(style);
      final localized = localizeStyle(style, 'de');
      expect(jsonEncode(localized), isNot(before));
      expect(jsonEncode(style), before);
    });

    test('resolved-locale folds to the language, filters included', () {
      final layer = (localizeStyle(style, 'de')['layers']! as List).single
          as Map<String, Object?>;
      expect(layer['filter'], [
        '==',
        ['literal', 'de'],
        'de',
      ]);
    });

    test('only symbol layers get their text-field rewritten', () {
      final line = _symbolStyle(['get', 'name'], type: 'line');
      expect(identical(localizeStyle(line, 'de'), line), isTrue);
    });

    test('a name in a filter is left alone', () {
      final filtered = _symbolStyle('{ref}', filter: [
        '==',
        ['get', 'name'],
        'Main Street',
      ]);
      expect(identical(localizeStyle(filtered, 'de'), filtered), isTrue);
    });
  });

  group('localizeTextField', () {
    test('a plain get is wrapped', () {
      expect(localizeTextField(['get', 'name'], 'de'), _de(['get', 'name']));
    });

    test('the language is used verbatim in both tag spellings', () {
      expect(localizeTextField(['get', 'name'], 'zh-Hans'), [
        'coalesce',
        ['get', 'name:zh-Hans'],
        ['get', 'name_zh-Hans'],
        ['get', 'name'],
      ]);
    });

    test('Liberty: the whole case is wrapped, so the translation shows once',
        () {
      for (final separator in ['\n', ' ']) {
        expect(localizeTextField(_liberty(separator), 'de'),
            _de(_liberty(separator)));
      }
    });

    test('concat with a non-name suffix wraps only the name', () {
      expect(
        localizeTextField([
          'concat',
          ['get', 'name'],
          '\n',
          ['get', 'ele'],
          ' m',
        ], 'de'),
        [
          'concat',
          _de(['get', 'name']),
          '\n',
          ['get', 'ele'],
          ' m',
        ],
      );
    });

    test('concat wraps the run of arguments spanning the names', () {
      expect(
        localizeTextField([
          'concat',
          '« ',
          ['get', 'name:latin'],
          '\n',
          ['get', 'name:nonlatin'],
          ' (',
          ['get', 'ref'],
          ')',
        ], 'de'),
        [
          'concat',
          '« ',
          _de([
            'concat',
            ['get', 'name:latin'],
            '\n',
            ['get', 'name:nonlatin'],
          ]),
          ' (',
          ['get', 'ref'],
          ')',
        ],
      );
    });

    test('a concat that is all names is wrapped whole', () {
      final field = [
        'concat',
        ['get', 'name:latin'],
        ' ',
        ['get', 'name:nonlatin'],
      ];
      expect(localizeTextField(field, 'de'), _de(field));
    });

    test('names in conditions and match inputs stay as they are', () {
      expect(
        localizeTextField([
          'match',
          ['get', 'name'],
          '',
          ['get', 'ref'],
          ['get', 'name'],
        ], 'de'),
        [
          'match',
          ['get', 'name'],
          '',
          ['get', 'ref'],
          _de(['get', 'name']),
        ],
      );
      final conditionOnly = [
        'case',
        [
          '==',
          ['get', 'name'],
          '',
        ],
        ['get', 'ref'],
        ['get', 'class'],
      ];
      expect(identical(localizeTextField(conditionOnly, 'de'), conditionOnly),
          isTrue);
    });

    test('a zoom step wraps only the outputs that show a name', () {
      expect(
        localizeTextField([
          'step',
          ['zoom'],
          ['get', 'ref'],
          10,
          ['get', 'name'],
        ], 'de'),
        [
          'step',
          ['zoom'],
          ['get', 'ref'],
          10,
          _de(['get', 'name']),
        ],
      );
    });

    test('token templates become the equivalent expression', () {
      expect(localizeTextField('{name}', 'de'), _de(['get', 'name']));
      expect(
        localizeTextField('{name:latin}\n{name:nonlatin}', 'de'),
        _de([
          'concat',
          ['get', 'name:latin'],
          '\n',
          ['get', 'name:nonlatin'],
        ]),
      );
      expect(localizeTextField('{name} ({ref})', 'de'), [
        'concat',
        _de(['get', 'name']),
        ' (',
        ['get', 'ref'],
        ')',
      ]);
    });

    test('a zoom stop function over templates becomes a step', () {
      expect(
        localizeTextField({
          'stops': [
            [2, '{ref}'],
            [6, '{name}'],
          ],
        }, 'de'),
        [
          'step',
          ['zoom'],
          ['get', 'ref'],
          6,
          _de(['get', 'name']),
        ],
      );
    });

    test('fields without a name reference come back untouched', () {
      final fields = <Object?>[
        'Fixed text',
        '{ref}',
        '{NAME}',
        ['get', 'housenumber'],
        ['get', 'name', <String, Object?>{}],
        [
          'literal',
          ['get', 'name'],
        ],
        // MapLibre demotiles' country labels: no lowercase name tag.
        {
          'stops': [
            [2, '{ABBREV}'],
            [4, '{NAME}'],
          ],
        },
        // An exponential function interpolates neighbouring outputs that
        // read as numbers or colours, which a step would not.
        {
          'stops': [
            [0, '1'],
            [5, '2'],
            [10, '{name}'],
          ],
        },
        {
          'stops': [
            [0, 'red'],
            [5, 'blue'],
            [10, '{name}'],
          ],
        },
        // Data-driven functions are not rewritten.
        {
          'property': 'class',
          'type': 'categorical',
          'stops': [
            ['city', '{name}'],
          ],
        },
        null,
      ];
      for (final field in fields) {
        expect(identical(localizeTextField(field, 'de'), field), isTrue,
            reason: '$field');
      }
    });

    test('without a translation, every shape shows what it showed before', () {
      final fields = <Object?>[
        '{name}',
        '{name} ({ref})',
        '{name:latin}\n{name:nonlatin}',
        _liberty('\n'),
        {
          'stops': [
            [2, '{ref}'],
            [6, '{name}'],
            [9, '{name}\n{ele} m'],
          ],
        },
        {
          'type': 'interval',
          'stops': [
            [4, '{name:latin}'],
          ],
        },
        // Numeric outputs that never meet another one, or an interval
        // function, hold like a step.
        {
          'stops': [
            [0, '1'],
            [5, '{name}'],
          ],
        },
        {
          'type': 'interval',
          'stops': [
            [0, '1'],
            [5, '2'],
            [10, '{name}'],
          ],
        },
      ];
      final features = <Map<String, Object?>>[
        {'name': 'Milano', 'ref': 'MI', 'ele': 120},
        {'name:latin': 'Tokyo', 'name:nonlatin': '東京', 'name_en': 'Tokyo'},
        {'ref': 'A 9'},
        {},
      ];
      for (final field in fields) {
        final original = _compile(field);
        final localized = _compile(localizeTextField(field, 'de'));
        for (final properties in features) {
          for (final zoom in [0.0, 2.0, 2.5, 5.99, 6.0, 8.5, 9.0, 14.0, 22.0]) {
            expect(_label(localized, properties, zoom: zoom),
                _label(original, properties, zoom: zoom),
                reason: '$field at $zoom for $properties');
          }
        }
      }
    });

    test('with a translation, the label shows it', () {
      const munich = {
        'name': 'München',
        'name:latin': 'München',
        'name_en': 'Munich',
        'name:de': 'München (de)',
        'ele': 519,
      };
      expect(_label(_compile(localizeTextField(_liberty('\n'), 'de')), munich),
          'München (de)');
      expect(
          _label(_compile(localizeTextField('{name}\n{ele} m', 'de')), munich),
          'München (de)\n519 m');
      expect(
          _label(_compile(localizeTextField('{name}', 'de')),
              {'name': 'München', 'name_de': 'München (de_)'}),
          'München (de_)');
    });
  });

  group('StyleReader.language', () {
    const styleUrl = 'https://example.com/style.json';
    final styleJson = {
      'version': 8,
      'name': 'liberty-ish',
      'sources': {
        'v': {
          'type': 'vector',
          'tiles': ['https://example.com/{z}/{x}/{y}.pbf'],
        },
      },
      'layers': [
        {
          'id': 'place',
          'type': 'symbol',
          'source': 'v',
          'source-layer': 'place',
          'layout': {'text-field': _liberty('\n'), 'text-size': 14},
        },
      ],
    };

    Future<Style> read(String? language) async {
      final style = await StyleReader(
        uri: styleUrl,
        cache: false,
        language: language,
        httpClient: MockClient((request) async =>
            request.url.toString() == styleUrl
                ? http.Response(jsonEncode(styleJson), 200)
                : http.Response('not found', 404)),
      ).read();
      addTearDown(style.dispose);
      return style;
    }

    /// Prepares one MVT tile with the property keep-lists the layer
    /// derives from [theme], and lays out its labels.
    List<String> labels(Theme theme) {
      const key = TileKey(14, 8800, 5730);
      final keep = <String, Set<String>?>{
        for (final layer in theme.layers)
          if (layer.sourceLayer != null)
            layer.sourceLayer!: layer.referencedProperties,
      };
      final bytes = MvtTileBuilder()
          .layer('place')
          .feature(
            type: 1,
            geometry: [cmd(1, 1), zig(1024), zig(1024)],
            properties: {
              'name': 'Milano',
              'name:latin': 'Milano',
              'name:de': 'Mailand',
              'name:fr': 'Milan',
            },
          )
          .feature(
            type: 1,
            geometry: [cmd(1, 1), zig(3072), zig(3072)],
            properties: {'name': 'Bologna', 'name:latin': 'Bologna'},
          )
          .done()
          .build();
      final prepared = prepareTileSync(PrepareInput(
        z: key.z,
        x: key.x,
        y: key.y,
        bytes: bytes,
        layerProperties: keep,
      ));
      final properties = [
        for (final feature in prepared.layers['place']!.features)
          feature.properties,
      ];
      // Trimming still applies: only what the theme reads survives.
      expect(properties.first.containsKey('name:fr'), isFalse);
      final instances = SymbolLayouter.layout(
        theme: theme,
        data: DisplayTileData(displayKey: key, sources: {'v': prepared}),
        styleZoom: 14,
      );
      return [for (final instance in instances) instance.text];
    }

    test('labels a feature in its translation and falls back without one',
        () async {
      final style = await read('de');
      expect(labels(style.theme), ['Mailand', 'Bologna']);
    });

    test('tile preparation keeps the translated names', () async {
      final style = await read('de');
      final layer = style.theme.layers.single;
      expect(layer.referencedProperties,
          containsAll(<String>['name:de', 'name_de', 'name']));
    });

    test('without a language, labels are the style\'s own', () async {
      final style = await read(null);
      expect(style.theme.layers.single.referencedProperties,
          isNot(contains('name:de')));
      expect(labels(style.theme), ['Milano', 'Bologna']);
    });

    test('each language gets its own theme id, keeping cached tiles apart',
        () async {
      final ids = {
        for (final language in [null, 'de', 'fr'])
          (await read(language)).theme.id,
      };
      expect(ids, hasLength(3));
    });
  });
}
