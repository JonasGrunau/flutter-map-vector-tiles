import 'dart:ui';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/expression_parser.dart';
import 'package:flutter_map_vector_tiles/src/style/feature_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FeatureStates', () {
    test('set merges keys, as MapLibre does', () {
      final states = FeatureStates();
      expect(states.set('s', 'l', 1, {'a': 1}), isTrue);
      expect(states.set('s', 'l', 1, {'b': 2}), isTrue);
      expect(states.lookup('s', 'l', 1), {'a': 1, 'b': 2});
      expect(states.lookup('s', 'other', 1), isNull);
      expect(states.lookup('other', 'l', 1), isNull);
    });

    test('setting values the feature already has changes nothing', () {
      final states = FeatureStates();
      states.set('s', 'l', 1, {'a': 1, 'b': 2});
      final version = states.version;
      expect(states.set('s', 'l', 1, {'a': 1}), isFalse);
      expect(states.set('s', 'l', 1, const {}), isFalse);
      expect(states.version, version);
      expect(states.set('s', 'l', 1, {'a': 3}), isTrue);
      expect(states.version, isNot(version));
    });

    test('a number and its decimal string are the same feature', () {
      final states = FeatureStates();
      states.set('s', 'l', 42, {'hit': true});
      expect(states.lookup('s', 'l', '42'), {'hit': true});
      expect(states.lookup('s', 'l', 42.0), {'hit': true});
      states.set('s', 'l', 'abc', {'hit': true});
      expect(states.lookup('s', 'l', 'abc'), {'hit': true});
      // Not canonical, so not the number.
      expect(states.lookup('s', 'l', '042'), isNull);
      expect(FeatureStates.normalizeId(1.5), 1.5);
      expect(FeatureStates.normalizeId(double.infinity), double.infinity);
    });

    test('remove takes one key, one feature, or the source layer', () {
      final states = FeatureStates();
      states
        ..set('s', 'l', 1, {'a': 1, 'b': 2})
        ..set('s', 'l', 2, {'a': 1})
        ..set('s', 'k', 3, {'a': 1});
      expect(states.remove('s', 'l', id: 1, key: 'a'), {1});
      expect(states.lookup('s', 'l', 1), {'b': 2});
      expect(states.remove('s', 'l', id: 1, key: 'missing'), isEmpty);
      expect(states.remove('s', 'l', id: '1'), {1});
      expect(states.lookup('s', 'l', 1), isNull);
      states.set('s', 'l', 1, {'a': 1});
      expect(states.remove('s', 'l'), {1, 2});
      expect(states.sourceLayer('s', 'l'), isNull);
      expect(states.lookup('s', 'k', 3), {'a': 1});
      expect(states.remove('s', 'k'), {3});
      expect(states.isEmpty, isTrue);
      expect(states.remove('s', 'k'), isEmpty);
    });

    test('two stores never share a version once either changed', () {
      final a = FeatureStates(), b = FeatureStates();
      a.set('s', 'l', 1, {'x': 1});
      b.set('s', 'l', 1, {'x': 2});
      expect(a.version, isNot(b.version));
    });
  });

  group('VectorTileLayerController state', () {
    test('getFeatureState is a read-only snapshot', () {
      final controller = VectorTileLayerController();
      controller.setFeatureState(
          source: 's', sourceLayer: 'l', id: 7, state: {'on': true});
      final state =
          controller.getFeatureState(source: 's', sourceLayer: 'l', id: '7');
      expect(state, {'on': true});
      expect(() => state['on'] = false, throwsUnsupportedError);
      controller.setFeatureState(
          source: 's', sourceLayer: 'l', id: 7, state: {'on': false});
      expect(state, {'on': true});
      expect(controller.getFeatureState(source: 's', sourceLayer: 'l', id: 8),
          isEmpty);
    });

    test('removing one key needs the feature id', () {
      final controller = VectorTileLayerController();
      expect(
          () => controller.removeFeatureState(
              source: 's', sourceLayer: 'l', key: 'on'),
          throwsArgumentError);
    });

    test('a detached controller queries nothing', () {
      final controller = VectorTileLayerController();
      expect(controller.isAttached, isFalse);
      expect(controller.queryRenderedFeatures(Offset.zero), isEmpty);
      expect(
          controller
              .queryRenderedFeaturesInRect(const Rect.fromLTWH(0, 0, 10, 10)),
          isEmpty);
    });
  });

  group('feature-state expression', () {
    Object? eval(Object json, Map<String, Object?>? state) =>
        ExpressionParser().parse(json)(featureContext(
          zoom: 10,
          properties: const {},
          geometryType: '',
          featureId: null,
          featureState: state,
        ));

    test('reads the feature state, null without one', () {
      expect(eval(['feature-state', 'hover'], {'hover': true}), isTrue);
      expect(eval(['feature-state', 'hover'], null), isNull);
      expect(eval(['feature-state', 'hover'], const {}), isNull);
      expect(
          eval([
            'case',
            [
              'boolean',
              ['feature-state', 'hover'],
              false
            ],
            1,
            0,
          ], {
            'hover': true
          }),
          1);
      expect(
          eval([
            'case',
            [
              'boolean',
              ['feature-state', 'hover'],
              false
            ],
            1,
            0,
          ], null),
          0);
      // A computed key.
      expect(
          eval([
            'feature-state',
            ['concat', 'ho', 'ver']
          ], {
            'hover': 5
          }),
          5);
    });

    test('a property reading state is never memoized against the zoom', () {
      final parser = ExpressionParser();
      expect(parser.readsFeatureState, isFalse);
      final p = parser.parseForProperty(['feature-state', 'hover']);
      expect(p.zoomOnly, isFalse);
      expect(parser.readsFeatureState, isTrue);
    });

    test('the theme reader marks the layers that read state', () {
      final theme = const ThemeReader().read({
        'layers': [
          {
            'id': 'plain',
            'type': 'fill',
            'source': 's',
            'source-layer': 'l',
            'paint': {'fill-color': '#ff0000'},
          },
          {
            'id': 'stateful',
            'type': 'line',
            'source': 's',
            'source-layer': 'l',
            'paint': {
              'line-width': [
                'case',
                [
                  'boolean',
                  ['feature-state', 'selected'],
                  false
                ],
                4,
                1,
              ],
            },
          },
          {
            'id': 'label',
            'type': 'symbol',
            'source': 's',
            'source-layer': 'l',
            'layout': {'text-field': '{name}'},
            'paint': {
              'text-color': [
                'coalesce',
                ['feature-state', 'color'],
                '#000'
              ],
            },
          },
        ],
      });
      expect([for (final l in theme.layers) l.readsFeatureState],
          [false, true, true]);
      final line = theme.layers[1] as LineThemeLayer;
      expect(line.width.zoomOnly, isFalse);
      expect(
          line.width.eval(const FeatureEvalContext(
              zoom: 10, featureState: {'selected': true})),
          4);
      expect(line.width.eval(const EvalContext(zoom: 10)), 1);
    });

    test('let bindings keep the state in scope', () {
      expect(
          eval([
            'let',
            'x',
            1,
            ['feature-state', 'hover'],
          ], {
            'hover': 'yes'
          }),
          'yes');
    });
  });
}
