import 'dart:ui' show Color;

import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final style = <String, Object?>{
    'version': 8,
    'name': 'test-style',
    'layers': [
      {
        'id': 'bg',
        'type': 'background',
        'paint': {'background-color': '#112233'},
      },
      {
        'id': 'water',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'water',
        'paint': {'fill-color': 'rgb(0, 0, 255)', 'fill-opacity': 0.5},
      },
      {
        'id': 'roads',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'transportation',
        'minzoom': 5,
        'maxzoom': 18,
        'filter': ['==', 'class', 'motorway'],
        'paint': {
          'line-color': '#ff0000',
          'line-width': {
            'base': 1.4,
            'stops': [
              [6, 0.5],
              [20, 30],
            ],
          },
        },
        'layout': {'line-cap': 'round'},
      },
      {
        'id': 'labels',
        'type': 'symbol',
        'source': 'openmaptiles',
        'source-layer': 'place',
        'layout': {
          'text-field': '{name}',
          'text-size': 12,
          'text-font': ['Noto Sans Bold', 'Noto Sans Regular'],
          'text-offset': [0, 0.6],
        },
        'paint': {
          'line-dasharray': [2, 1]
        },
      },
      {
        'id': 'hidden',
        'type': 'fill',
        'source': 'openmaptiles',
        'source-layer': 'landuse',
        'layout': {'visibility': 'none'},
      },
      {
        'id': 'exotic',
        'type': 'hologram-3d',
      },
      'garbage entry',
    ],
  };

  test('reads layers, skipping hidden and unknown types', () {
    final theme = const ThemeReader().read(style);
    expect(theme.layers.map((l) => l.id), ['bg', 'water', 'roads', 'labels']);
  });

  test('background color evaluation', () {
    final theme = const ThemeReader().read(style);
    expect(theme.backgroundColor(10), const Color(0xff112233));
  });

  test('fill layer paints with opacity', () {
    final theme = const ThemeReader().read(style);
    final water = theme.layers[1] as FillThemeLayer;
    const ctx = EvalContext(zoom: 10);
    expect(water.color.eval(ctx), const Color(0xff0000ff));
    expect(water.opacity.eval(ctx), 0.5);
  });

  test('line layer zoom range and legacy width stops', () {
    final theme = const ThemeReader().read(style);
    final roads = theme.layers[2] as LineThemeLayer;
    expect(roads.coversZoom(4), false);
    expect(roads.coversZoom(5), true);
    expect(roads.coversZoom(18), false);
    expect(roads.width.eval(const EvalContext(zoom: 6)), closeTo(0.5, 0.001));
    expect(roads.width.eval(const EvalContext(zoom: 20)), closeTo(30, 0.001));
    expect(roads.cap.eval(const EvalContext(zoom: 10)), 'round');
  });

  test('filter compiles and references properties', () {
    final theme = const ThemeReader().read(style);
    final roads = theme.layers[2] as LineThemeLayer;
    expect(
        roads.matches(const EvalContext(
            zoom: 10,
            properties: {'class': 'motorway'},
            geometryType: 'LineString')),
        true);
    expect(
        roads.matches(const EvalContext(
            zoom: 10,
            properties: {'class': 'path'},
            geometryType: 'LineString')),
        false);
    expect(roads.referencedProperties, contains('class'));
  });

  test('token template text-field references properties', () {
    final theme = const ThemeReader().read(style);
    final labels = theme.layers[3] as SymbolThemeLayer;
    expect(
        labels.textField
            .eval(const EvalContext(zoom: 10, properties: {'name': 'München'})),
        'München');
    expect(labels.referencedProperties, contains('name'));
  });

  test('bare literal arrays are values, not expressions', () {
    // Regression: ['Noto Sans Bold'] / [0, 0.6] must not be parsed as
    // expressions with operator 'Noto Sans Bold' / 0.
    final theme = const ThemeReader().read(style);
    final labels = theme.layers[3] as SymbolThemeLayer;
    const ctx = EvalContext(zoom: 10);
    expect(labels.textFont.eval(ctx), ['Noto Sans Bold', 'Noto Sans Regular']);
    expect(labels.textOffset.eval(ctx), [0, 0.6]);
  });

  test('referenced source layers per source', () {
    final theme = const ThemeReader().read(style);
    expect(theme.referencedSourceLayers['openmaptiles'],
        containsAll(['water', 'transportation', 'place']));
  });

  test('legacy stop outputs of text-field expand their {tokens}', () {
    final theme = const ThemeReader().read({
      'layers': [
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {
            'text-field': {
              'stops': [
                [12, '{name:latin}'],
                [15, '{name:latin}\n{name:nonlatin}'],
                [17, 'literal'],
              ],
            },
          },
        },
      ],
    });
    final layer = theme.layers.single as SymbolThemeLayer;
    const props = {'name:latin': 'Moskva', 'name:nonlatin': 'Москва'};
    expect(layer.textField.eval(const EvalContext(zoom: 13, properties: props)),
        'Moskva');
    expect(layer.textField.eval(const EvalContext(zoom: 16, properties: props)),
        'Moskva\nМосква');
    expect(layer.textField.eval(const EvalContext(zoom: 18, properties: props)),
        'literal');
    // The token names are feature reads: the prep-side keep-filter
    // must not strip them.
    final referenced = layer.referencedProperties;
    if (referenced != null) {
      expect(referenced, containsAll(['name:latin', 'name:nonlatin']));
    }
  });

  test('a legacy function\'s default expands its {tokens}', () {
    final theme = const ThemeReader().read({
      'layers': [
        {
          'id': 'poi',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'poi',
          'layout': {
            'text-field': {
              'property': 'class',
              'type': 'categorical',
              'stops': [
                ['shop', '{name} (shop)'],
              ],
              'default': '{name}',
            },
          },
        },
      ],
    });
    final layer = theme.layers.single as SymbolThemeLayer;
    expect(
        layer.textField.eval(const EvalContext(
            zoom: 14, properties: {'class': 'shop', 'name': 'Rewe'})),
        'Rewe (shop)');
    expect(
        layer.textField.eval(const EvalContext(
            zoom: 14, properties: {'class': 'cafe', 'name': 'Tambosi'})),
        'Tambosi');
  });

  group('filterReadsZoom', () {
    bool readsZoom(Object? filter, {Map<String, Object?> paint = const {}}) =>
        const ThemeReader()
            .read({
              'layers': [
                {
                  'id': 'roads',
                  'type': 'line',
                  'source': 's',
                  'source-layer': 'transportation',
                  if (filter != null) 'filter': filter,
                  'paint': paint,
                },
              ],
            })
            .layers
            .single
            .filterReadsZoom;

    test('is false without a filter, and for legacy filters', () {
      expect(readsZoom(null), isFalse);
      expect(readsZoom(['==', 'class', 'motorway']), isFalse);
      expect(
          readsZoom([
            'all',
            ['==', r'$type', 'LineString'],
            ['in', 'class', 'primary', 'secondary'],
            ['!has', 'tunnel'],
          ]),
          isFalse);
    });

    test('is false for an expression filter on feature data only', () {
      expect(
          readsZoom([
            'all',
            [
              '==',
              ['get', 'class'],
              'motorway'
            ],
            [
              '==',
              ['geometry-type'],
              'LineString'
            ],
            [
              'match',
              ['get', 'brunnel'],
              ['bridge', 'tunnel'],
              false,
              true
            ],
          ]),
          isFalse);
    });

    test('is true wherever an expression filter reads the zoom', () {
      for (final filter in [
        [
          '<',
          ['zoom'],
          15
        ],
        [
          'let',
          'z',
          ['zoom'],
          [
            '>',
            ['var', 'z'],
            10
          ],
        ],
        [
          'step',
          ['zoom'],
          false,
          12,
          true
        ],
        [
          'case',
          [
            '==',
            ['get', 'class'],
            'path'
          ],
          [
            '>=',
            ['zoom'],
            15
          ],
          true,
        ],
        [
          '>',
          [
            'interpolate',
            ['linear'],
            ['zoom'],
            10,
            0,
            16,
            1
          ],
          ['get', 'rank'],
        ],
        // Legacy syntax around an expression: the expression still counts.
        [
          'all',
          ['==', 'class', 'path'],
          [
            '>=',
            ['zoom'],
            15
          ],
        ],
      ]) {
        expect(readsZoom(filter), isTrue, reason: '$filter');
      }
    });

    test('is true for a zoom-keyed legacy function inside a filter', () {
      expect(
          readsZoom([
            '==',
            ['get', 'rank'],
            {
              'stops': [
                [10, 1],
                [15, 2],
              ],
            },
          ]),
          isTrue);
      expect(
          readsZoom([
            '==',
            ['get', 'rank'],
            {'type': 'identity'},
          ]),
          isTrue);
      expect(
          readsZoom([
            '==',
            ['get', 'rank'],
            {
              'property': 'max_rank',
              'stops': [
                [1, 1],
                [5, 2],
              ],
            },
          ]),
          isFalse,
          reason: 'a property function reads feature data, not the zoom');
    });

    test('ignores zoom read by paint properties', () {
      expect(
          readsZoom(
            [
              '==',
              ['get', 'class'],
              'motorway'
            ],
            paint: {
              'line-width': [
                'interpolate',
                ['linear'],
                ['zoom'],
                10,
                1,
                16,
                4,
              ],
            },
          ),
          isFalse);
    });
  });

  group('global state', () {
    Map<String, Object?> stateStyle() => {
          'version': 8,
          'name': 'stateful',
          'state': {
            'highlight': {'default': 'park'},
            'opacity': {'default': 1},
          },
          'layers': [
            {
              'id': 'landuse',
              'type': 'fill',
              'source': 's',
              'source-layer': 'landuse',
              'filter': [
                '==',
                ['get', 'class'],
                ['global-state', 'highlight']
              ],
              'paint': {
                'fill-opacity': ['global-state', 'opacity'],
              },
            },
          ],
        };
    bool shows(Theme theme, String cls) => theme.layers.single
        .matches(EvalContext(zoom: 0, properties: {'class': cls}));
    double opacity(Theme theme) =>
        (theme.layers.single as FillThemeLayer).opacity.eval(EvalContext.empty);

    test("the style's state defaults are what expressions read", () {
      final theme = const ThemeReader().read(stateStyle());
      expect(theme.globalState, {'highlight': 'park', 'opacity': 1});
      expect(shows(theme, 'park'), isTrue);
      expect(shows(theme, 'forest'), isFalse);
      expect(theme.layers.single.filterReadsZoom, isFalse,
          reason: 'state is compiled in: the filter stays cacheable');
    });

    test('withGlobalState compiles a sibling with the overrides', () {
      final theme = const ThemeReader().read(stateStyle());
      final forest = theme.withGlobalState({'highlight': 'forest'});
      expect(shows(forest, 'forest'), isTrue);
      expect(shows(forest, 'park'), isFalse);
      expect(opacity(forest), 1, reason: 'unnamed keys keep their default');
      expect(forest.globalState, {'highlight': 'forest', 'opacity': 1});
      expect(forest.isSiblingOf(theme), isTrue);
      expect(forest.id, isNot(theme.id));
      expect(forest.id, startsWith(theme.id));
    });

    test('the same state is the same theme, so build methods are free', () {
      final theme = const ThemeReader().read(stateStyle());
      final a = theme.withGlobalState({'opacity': 0.5});
      expect(theme.withGlobalState({'opacity': 0.5}), same(a));
      expect(a.withGlobalState({'opacity': 0.5}), same(a));
      expect(theme.withGlobalState(const {}), same(theme));
      expect(a.withGlobalState({'opacity': null}), same(theme),
          reason: 'null returns a key to its default');
      expect(opacity(a), 0.5);
    });

    test('a style that reads no global state is its own sibling for all', () {
      final theme = const ThemeReader().read(style);
      expect(theme.withGlobalState({'anything': 1}), same(theme));
      expect(theme.isSiblingOf(theme), isFalse);
      expect(theme.globalState, isEmpty);
    });

    test('different styles are never siblings', () {
      final a = const ThemeReader().read(stateStyle());
      final b = const ThemeReader().read(stateStyle());
      expect(a.isSiblingOf(b), isFalse);
    });
  });

  test('readsGeometry marks layers whose expressions use within/distance', () {
    final theme = const ThemeReader().read({
      'layers': [
        {
          'id': 'near',
          'type': 'circle',
          'source': 's',
          'source-layer': 'poi',
          'paint': {
            'circle-opacity': [
              'case',
              [
                '<',
                [
                  'distance',
                  {
                    'type': 'Point',
                    'coordinates': [11.5, 48.1]
                  }
                ],
                1000
              ],
              1,
              0.3
            ],
          },
        },
        {
          'id': 'plain',
          'type': 'circle',
          'source': 's',
          'source-layer': 'poi',
        },
      ],
    });
    expect(theme.layers.map((l) => l.readsGeometry), [true, false]);
  });

  test('a property takes values of its own type', () {
    final theme = const ThemeReader().read({
      'layers': [
        {
          'id': 'labels',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'place',
          'layout': {
            // A single font written without brackets is a one-font stack.
            'text-font': 'Noto Sans Regular',
            'text-size': ['get', 'size'],
            'text-offset': ['get', 'offset'],
            'text-anchor': {
              'type': 'identity',
              'property': 'anchor',
              'default': 'top',
            },
          },
        },
      ],
    });
    final labels = theme.layers.single as SymbolThemeLayer;
    EvalContext feature(Map<String, Object?> properties) =>
        EvalContext(zoom: 10, properties: properties);
    expect(labels.textFont.eval(feature({})), ['Noto Sans Regular']);
    expect(labels.textSize.eval(feature({'size': 20})), 20);
    expect(labels.textSize.eval(feature({'size': '20'})), 16);
    expect(
        labels.textOffset.eval(feature({
          'offset': [1, 2]
        })),
        [1, 2]);
    expect(
        labels.textOffset.eval(feature({
          'offset': [1, 2, 3]
        })),
        [0, 0]);
    expect(labels.textAnchor.eval(feature({'anchor': 'left'})), 'left');
    expect(labels.textAnchor.eval(feature({'anchor': 'middle'})), 'top');
  });
}
