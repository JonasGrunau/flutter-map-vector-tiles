import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/pipeline/executor/direct_executor.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_filters.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_map_vector_tiles/src/render/matched_features.dart';
import 'package:flutter_map_vector_tiles/src/style/expression.dart';
import 'package:flutter_map_vector_tiles/src/style/filter_ids.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/liberty_layers.dart';
import 'fixtures/mvt_builder.dart';

/// Filters of every shape the parser compiles — legacy and expression
/// syntax, type-mismatched comparisons, `let`, string and type
/// operators — over one source layer whose features carry every
/// property type MVT can.
const _syntheticFilters = <Object?>[
  null,
  ['==', 'class', 'a'],
  ['!=', 'class', 'a'],
  ['<', 'rank', 5],
  ['<=', 'rank', 5],
  ['>', 'rank', 0],
  ['>=', 'rank', 2.5],
  ['==', 'rank', '5'],
  ['in', 'class', 'a', 'b'],
  ['!in', 'class', 'a', 'b'],
  ['has', 'name'],
  ['!has', 'name'],
  [
    'all',
    ['==', r'$type', 'Point'],
    ['has', 'rank']
  ],
  [
    'any',
    ['==', 'class', 'park'],
    ['==', 'flag', true]
  ],
  [
    'none',
    ['==', 'class', 'a'],
    ['<', 'rank', 1]
  ],
  ['==', r'$type', 'Polygon'],
  ['in', r'$type', 'LineString', 'Polygon'],
  ['==', r'$id', 3],
  ['all'],
  ['any'],
  [
    '==',
    ['get', 'class'],
    'a'
  ],
  [
    '!=',
    ['get', 'rank'],
    5
  ],
  [
    '<',
    ['get', 'rank'],
    3
  ],
  [
    '>',
    [
      'to-number',
      ['get', 'rank']
    ],
    1
  ],
  [
    'match',
    ['get', 'class'],
    ['a', 'b'],
    true,
    'park',
    ['has', 'name'],
    false
  ],
  [
    'case',
    ['has', 'rank'],
    [
      '>=',
      ['get', 'rank'],
      1
    ],
    [
      '==',
      ['get', 'flag'],
      true
    ]
  ],
  [
    'in',
    ['get', 'class'],
    [
      'literal',
      ['a', 'c']
    ]
  ],
  [
    '!',
    [
      'in',
      ['get', 'subclass'],
      [
        'literal',
        ['x', 'y']
      ]
    ]
  ],
  [
    '==',
    ['geometry-type'],
    'LineString'
  ],
  [
    '<',
    ['id'],
    10
  ],
  [
    'coalesce',
    ['get', 'flag'],
    false
  ],
  [
    '==',
    [
      'downcase',
      ['get', 'name']
    ],
    'a'
  ],
  [
    'let',
    'r',
    ['get', 'rank'],
    [
      'all',
      [
        '>',
        ['var', 'r'],
        0
      ],
      [
        '<',
        ['var', 'r'],
        6
      ]
    ]
  ],
  [
    'any',
    [
      '==',
      ['get', 'class'],
      'a'
    ],
    [
      'all',
      ['has', 'level'],
      [
        '>=',
        [
          'to-number',
          ['get', 'level'],
          0
        ],
        1
      ]
    ]
  ],
  [
    '==',
    [
      'concat',
      ['get', 'class'],
      '-',
      ['get', 'subclass']
    ],
    'a-x'
  ],
  ['get', 'flag'],
  [
    'boolean',
    ['get', 'flag'],
    false
  ],
  [
    'to-boolean',
    ['get', 'name']
  ],
  [
    '==',
    [
      'typeof',
      ['get', 'rank']
    ],
    'number'
  ],
  [
    '==',
    [
      'length',
      [
        'to-string',
        ['get', 'name']
      ]
    ],
    1
  ],
];

const _values = <Object>[
  'a',
  'b',
  'c',
  'park',
  'x',
  '5',
  '',
  0,
  1,
  5,
  -3,
  2.5,
  -0.5,
  true,
  false
];

/// [count] features per source layer of [pools] with random geometry
/// types and ids, each carrying most of its source layer's keys with a
/// value drawn from that key's pool; encoded as one MVT.
Uint8List _randomTile(
  Map<String, Map<String, List<Object>>> pools, {
  int count = 300,
  int seed = 7,
}) {
  final random = Random(seed);
  final tile = MvtTileBuilder();
  pools.forEach((sourceLayer, valuesByKey) {
    final layer = tile.layer(sourceLayer);
    for (var i = 0; i < count; i++) {
      final type = 1 + random.nextInt(3);
      layer.feature(
        type: type,
        id: random.nextInt(4) == 0 ? null : random.nextInt(20),
        properties: {
          for (final MapEntry(:key, value: values) in valuesByKey.entries)
            if (random.nextInt(5) > 0)
              key: values[random.nextInt(values.length)],
        },
        geometry: switch (type) {
          1 => [cmd(1, 1), zig(100), zig(100)],
          2 => [cmd(1, 1), zig(0), zig(0), cmd(2, 1), zig(400), zig(400)],
          _ => [
              cmd(1, 1), zig(0), zig(0), //
              cmd(2, 2), zig(400), zig(0), zig(0), zig(400), cmd(7, 1),
            ],
        },
      );
    }
    layer.done();
  });
  return tile.build();
}

