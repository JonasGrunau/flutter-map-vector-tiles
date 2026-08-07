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
}
