import 'package:flutter_map_vector_tiles/src/pipeline/extrusion_mesh.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/mvt_builder.dart';

/// MVT geometry for a polygon of [rings], each a list of `[x, y]`.
List<int> _polygon(List<List<List<int>>> rings) {
  final out = <int>[];
  var cx = 0, cy = 0;
  for (final ring in rings) {
    out
      ..add(cmd(1, 1))
      ..add(zig(ring[0][0] - cx))
      ..add(zig(ring[0][1] - cy));
    cx = ring[0][0];
    cy = ring[0][1];
    out.add(cmd(2, ring.length - 1));
    for (final p in ring.skip(1)) {
      out
        ..add(zig(p[0] - cx))
        ..add(zig(p[1] - cy));
      cx = p[0];
      cy = p[1];
    }
    out.add(cmd(7, 1));
  }
  return out;
}

/// A clockwise (in y-down tile coordinates) square: an MVT exterior.
List<List<int>> _square(int x0, int y0, int x1, int y1) => [
      [x0, y0],
      [x1, y0],
      [x1, y1],
      [x0, y1]
    ];

/// The same square counter-clockwise: an MVT hole.
List<List<int>> _hole(int x0, int y0, int x1, int y1) => [
      [x0, y0],
      [x0, y1],
      [x1, y1],
      [x1, y0]
    ];

ExtrusionMesh _mesh(List<List<List<List<int>>>> features,
    {Set<String> extrusionLayers = const {'building'}}) {
  final layer = MvtTileBuilder().layer('building');
  for (final rings in features) {
    layer.feature(type: 3, geometry: _polygon(rings), properties: {'h': 10});
  }
  final prepared = prepareTileSync(PrepareInput(
    z: 14,
    x: 0,
    y: 0,
    bytes: layer.done().build(),
    layerProperties: const {'building': null},
    extrusionLayers: extrusionLayers,
  ));
  return prepared.layers['building']!.mesh!;
}

/// Wall w's outward normal `(dy, -dx)` and its midpoint.
({double nx, double ny, double mx, double my}) _wall(
    ExtrusionMesh mesh, int polygon, int w) {
  final v0 = mesh.vertexStart[polygon];
  final a = (v0 + mesh.walls[w]) * 2, b = (v0 + mesh.walls[w + 1]) * 2;
  final ax = mesh.xy[a], ay = mesh.xy[a + 1];
  final bx = mesh.xy[b], by = mesh.xy[b + 1];
  return (
    nx: by - ay,
    ny: -(bx - ax),
    mx: (ax + bx) / 2,
    my: (ay + by) / 2,
  );
}