/// One `poi` source layer whose [keys] take any of [_values].
Uint8List _poiTile(Set<String> keys) => _randomTile({
      'poi': {for (final key in keys) key: _values}
    });

/// Per source layer, the union of the properties the theme reads — what
/// the layer hands its stores.
Map<String, Set<String>?> _layerProperties(Theme theme) {
  final result = <String, Set<String>?>{};
  for (final layer in theme.layers) {
    final sourceLayer = layer.sourceLayer;
    if (sourceLayer == null) continue;
    final incoming = layer.referencedProperties;
    if (!result.containsKey(sourceLayer)) {
      result[sourceLayer] = incoming?.toSet();
    } else {
      final existing = result[sourceLayer];
      result[sourceLayer] = existing == null || incoming == null
          ? null
          : {...existing, ...incoming};
    }
  }
  return result;
}

/// Prepares [bytes] the way a native worker does: every filter of
/// [theme] compiled from its JSON source, resolved at a zoom whose band
/// covers every layer.
PreparedTile _prepareOnWorker(Theme theme, Uint8List bytes) {
  final plan = TileFilterPlan(theme.layers, minimumZoom: 0, maximumZoom: 0);
  final filters = CompiledFilters()
    ..addAll({
      for (final layer in theme.layers)
        if (layer.filterId case final id?) id: FilterIds.sourceOf(id),
    });
  return prepareTileSync(
    PrepareInput(
      z: 0,
      x: 0,
      y: 0,
      bytes: bytes,
      layerProperties: _layerProperties(theme),
      filterIds: plan.idsAt(0),
    ),
    filters: filters,
  );
}

/// What a full scan on the UI isolate selects.
List<PreparedFeature> _scan(ThemeLayer layer, PreparedSourceLayer source) => [
      for (final feature in source.features)
        if (layer.matches(EvalContext(
          zoom: 0,
          properties: feature.properties,
          geometryType: feature.geometryType,
          featureId: feature.id,
        )))
          feature,
    ];

/// Asserts that every zoom-free layer of [theme] reads the worker's
/// matches for [tile], and that they equal a UI-side scan.
void _expectWorkerMatchesUi(Theme theme, PreparedTile tile) {
  var resolved = 0;
  for (final layer in theme.layers) {
    final source = tile.layers[layer.sourceLayer];
    if (source == null || layer.filterReadsZoom) continue;
    final id = layer.filterId;
    expect(id, isNotNull, reason: layer.id);
    expect(source.matches.containsKey(id), isTrue,
        reason: '${layer.id} was resolved on the worker');
    expect(
        MatchedFeatures.of(layer, source, tile: tile.key), _scan(layer, source),
        reason: layer.id);
    resolved++;
  }
  expect(resolved, greaterThan(0));
}

Theme _themeOf(List<Object?> filters, {String sourceLayer = 'poi'}) =>
    const ThemeReader().read({
      'layers': [
        for (var i = 0; i < filters.length; i++)
          {
            'id': 'l$i',
            'type': 'line',
            'source': 's',
            'source-layer': sourceLayer,
            if (filters[i] != null) 'filter': filters[i],
          },
      ],
    });

