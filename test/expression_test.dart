import 'dart:typed_data';
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

  group('global-state', () {
    test('reads the state the parser was given, compiled in', () {
      final parser = ExpressionParser(globalState: {'mode': 'night', 'n': 3});
      final p = parser.parseForProperty([
        'case',
        [
          '==',
          ['global-state', 'mode'],
          'night'
        ],
        ['global-state', 'n'],
        0
      ]);
      expect(p.expr(EvalContext.empty), 3);
      expect(p.zoomOnly, isTrue, reason: 'global state is no feature data');
      expect(parser.readsZoom, isFalse);
      expect(parser.readsGlobalState, isTrue);
    });

    test('an unset name is null', () {
      expect(eval(['global-state', 'nothing']), isNull);
    });

    test('a computed name degrades with a warning', () {
      final parser = ExpressionParser(globalState: {'ab': 1});
      final e = parser.parse([
        'global-state',
        ['concat', 'a', 'b']
      ]);
      expect(e(EvalContext.empty), isNull);
      expect(parser.warnings, isNotEmpty);
    });
  });

  group('join, split and semiliteral', () {
    test('join and split', () {
      expect(
          eval([
            'join',
            ['get', 'names'],
            ' · '
          ], props: {
            'names': ['a', 'b']
          }),
          'a · b');
      expect(eval(['split', 'a;b;;c', ';']), ['a', 'b', '', 'c']);
      expect(eval(['join', 'not a list', ',']), isNull);
      expect(eval(['split', 5, ',']), isNull);
    });

    test('semiliteral evaluates the expressions inside its array', () {
      expect(
          eval([
            'semiliteral',
            [
              ['get', 'x'],
              2,
              'top'
            ]
          ], props: {
            'x': 1
          }),
          [1, 2.0, 'top']);
      expect(
          eval([
            'semiliteral',
            [1, 2]
          ]),
          [1, 2]);
    });

    test('semiliteral without exactly one argument warns', () {
      final parser = ExpressionParser();
      expect(parser.parse(['semiliteral'])(EvalContext.empty), isNull);
      expect(parser.warnings, isNotEmpty);
    });
  });

  group('number-format', () {
    test('locale digits, currencies and units', () {
      expect(eval(['number-format', 123456.789, <String, Object?>{}]),
          '123,456.789');
      expect(
          eval([
            'number-format',
            1234.5,
            {'locale': 'de'}
          ]),
          '1.234,5');
      expect(
          eval([
            'number-format',
            123456.789,
            {'locale': 'en-US', 'currency': 'EUR'}
          ]),
          '€123,456.79');
      expect(
          eval([
            'number-format',
            ['get', 'ele'],
            {'unit': 'meter', 'max-fraction-digits': 0}
          ], props: {
            'ele': 2962.4
          }),
          '2,962 m');
      expect(
          eval([
            'number-format',
            21.5,
            {'unit': 'celsius'}
          ]),
          '21.5°C');
    });

    test('a non-number formats to null', () {
      expect(
          eval([
            'number-format',
            ['get', 'missing'],
            <String, Object?>{}
          ]),
          isNull);
    });

    test('currency and unit together warn', () {
      final parser = ExpressionParser();
      parser.parse([
        'number-format',
        1,
        {'currency': 'EUR', 'unit': 'meter'}
      ]);
      expect(parser.warnings, isNotEmpty);
    });
  });

  group('within and distance', () {
    // z0, extent 4096: the tile centre is (0°, 0°).
    FeatureGeometry point(double x, double y) => FeatureGeometry(
          z: 0,
          x: 0,
          y: 0,
          extent: 4096,
          type: 'Point',
          parts: [
            Float32List.fromList([x, y])
          ],
        );
    const square = {
      'type': 'Polygon',
      'coordinates': [
        [
          [-10, -10],
          [10, -10],
          [10, 10],
          [-10, 10],
          [-10, -10]
        ]
      ],
    };

    Object? evalAt(Object? json, FeatureGeometry geometry) =>
        ExpressionParser().parse(json)(
            EvalContext(zoom: 0, geometryType: 'Point', geometry: geometry));

    test('within tests the feature against the polygons', () {
      expect(evalAt(['within', square], point(2048, 2048)), isTrue);
      expect(evalAt(['within', square], point(3072, 2048)), isFalse);
    });

    test('distance is in metres', () {
      final d = evalAt([
        'distance',
        {
          'type': 'Point',
          'coordinates': [0, 1]
        }
      ], point(2048, 2048)) as double;
      // One degree of latitude at the equator.
      expect(d, closeTo(110574, 1));
      expect(evalAt(['distance', square], point(2048, 2048)), 0);
    });

    test('both read the geometry, which makes them per feature', () {
      final parser = ExpressionParser();
      final p = parser.parseForProperty(['distance', square]);
      expect(p.zoomOnly, isFalse);
      expect(parser.readsGeometry, isTrue);
      expect(ExpressionParser().readsGeometry, isFalse);
    });

    test('without geometry a feature is not within and has no distance', () {
      expect(eval(['within', square]), isFalse);
      expect(eval(['distance', square]), isNull);
    });

    test('non-geometry arguments warn', () {
      final parser = ExpressionParser();
      expect(
          parser.parse([
            'within',
            {
              'type': 'Point',
              'coordinates': [0, 0]
            }
          ])(EvalContext.empty),
          isNull);
      parser.parse([
        'distance',
        ['get', 'geojson']
      ]);
      expect(parser.warnings, hasLength(2));
    });
  });

  group('MapLibre semantics the spec fixtures pinned down', () {
    test('elevation is null: no terrain is drawn', () {
      final parser = ExpressionParser();
      expect(parser.parse(['elevation'])(EvalContext.empty), isNull);
      expect(parser.warnings, isEmpty);
    });

    test('to-number converts null to 0 and fails on the unconvertible', () {
      expect(eval(['to-number', null]), 0);
      expect(eval(['to-number', 'abc']), isNull);
      expect(eval(['to-number', 'abc', '7']), 7);
    });

    test('index-of, slice and length count characters, not code units', () {
      expect(eval(['index-of', 'b', 'abcb', 2]), 3);
      expect(eval(['index-of', '市', '😀市']), 1);
      expect(eval(['length', '😀市']), 2);
      expect(eval(['slice', 'hello', -3]), 'llo');
      expect(
          eval([
            'slice',
            [
              'literal',
              [1, 2, 3, 4]
            ],
            1,
            -1
          ]),
          [2, 3]);
    });

    test('to-string writes arrays and objects as JSON', () {
      expect(
          eval([
            'to-string',
            [
              'literal',
              [1, 'a']
            ]
          ]),
          '[1,"a"]');
    });

    test('typeof names an array by its items', () {
      expect(
          eval([
            'typeof',
            [
              'literal',
              [1, 2]
            ]
          ]),
          'array<number, 2>');
    });

    test('format leaves inline images out of the text', () {
      expect(
          eval([
            'format',
            ['image', 'shield'],
            <String, Object?>{},
            'A9',
            <String, Object?>{}
          ]),
          'A9');
    });

    test('interpolate-lab and -hcl blend outside RGB', () {
      Color at(String op) => eval([
            op,
            ['linear'],
            0.5,
            0,
            '#ff0000',
            1,
            '#0000ff'
          ]) as Color;
      final rgb = at('interpolate');
      final lab = at('interpolate-lab');
      final hcl = at('interpolate-hcl');
      expect(rgb.r, closeTo(0.5, 0.01));
      expect(lab.r, greaterThan(rgb.r + 0.1), reason: 'LAB keeps it lighter');
      expect(hcl.r, greaterThan(rgb.r + 0.1));
      expect(hcl, isNot(lab));
    });

    test('cubic-bezier easing is solved exactly, not approximated', () {
      // CSS `ease` at the midpoint.
      expect(
          eval([
            'interpolate',
            ['cubic-bezier', 0.25, 0.1, 0.25, 1],
            0.5,
            0,
            0,
            1,
            1
          ]) as double,
          closeTo(0.8024033877399112, 1e-6));
    });

    test('legacy zoom-and-property functions ramp both', () {
      final f = {
        'property': 'p',
        'stops': [
          [
            {'zoom': 0, 'value': 0},
            0
          ],
          [
            {'zoom': 0, 'value': 1},
            1
          ],
          [
            {'zoom': 1, 'value': 0},
            2
          ],
          [
            {'zoom': 1, 'value': 1},
            3
          ],
        ],
      };
      expect(eval(f, zoom: 0.5, props: {'p': 0.5}), 1.5);
      expect(eval({...f, 'type': 'interval'}, zoom: 0.5, props: {'p': 0.5}), 0);
    });

    test('legacy functions hold numeric strings and the first duplicate stop',
        () {
      expect(
          eval({
            'property': 'p',
            'stops': [
              [0, '0'],
              [1, '1']
            ]
          }, props: {
            'p': 0.5
          }),
          '0');
      expect(
          eval({
            'stops': [
              [0, 10],
              [1, 20],
              [1, 25],
              [2, 30]
            ]
          }, zoom: 1),
          20);
    });
  });
}