void main() {
  test('a building is cut into a roof and four outward walls', () {
    final mesh = _mesh([
      [_square(1000, 1000, 2000, 2000)],
    ]);
    expect(mesh.length, 1);
    expect(mesh.feature, [0]);
    expect(mesh.vertexStart, [0, 4]);
    expect(mesh.roofStart, [0, 6]);
    expect(mesh.wallStart, [0, 8]);
    expect(mesh.bounds, [1000, 1000, 2000, 2000]);
    for (var w = 0; w < 8; w += 2) {
      final wall = _wall(mesh, 0, w);
      // Away from the centre of the building.
      expect(wall.nx * (wall.mx - 1500) + wall.ny * (wall.my - 1500),
          greaterThan(0));
    }
  });

  test('a hole stands up walls facing into it', () {
    final mesh = _mesh([
      [_square(0, 0, 3000, 3000), _hole(1000, 1000, 2000, 2000)],
    ]);
    expect(mesh.length, 1);
    expect(mesh.vertexStart, [0, 8]);
    expect(mesh.wallStart, [0, 16]);
    // Roof triangles cover the ring minus the hole: 9e6 - 1e6.
    var area = 0.0;
    for (var r = 0; r < mesh.roof.length; r += 3) {
      final a = mesh.roof[r] * 2, b = mesh.roof[r + 1] * 2;
      final c = mesh.roof[r + 2] * 2;
      final xy = mesh.xy;
      area += ((xy[b] - xy[a]) * (xy[c + 1] - xy[a + 1]) -
                  (xy[c] - xy[a]) * (xy[b + 1] - xy[a + 1]))
              .abs() /
          2;
    }
    expect(area, closeTo(8e6, 1));
    for (var w = 8; w < 16; w += 2) {
      final wall = _wall(mesh, 0, w);
      expect(
          wall.nx * (wall.mx - 1500) + wall.ny * (wall.my - 1500), lessThan(0));
    }
  });

  test("edges on the tile's clip boundary stand up no wall", () {
    // Cut by the producer at the buffer edge, x = -64: that edge is no
    // wall. An edge exactly on the tile edge, y = 0, still is one.
    final mesh = _mesh([
      [_square(-64, 0, 1000, 1000)],
      [_square(4000, 500, 4160, 1500)],
    ]);
    expect(mesh.length, 2);
    expect(mesh.wallStart, [0, 6, 12]);
    for (var w = 0; w < 6; w += 2) {
      expect(_wall(mesh, 0, w).mx, isNot(-64));
    }
    for (var w = 6; w < 12; w += 2) {
      expect(_wall(mesh, 1, w).mx, isNot(4160));
    }
  });

  test('a multipolygon is one mesh polygon per exterior ring', () {
    final mesh = _mesh([
      [_square(0, 0, 100, 100), _square(200, 0, 300, 100)],
      [_square(500, 500, 600, 700)],
    ]);
    expect(mesh.length, 3);
    expect(mesh.feature, [0, 0, 1]);
    expect(mesh.bounds, [0, 0, 100, 100, 200, 0, 300, 100, 500, 500, 600, 700]);
    expect(mesh.vertexStart, [0, 4, 8, 12]);
  });

  test('only the source layers an extrusion reads get a mesh', () {
    final tile = MvtTileBuilder()
        .layer('building')
        .feature(type: 3, geometry: _polygon([_square(0, 0, 100, 100)]))
        .done()
        .layer('water')
        .feature(type: 3, geometry: _polygon([_square(0, 0, 100, 100)]))
        .done()
        .build();
    final plain = prepareTileSync(PrepareInput(
      z: 14,
      x: 0,
      y: 0,
      bytes: tile,
      layerProperties: const {'building': null, 'water': null},
    ));
    final meshed = prepareTileSync(PrepareInput(
      z: 14,
      x: 0,
      y: 0,
      bytes: tile,
      layerProperties: const {'building': null, 'water': null},
      extrusionLayers: const {'building'},
    ));
    expect(plain.layers['building']!.mesh, isNull);
    expect(meshed.layers['building']!.mesh, isNotNull);
    expect(meshed.layers['water']!.mesh, isNull);
    expect(meshed.byteSize - plain.byteSize,
        meshed.layers['building']!.mesh!.byteSize);
  });

  /// Per polygon, the walls that have another polygon in front of
  /// them, as (polygon, covering polygons, wall midpoint x).
  List<(int, List<int>, double)> covered(ExtrusionMesh mesh) => [
        for (var p = 0; p < mesh.length; p++)
          for (var w = mesh.wallStart[p]; w < mesh.wallStart[p + 1]; w += 2)
            if (mesh.wallCoverStart[(w >> 1) + 1] > mesh.wallCoverStart[w >> 1])
              (
                p,
                mesh.wallCovers
                    .sublist(mesh.wallCoverStart[w >> 1],
                        mesh.wallCoverStart[(w >> 1) + 1])
                    .toList(),
                _wall(mesh, p, w).mx,
              ),
      ];

  test('terraced houses know the neighbour behind a shared wall', () {
    // Two houses side by side: the first's east wall runs the second's
    // west wall the other way. A third stands apart.
    final mesh = _mesh([
      [_square(0, 0, 100, 100)],
      [_square(100, 0, 200, 100)],
      [_square(500, 0, 600, 100)],
    ]);
    expect(covered(mesh).map((f) => '${f.$1} <- ${f.$2} at x = ${f.$3}'),
        unorderedEquals(['0 <- [1] at x = 100.0', '1 <- [0] at x = 100.0']));
  });

  test('a part rising out of its outline stands inside it', () {
    // The outline, and a part in its middle: every wall of the part has
    // the outline in front of it, no wall of the outline has the part.
    final mesh = _mesh([
      [_square(0, 0, 1000, 1000)],
      [_square(300, 300, 700, 700)],
    ]);
    final found = covered(mesh);
    expect(found.length, 4);
    for (final (polygon, covers, _) in found) {
      expect(polygon, 1);
      expect(covers, [0]);
    }
  });

  test('a part flush with its outline covers only its inner walls', () {
    // The part shares the outline's west edge: that wall faces the
    // street, the other three stand in the outline.
    final mesh = _mesh([
      [_square(0, 0, 1000, 1000)],
      [_square(0, 300, 400, 700)],
    ]);
    final found = covered(mesh);
    expect(found.map((f) => f.$1), everyElement(1));
    expect(found.length, 3);
    expect(found.map((f) => f.$3), isNot(contains(0)));
  });

  test('lines and points build no mesh', () {
    final tile = MvtTileBuilder()
        .layer('building')
        .feature(type: 1, geometry: [cmd(1, 1), zig(10), zig(10)])
        .feature(
            type: 2,
            geometry: [cmd(1, 1), zig(0), zig(0), cmd(2, 1), zig(50), zig(0)])
        .done()
        .build();
    final prepared = prepareTileSync(PrepareInput(
      z: 14,
      x: 0,
      y: 0,
      bytes: tile,
      layerProperties: const {'building': null},
      extrusionLayers: const {'building'},
    ));
    expect(prepared.layers['building']!.mesh, isNull);
  });
}
