import 'package:flutter_map_vector_tiles/src/mvt/mvt_decoder.dart';
import 'package:flutter_map_vector_tiles/src/mvt/mvt_tile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mvt_builder.dart';

void main() {
  test('decodes a layer with a point feature and properties', () {
    final bytes = MvtTileBuilder()
        .layer('poi')
        .feature(
          type: 1,
          id: 42,
          geometry: [cmd(1, 1), zig(100), zig(200)],
          properties: {'name': 'Berlin', 'rank': 3, 'capital': true},
        )
        .done()
        .build();

    final tile = decodeMvt(bytes);
    expect(tile.layers, hasLength(1));
    final layer = tile.layers.single;
    expect(layer.name, 'poi');
    expect(layer.extent, 4096);

    final feature = layer.features.single;
    expect(feature.id, 42);
    expect(feature.type, MvtGeomType.point);
    expect(feature.parts.single, [100.0, 200.0]);
    expect(feature.decodeProperties(layer),
        {'name': 'Berlin', 'rank': 3, 'capital': true});
  });

  test('decodes multipoint geometry', () {
    final bytes = MvtTileBuilder()
        .layer('poi')
        .feature(type: 1, geometry: [
          cmd(1, 2),
          zig(10),
          zig(10),
          zig(5),
          zig(-5),
        ])
        .done()
        .build();

    final feature = decodeMvt(bytes).layers.single.features.single;
    expect(feature.parts.single, [10.0, 10.0, 15.0, 5.0]);
  });

  test('decodes linestring with cumulative coordinates', () {
    final bytes = MvtTileBuilder()
        .layer('roads')
        .feature(type: 2, geometry: [
          cmd(1, 1), zig(2), zig(2), //
          cmd(2, 2), zig(10), zig(0), zig(0), zig(10),
        ])
        .done()
        .build();

    final feature = decodeMvt(bytes).layers.single.features.single;
    expect(feature.type, MvtGeomType.lineString);
    expect(feature.parts.single, [2.0, 2.0, 12.0, 2.0, 12.0, 12.0]);
  });

  test('decodes polygon rings with winding classification', () {
    // Exterior ring (CW in y-down space): positive area.
    final bytes = MvtTileBuilder()
        .layer('water')
        .feature(type: 3, geometry: [
          cmd(1, 1), zig(0), zig(0), //
          cmd(2, 3), zig(10), zig(0), zig(0), zig(10), zig(-10), zig(0),
          cmd(7, 1),
        ])
        .done()
        .build();

    final feature = decodeMvt(bytes).layers.single.features.single;
    expect(feature.type, MvtGeomType.polygon);
    expect(feature.parts.single,
        [0.0, 0.0, 10.0, 0.0, 10.0, 10.0, 0.0, 10.0]);
    expect(feature.ringAreas.single, greaterThan(0));
  });

  test('decodes multiple layers and double values', () {
    final bytes = MvtTileBuilder()
        .layer('a')
        .feature(
            type: 1,
            geometry: [cmd(1, 1), zig(1), zig(1)],
            properties: {'height': 12.5})
        .done()
        .layer('b', extent: 512)
        .feature(type: 1, geometry: [cmd(1, 1), zig(2), zig(2)])
        .done()
        .build();

    final tile = decodeMvt(bytes);
    expect(tile.layers.map((l) => l.name), ['a', 'b']);
    expect(tile.layer('b')!.extent, 512);
    final props = tile.layers.first.features.single
        .decodeProperties(tile.layers.first);
    expect(props['height'], 12.5);
  });

  test('tolerates malformed feature geometry without throwing', () {
    final bytes = MvtTileBuilder()
        .layer('bad')
        .feature(type: 2, geometry: [cmd(2, 1), zig(5), zig(5)]) // LineTo first
        .feature(type: 1, geometry: [cmd(1, 1), zig(7), zig(7)])
        .done()
        .build();

    final layer = decodeMvt(bytes).layers.single;
    // Malformed feature dropped, valid one kept.
    expect(layer.features, hasLength(1));
    expect(layer.features.single.parts.single, [7.0, 7.0]);
  });
}
