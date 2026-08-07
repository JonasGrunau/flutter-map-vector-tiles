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
}