void main() {
  group('worker-resolved matches equal UI-resolved ones', () {
    test('on a filter-heavy synthetic style', () {
      final theme = _themeOf(_syntheticFilters);
      final tile = _prepareOnWorker(theme,
          _poiTile({'class', 'subclass', 'rank', 'name', 'flag', 'level'}));
      _expectWorkerMatchesUi(theme, tile);
    });

    test('on Liberty', () {
      final layers = (jsonDecode(libertyLayersJson) as List).cast<Object?>();
      final theme = const ThemeReader().read({'layers': layers});
      expect(theme.layers, hasLength(layers.length));
      // Per source layer and key, every literal its filters compare
      // the key with, so each filter has features on both sides of it.
      final pools = <String, Map<String, Set<Object>>>{};
      void collect(Object? json, Map<String, Set<Object>> into) {
        if (json is! List || json.isEmpty) return;
        final keys = {
          // Legacy syntax names the key second, expressions `get` it.
          if (json.length > 1 && json[1] is String && json[0] != 'get')
            json[1] as String,
          for (final e in json)
            if (e is List && e.length == 2 && e[0] == 'get' && e[1] is String)
              e[1] as String,
        };
        final literals = <Object>{};
        void scalars(Object? e) {
          if (e is List) e.forEach(scalars);
          if (e is String || e is num || e is bool) literals.add(e!);
        }

        scalars(json);
        for (final key in keys) {
          (into[key] ??= {'other', 0, 1, 3, 0.5, true}).addAll(literals);
        }
        for (final e in json) {
          collect(e, into);
        }
      }

      for (final layer in layers.cast<Map<String, Object?>>()) {
        collect(
            layer['filter'], pools[layer['source-layer']! as String] ??= {});
      }
      for (final layer in theme.layers) {
        final keys = pools[layer.sourceLayer!]!;
        for (final key in layer.referencedProperties ?? const <String>{}) {
          keys[key] ??= {..._values};
        }
      }
      final tile = _prepareOnWorker(
        theme,
        _randomTile(count: 600, {
          for (final MapEntry(key: sourceLayer, value: keys) in pools.entries)
            sourceLayer: {
              for (final MapEntry(:key, :value) in keys.entries)
                key: value.toList(),
            },
        }),
      );
      _expectWorkerMatchesUi(theme, tile);
    });
  });

  test('equal filters share an id, across themes too; different ones never',
      () {
    final a = _themeOf([
      ['==', 'class', 'a'],
      ['==', 'class', 'b'],
      ['==', 'class', 'a'],
    ]).layers;
    final b = _themeOf([
      ['==', 'class', 'a'],
    ]).layers;
    expect(a[0].filterId, a[2].filterId);
    expect(a[0].filterId, b[0].filterId);
    expect(a[0].filterId, isNot(a[1].filterId));
    expect(FilterIds.intern(double.nan), isNull,
        reason: 'not JSON: left to the UI isolate');
  });

  test('only zoom-free filters of source layers get an id', () {
    final theme = const ThemeReader().read({
      'layers': [
        {'id': 'bg', 'type': 'background'},
        {'id': 'free', 'type': 'fill', 'source': 's', 'source-layer': 'x'},
        {
          'id': 'zoomed',
          'type': 'fill',
          'source': 's',
          'source-layer': 'x',
          'filter': [
            '<',
            ['zoom'],
            10
          ],
        },
        {'id': 'raster', 'type': 'raster', 'source': 'r'},
      ],
    });
    expect([for (final layer in theme.layers) layer.filterId != null],
        [false, true, false, false]);
  });

  test('a zoom-reading filter is never resolved on the worker', () {
    final theme = _themeOf([
      [
        'all',
        ['==', 'class', 'a'],
        [
          '>=',
          ['zoom'],
          12
        ]
      ],
      ['==', 'class', 'a'],
    ]);
    final tile = _prepareOnWorker(theme, _poiTile({'class'}));
    final source = tile.layers['poi']!;
    expect(source.matches.keys, [theme.layers[1].filterId]);
    expect(MatchedFeatures.of(theme.layers[0], source, tile: tile.key), isNull,
        reason: 'still evaluated per display tile');
  });

  test('a global-state filter stays on the UI isolate and follows the state',
      () {
    // The state is compiled into the filter, so one JSON is a different
    // filter under every state: it gets no id and no worker list.
    final a = const ThemeReader().read({
      'state': {
        'cls': {'default': 'a'},
      },
      'layers': [
        for (final (id, filter) in [
          (
            'by-state',
            [
              '==',
              ['get', 'class'],
              ['global-state', 'cls']
            ]
          ),
          ('fixed', ['==', 'class', 'a']),
        ])
          {
            'id': id,
            'type': 'line',
            'source': 's',
            'source-layer': 'poi',
            'filter': filter,
          },
      ],
    });
    final b = a.withGlobalState({'cls': 'b'});
    expect(b, isNot(same(a)));
    expect([a.layers[0].filterId, b.layers[0].filterId], [isNull, isNull]);
    expect(a.layers[1].filterId, isNotNull);

    // Prepared under state a, then drawn under a and under b.
    final tile = _prepareOnWorker(a, _poiTile({'class'}));
    final source = tile.layers['poi']!;
    expect(source.matches.keys, [a.layers[1].filterId]);
    for (final (theme, cls) in [(a, 'a'), (b, 'b')]) {
      final layer = theme.layers[0];
      final matched = MatchedFeatures.of(layer, source, tile: tile.key)!;
      expect(matched, isNotEmpty, reason: cls);
      expect(matched.every((f) => f.properties['class'] == cls), isTrue,
          reason: cls);
      expect(matched, _scan(layer, source), reason: cls);
    }
  });

  test('a filter reading the feature geometry stays on the UI isolate', () {
    final theme = _themeOf([
      [
        'within',
        {
          'type': 'Polygon',
          'coordinates': [
            [
              [0, 0],
              [1, 0],
              [1, 1],
              [0, 0]
            ]
          ],
        }
      ],
    ]);
    expect(theme.layers.single.readsGeometry, isTrue);
    expect(theme.layers.single.filterId, isNull);
  });

  test('a tile prepared for another filter falls back to the UI isolate', () {
    final before = _themeOf([
      ['==', 'class', 'a'],
    ]);
    final tile = _prepareOnWorker(before, _poiTile({'class'}));
    // The style changed under the in-flight tile: same layer id, another
    // filter. Its id differs, so the stale matches are never read.
    final after = _themeOf([
      ['==', 'class', 'b'],
    ]);
    final layer = after.layers.single;
    final source = tile.layers['poi']!;
    expect(source.matches.containsKey(layer.filterId), isFalse);
    final matched = MatchedFeatures.of(layer, source, tile: tile.key)!;
    expect(matched, _scan(layer, source));
    expect(matched.every((f) => f.properties['class'] == 'b'), isTrue);
  });

  test('the match lists are counted in byteSize', () {
    final theme = _themeOf(_syntheticFilters);
    final bytes =
        _poiTile({'class', 'subclass', 'rank', 'name', 'flag', 'level'});
    final plain = prepareTileSync(PrepareInput(
        z: 0,
        x: 0,
        y: 0,
        bytes: bytes,
        layerProperties: _layerProperties(theme)));
    final resolved = _prepareOnWorker(theme, bytes);
    final lists = resolved.layers['poi']!.matches.values;
    expect(resolved.byteSize - plain.byteSize,
        lists.fold<int>(0, (sum, l) => sum + 16 + (l?.lengthInBytes ?? 0)));
  });

  test('the web executor resolves no filter: the UI isolate does', () async {
    final theme = _themeOf([
      ['==', 'class', 'a'],
    ]);
    final executor = PlatformExecutor();
    addTearDown(executor.dispose);
    final tile = await executor.prepare(PrepareInput(
      z: 0,
      x: 0,
      y: 0,
      bytes: _poiTile({'class'}),
      layerProperties: _layerProperties(theme),
      filterIds:
          TileFilterPlan(theme.layers, minimumZoom: 0, maximumZoom: 0).idsAt(0),
    ));
    final source = tile!.layers['poi']!;
    expect(source.matches, isEmpty);
    final layer = theme.layers.single;
    expect(MatchedFeatures.of(layer, source, tile: tile.key),
        _scan(layer, source));
  });

  group('TileFilterPlan resolves the layers of a tile\'s own zoom band', () {
    final theme = const ThemeReader().read({
      'layers': [
        for (final (id, min, max) in [
          ('all', null, null),
          ('low', null, 8),
          ('mid', 10, 13),
          ('high', 14, null),
        ])
          {
            'id': id,
            'type': 'fill',
            'source': 's',
            'source-layer': 'x',
            if (min != null) 'minzoom': min,
            if (max != null) 'maxzoom': max,
            'filter': ['==', 'class', id],
          },
        {
          'id': 'shared-low',
          'type': 'line',
          'source': 's',
          'source-layer': 'x',
          'maxzoom': 6,
          'filter': ['==', 'class', 'high'],
        },
      ],
    });
    final idOf = {for (final l in theme.layers) l.id: l.filterId};
    final plan = TileFilterPlan(theme.layers, minimumZoom: 2, maximumZoom: 14);
    Set<String> resolvedAt(int z) => {
          for (final MapEntry(:key, :value) in idOf.entries)
            if (plan.idsAt(z)?['x']?.contains(value) ?? false) key,
        };

    test('between the source\'s zoom bounds: that zoom only', () {
      expect(resolvedAt(7), {'all', 'low'});
      expect(resolvedAt(8), {'all'}, reason: 'maxzoom is exclusive');
      expect(resolvedAt(10), {'all', 'mid'});
      expect(resolvedAt(12), {'all', 'mid'});
      expect(resolvedAt(5), {'all', 'low', 'shared-low', 'high'},
          reason: 'one layer in the band resolves a filter it shares');
    });

    test('the deepest level serves every zoom past it', () {
      expect(resolvedAt(14), {'all', 'high', 'shared-low'});
    });

    test('the shallowest level serves every zoom before it', () {
      expect(resolvedAt(2), {'all', 'low', 'shared-low', 'high'});
    });

    test('no filter to resolve: no list at all', () {
      final empty = TileFilterPlan(const [], minimumZoom: 0, maximumZoom: 14);
      expect(empty.idsAt(5), isNull);
    });
  });
}
