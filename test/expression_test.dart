import 'dart:ui' show Color;

import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/expression_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Object? eval(Object? json,
      {double zoom = 10,
      Map<String, Object?>? props,
      String geometryType = 'Point'}) {
    return ExpressionParser().parse(json)(EvalContext(
      zoom: zoom,
      properties: props ?? const {},
      geometryType: geometryType,
    ));
  }

  bool evalFilter(Object? json,
      {double zoom = 10,
      Map<String, Object?>? props,
      String geometryType = 'Point',
      Object? id}) {
    return toBoolean(ExpressionParser().parseFilter(json)(EvalContext(
      zoom: zoom,
      properties: props ?? const {},
      geometryType: geometryType,
      featureId: id,
    )));
  }

  group('literals and lookup', () {
    test('scalars evaluate to themselves', () {
      expect(eval(5), 5.0);
      expect(eval('hello'), 'hello');
      expect(eval(true), true);
      expect(eval(null), null);
    });

    test('get and has read feature properties', () {
      expect(eval(['get', 'name'], props: {'name': 'A'}), 'A');
      expect(eval(['get', 'missing'], props: {}), null);
      expect(eval(['has', 'name'], props: {'name': 'A'}), true);
      expect(eval(['has', 'x'], props: {'name': 'A'}), false);
    });

    test('zoom and geometry-type', () {
      expect(eval(['zoom'], zoom: 7.5), 7.5);
      expect(eval(['geometry-type'], geometryType: 'LineString'), 'LineString');
    });
  });

  group('decisions', () {
    test('comparisons', () {
      expect(
          eval([
            '==',
            ['get', 'a'],
            1
          ], props: {
            'a': 1
          }),
          true);
      expect(
          eval([
            '==',
            ['get', 'a'],
            1
          ], props: {
            'a': 2
          }),
          false);
      expect(
          eval([
            '!=',
            ['get', 'a'],
            1
          ], props: {
            'a': 2
          }),
          true);
      expect(
          eval([
            '>',
            ['zoom'],
            5
          ], zoom: 6),
          true);
      expect(
          eval([
            '<=',
            ['zoom'],
            5
          ], zoom: 5),
          true);
      expect(eval(['<', 'apple', 'banana']), true);
    });

    test('case, match, coalesce', () {
      expect(
          eval([
            'case',
            [
              '==',
              ['get', 'class'],
              'motorway'
            ],
            'red',
            'blue',
          ], props: {
            'class': 'motorway'
          }),
          'red');
      expect(
          eval([
            'match',
            ['get', 'class'],
            ['primary', 'secondary'],
            1,
            'motorway',
            2,
            0,
          ], props: {
            'class': 'secondary'
          }),
          1);
      expect(
          eval([
            'coalesce',
            null,
            ['get', 'x'],
            'fallback'
          ]),
          'fallback');
    });

    test('all / any / !', () {
      expect(
          eval([
            'all',
            true,
            ['>', 2, 1]
          ]),
          true);
      expect(eval(['all', true, false]), false);
      expect(eval(['any', false, true]), true);
      expect(eval(['!', false]), true);
    });
  });

  group('ramps', () {
    test('step', () {
      final expr = [
        'step',
        ['zoom'],
        'a',
        10,
        'b',
        14,
        'c'
      ];
      expect(eval(expr, zoom: 5), 'a');
      expect(eval(expr, zoom: 10), 'b');
      expect(eval(expr, zoom: 13.9), 'b');
      expect(eval(expr, zoom: 14), 'c');
    });

    test('linear interpolate on numbers', () {
      final expr = [
        'interpolate',
        ['linear'],
        ['zoom'],
        10,
        0,
        20,
        100
      ];
      expect(eval(expr, zoom: 5), 0);
      expect(eval(expr, zoom: 15), 50);
      expect(eval(expr, zoom: 20), 100);
    });

    test('exponential interpolate', () {
      final expr = [
        'interpolate',
        ['exponential', 2],
        ['zoom'],
        10,
        100,
        12,
        400,
      ];
      final mid = eval(expr, zoom: 11)! as double;
      // base 2: t = (2^1 - 1) / (2^2 - 1) = 1/3
      expect(mid, closeTo(200, 0.01));
    });

    test('interpolate on colors', () {
      final expr = [
        'interpolate',
        ['linear'],
        ['zoom'],
        0,
        '#000000',
        10,
        '#ffffff',
      ];
      final color = eval(expr, zoom: 5)! as Color;
      expect((color.r * 255).round(), closeTo(128, 12));
    });
  });

  group('math and strings', () {
    test('arithmetic', () {
      expect(eval(['+', 1, 2, 3]), 6);
      expect(eval(['*', 2, 3]), 6);
      expect(eval(['-', 10, 4]), 6);
      expect(eval(['-', 4]), -4);
      expect(eval(['/', 12, 2]), 6);
      expect(eval(['%', 13, 7]), 6);
      expect(eval(['^', 2, 3]), 8);
      expect(eval(['min', 5, 2, 8]), 2);
      expect(eval(['max', 5, 2, 8]), 8);
    });

    test('string ops', () {
      expect(eval(['concat', 'a', 1, 'b']), 'a1b');
      expect(eval(['upcase', 'abc']), 'ABC');
      expect(eval(['downcase', 'ABC']), 'abc');
      expect(eval(['length', 'abcd']), 4);
    });

    test('coercions', () {
      expect(eval(['to-string', 5]), '5');
      expect(eval(['to-number', '42']), 42);
      expect(eval(['to-boolean', '']), false);
      expect(eval(['to-color', '#ff0000']), const Color(0xffff0000));
    });
  });

  group('legacy filters', () {
    test('property equality', () {
      expect(
          evalFilter(['==', 'class', 'park'], props: {'class': 'park'}), true);
      expect(evalFilter(['==', 'class', 'park'], props: {'class': 'x'}), false);
    });

    test(r'$type matching', () {
      expect(evalFilter(['==', r'$type', 'Point']), true);
      expect(
          evalFilter(['==', r'$type', 'Polygon'], geometryType: 'LineString'),
          false);
    });

    test('in / !in', () {
      expect(
          evalFilter(['in', 'class', 'a', 'b'], props: {'class': 'b'}), true);
      expect(
          evalFilter(['!in', 'class', 'a', 'b'], props: {'class': 'b'}), false);
    });

    test('has / !has and nested all', () {
      expect(evalFilter(['has', 'name'], props: {'name': 'x'}), true);
      expect(
          evalFilter([
            'all',
            ['==', r'$type', 'Point'],
            ['!has', 'hidden'],
          ], props: {
            'name': 'x'
          }),
          true);
    });

    test('numeric comparison with int/double mix', () {
      expect(evalFilter(['>=', 'rank', 3], props: {'rank': 3.0}), true);
      expect(evalFilter(['<', 'rank', 3], props: {'rank': 5}), false);
    });
  });

  group('legacy zoom functions', () {
    test('stops interpolate by zoom', () {
      final fn = {
        'base': 1,
        'stops': [
          [10, 1],
          [20, 11],
        ],
      };
      expect(eval(fn, zoom: 15), 6);
      expect(eval(fn, zoom: 9), 1);
      expect(eval(fn, zoom: 25), 11);
    });

    test('categorical property function', () {
      final fn = {
        'property': 'class',
        'type': 'categorical',
        'stops': [
          ['a', 1],
          ['b', 2],
        ],
        'default': 0,
      };
      expect(eval(fn, props: {'class': 'b'}), 2);
      expect(eval(fn, props: {'class': 'zzz'}), 0);
    });

    test('interval selects the greatest stop <= input, at exact stops too', () {
      // Regression: an input exactly on a middle stop used to return the
      // PREVIOUS band's output — visible at every integer zoom boundary.
      final fn = {
        'type': 'interval',
        'stops': [
          [0, 'a'],
          [10, 'b'],
          [20, 'c'],
        ],
      };
      expect(eval(fn, zoom: 5), 'a');
      expect(eval(fn, zoom: 10), 'b');
      expect(eval(fn, zoom: 15), 'b');
      expect(eval(fn, zoom: 20), 'c');
      expect(eval(fn, zoom: 25), 'c');
    });

    test('identity functions return the raw property value', () {
      // Regression: stop-less legacy functions — {"type": "identity"}
      // included — were silently compiled to a constant returning the
      // raw JSON map, so every typed property fell back to its default.
      final fn = {'type': 'identity', 'property': 'colour'};
      expect(eval(fn, props: {'colour': '#ff0000'}), '#ff0000');
      expect(eval(fn, props: {}), null);
      expect(
        eval({'type': 'identity', 'property': 'n', 'default': 7}, props: {}),
        7,
      );

      final parser = ExpressionParser();
      parser.parse({'type': 'identity', 'property': 'colour'});
      expect(parser.referencedProperties, contains('colour'));
    });

    test('unsupported stop-less functions degrade with a warning', () {
      final parser = ExpressionParser();
      final expr = parser.parse({'type': 'exponential', 'property': 'x'});
      expect(expr(const EvalContext(zoom: 10)), null);
      expect(parser.warnings, isNotEmpty);
    });
  });

  group('coercions', () {
    test('toStringValue survives non-finite doubles', () {
      // Regression: infinity == infinity.roundToDouble() is true, so
      // .round() threw an uncaught UnsupportedError on the main isolate
      // when a tile property carried an Infinity into a text-field.
      expect(toStringValue(double.infinity), 'Infinity');
      expect(toStringValue(double.negativeInfinity), '-Infinity');
      expect(toStringValue(double.nan), 'NaN');
      expect(toStringValue(2.0), '2');
      expect(toStringValue(2.5), '2.5');
    });
  });

  group('referenced property collection', () {
    test('collects get/has/legacy keys', () {
      final parser = ExpressionParser();
      parser.parse(['get', 'name']);
      parser.parseFilter(['==', 'class', 'park']);
      parser.parse(['has', 'ele']);
      expect(
          parser.referencedProperties, containsAll(['name', 'class', 'ele']));
      expect(parser.referencesAllProperties, false);
    });

    test('dynamic access flags all properties', () {
      final parser = ExpressionParser();
      parser.parse([
        'get',
        ['get', 'keyName']
      ]);
      // outer get has non-literal name
      expect(parser.referencesAllProperties, true);
    });
  });

  group('zoom-only detection and memoization', () {
    test('zoom ramps are detected as zoom-only', () {
      final p = ExpressionParser().parseForProperty([
        'interpolate',
        ['linear'],
        ['zoom'],
        5,
        1,
        10,
        2,
      ]);
      expect(p.zoomOnly, isTrue);
    });

    test('feature reads disable zoom-only', () {
      final parser = ExpressionParser();
      expect(parser.parseForProperty(['get', 'name']).zoomOnly, isFalse);
      expect(parser.parseForProperty(['geometry-type']).zoomOnly, isFalse);
      expect(parser.parseForProperty(['id']).zoomOnly, isFalse);
      expect(
          parser.parseForProperty([
            'match',
            ['get', 'class'],
            'a',
            1,
            2,
          ]).zoomOnly,
          isFalse);
    });

    test('detection is per property, not per parser', () {
      final parser = ExpressionParser();
      expect(parser.parseForProperty(['get', 'name']).zoomOnly, isFalse);
      expect(parser.parseForProperty(['zoom']).zoomOnly, isTrue);
      expect(parser.referencedProperties, contains('name'));
    });

    test('zoom-only props memoize per zoom and re-evaluate on change', () {
      final p = ExpressionParser().parseForProperty([
        'interpolate',
        ['linear'],
        ['zoom'],
        0,
        0,
        10,
        10,
      ]);
      final prop = DoubleProp(p.expr, 0, zoomOnly: p.zoomOnly);
      expect(prop.eval(const EvalContext(zoom: 5)), 5);
      expect(prop.eval(const EvalContext(zoom: 5)), 5); // memo hit
      expect(prop.eval(const EvalContext(zoom: 8)), 8); // invalidated
    });

    test('feature-dependent props stay per-feature', () {
      final p = ExpressionParser().parseForProperty(['get', 'width']);
      final prop = DoubleProp(p.expr, 0, zoomOnly: p.zoomOnly);
      expect(
          prop.eval(const EvalContext(zoom: 5, properties: {'width': 1})), 1);
      expect(
          prop.eval(const EvalContext(zoom: 5, properties: {'width': 2})), 2);
    });
  });

  group('set-based membership', () {
    test('legacy in matches ints against doubles', () {
      expect(
          evalFilter(['in', 'admin_level', 2, 4], props: {'admin_level': 2.0}),
          isTrue);
      expect(evalFilter(['!in', 'admin_level', 2], props: {'admin_level': 2.0}),
          isFalse);
      expect(
          evalFilter(['in', 'class', 'primary', 'secondary'],
              props: {'class': 'tertiary'}),
          isFalse);
    });

    test('expression in over a literal list keeps loose number equality', () {
      expect(
          eval([
            'in',
            2.0,
            [
              'literal',
              [1, 2, 3]
            ]
          ]),
          true);
      expect(
          eval([
            'in',
            5,
            [
              'literal',
              [1, 2, 3]
            ]
          ]),
          false);
    });
  });
}
