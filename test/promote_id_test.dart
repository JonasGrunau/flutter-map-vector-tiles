import 'dart:convert';

import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/grid/tile_store.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/executor/executor.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures/mvt_builder.dart';

List<int> _point(int x, int y) => [cmd(1, 1), zig(x), zig(y)];

/// A tile whose `poi` layer carries MVT ids 1..5 and an `osm` property
/// of every promotable — and an unpromotable — kind.
final _bytes = (MvtTileBuilder()
        .layer('poi')
        .feature(
            type: 1,
            geometry: _point(10, 10),
            id: 1,
            properties: {'osm': 1001, 'name': 'a'})
        .feature(
            type: 1,
            geometry: _point(20, 20),
            id: 2,
            properties: {'osm': 'w42', 'name': 'b'})
        .feature(
            type: 1,
            geometry: _point(30, 30),
            id: 3,
            properties: {'osm': true, 'name': 'c'})
        .feature(type: 1, geometry: _point(40, 40), id: 4, properties: {
          'name': 'd',
        })
        .done()
        .layer('road')
        .feature(
            type: 2,
            geometry: [cmd(1, 1), zig(0), zig(0), cmd(2, 1), zig(10), zig(0)],
            id: 9,
            properties: {'osm': 77})
        .done())
    .build();

void main() {
  test('PromoteId parses both shapes the style spec allows', () {
    expect(PromoteId.parse('osm'), const PromoteId('osm'));
    expect(PromoteId.parse({'poi': 'osm', 'bad': 3}),
        const PromoteId.bySourceLayer({'poi': 'osm'}));
    expect(PromoteId.parse(''), isNull);
    expect(PromoteId.parse(3), isNull);
    expect(PromoteId.parse({'poi': 3}), isNull);
    const both = PromoteId.bySourceLayer({'poi': 'osm'});
    expect(both.propertyFor('poi'), 'osm');
    expect(both.propertyFor('road'), isNull);
    expect(const PromoteId('id').propertyFor('anything'), 'id');
  });

  test('decoding promotes the property to the feature id', () {
    final tile = prepareTileSync(PrepareInput(
      z: 0,
      x: 0,
      y: 0,
      bytes: _bytes,
      layerProperties: const {
        'poi': {'osm'},
        'road': {'osm'},
      },
      promoteIds: const {'poi': 'osm'},
    ));
    expect([for (final f in tile.layers['poi']!.features) f.id],
        [1001, 'w42', 1, null]);
    // The property stays a property, as in MapLibre.
    expect(tile.layers['poi']!.features.first.properties, {'osm': 1001});
    // A source layer without a promoted property keeps its own ids.
    expect(tile.layers['road']!.features.single.id, 9);
  });

  test('stores promoting different properties keep apart', () async {
    final provider = MemoryVectorTileProvider(
        tiles: {const TileKey(0, 0, 0): _bytes}, cacheKey: 'promote-test');
    final executor = TilePrepareExecutor(concurrency: 1);
    addTearDown(executor.dispose);
    TileStore store(Map<String, String> promoteIds) => TileStore(
          provider: provider,
          executor: executor,
          layerProperties: const {
            'poi': {'osm'}
          },
          promoteIds: promoteIds,
        );
    final plain = store(const {});
    final promoted = store(const {'poi': 'osm'});
    final a = await plain.obtain(const TileKey(0, 0, 0));
    final b = await promoted.obtain(const TileKey(0, 0, 0));
    expect(a!.layers['poi']!.features.first.id, 1);
    expect(b!.layers['poi']!.features.first.id, 1001);
    plain.dispose();
    promoted.dispose();
  });

  test('StyleReader reads promoteId from the source', () async {
    const styleUrl = 'https://example.com/style.json';
    final client = MockClient((request) async {
      if (request.url.toString() != styleUrl) {
        return http.Response('not found', 404);
      }
      return http.Response(
          jsonEncode({
            'version': 8,
            'sources': {
              'a': {
                'type': 'vector',
                'tiles': ['https://example.com/a/{z}/{x}/{y}.pbf'],
                'promoteId': 'osm_id',
              },
              'b': {
                'type': 'vector',
                'tiles': ['https://example.com/b/{z}/{x}/{y}.pbf'],
                'promoteId': {'building': 'ref'},
              },
              'c': {
                'type': 'vector',
                'tiles': ['https://example.com/c/{z}/{x}/{y}.pbf'],
              },
            },
            'layers': [
              {
                'id': 'bg',
                'type': 'background',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'});
    });
    final style =
        await StyleReader(uri: styleUrl, httpClient: client, cache: false)
            .read();
    addTearDown(style.dispose);
    expect(style.providers.promoteIds, {
      'a': const PromoteId('osm_id'),
      'b': const PromoteId.bySourceLayer({'building': 'ref'}),
    });
  });
}
