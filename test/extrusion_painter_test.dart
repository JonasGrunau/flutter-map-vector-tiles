@TestOn('vm')
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/grid/grid_layout.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/tile_processor.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/extrusion_layouter.dart';
import 'package:flutter_map_vector_tiles/src/render/extrusion_painter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
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

const _tile = TileKey(16, 32768, 32768);

/// The tile east of [_tile].
const _east = TileKey(16, 32769, 32768);

/// The tile south of [_tile].
const _south = TileKey(16, 32768, 32769);

/// Lays [features] — `(rings, height)` in tile-extent units, MVT winding
/// — out as one `fill-extrusion` layer over [tile].
List<ExtrusionTile> _layout(List<(List<List<List<int>>>, num)> features,
    {String color = '#e0d8cc', TileKey tile = _tile}) {
  final layer = MvtTileBuilder().layer('building');
  for (final (rings, height) in features) {
    layer
        .feature(type: 3, geometry: _polygon(rings), properties: {'h': height});
  }
  final prepared = prepareTileSync(PrepareInput(
    z: tile.z,
    x: tile.x,
    y: tile.y,
    bytes: layer.done().build(),
    layerProperties: const {'building': null},
    extrusionLayers: const {'building'},
  ));
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'b',
        'type': 'fill-extrusion',
        'source': 's',
        'source-layer': 'building',
        'paint': {
          'fill-extrusion-color': color,
          'fill-extrusion-height': ['get', 'h'],
        },
      },
    ],
  });
  return [
    for (final layout in ExtrusionLayouter.layout(
      layers: ExtrusionLayouter.layersOf(theme),
      data: DisplayTileData(
          displayKey: tile, sources: <String, PreparedTile>{'s': prepared}),
      styleZoom: 16,
    )!)
      (layout: layout, skip: null, side: 1),
  ];
}

/// [tiles] painted on a [size]² canvas over blue, the camera at zoom
/// 16 on the tile's centre turned by [rotation] degrees.
Future<ui.Image> _paint(List<ExtrusionTile> tiles,
    {int size = 256,
    double rotation = 0,
    ExtrusionPainter? painter,
    int generation = 1,
    Offset? center}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xff2040a0), BlendMode.src);
  canvas.translate(size / 2, size / 2);
  final radians = rotation * 3.141592653589793 / 180;
  canvas.rotate(radians);
  (painter ?? ExtrusionPainter()).paint(
    canvas,
    generation: generation,
    layouts: () => tiles,
    cameraZoom: 16,
    styleZoom: 16,
    worldCenter: center ?? displayTileRect(_tile, 16).center,
    latitude: 0,
    viewport: Size(size.toDouble(), size.toDouble()),
    rotation: radians,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  return image;
}

Future<void> _expectGolden(ui.Image image, String name) async {
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  final bytes = png!.buffer.asUint8List();
  final golden = Uri.parse('goldens/$name.png');
  // Straight to the comparator: `matchesGoldenFile` hands an image to it
  // through `runAsync`, whose errors only a `testWidgets` reports, so in
  // a plain test a mismatch passed.
  if (autoUpdateGoldenFiles) {
    await goldenFileComparator.update(golden, bytes);
  } else {
    expect(await goldenFileComparator.compare(bytes, golden), isTrue);
  }
}

/// A square ring from (x0, y0) to (x1, y1), MVT exterior winding.
List<List<int>> _box(int x0, int y0, int x1, int y1) => [
      [x0, y0],
      [x1, y0],
      [x1, y1],
      [x0, y1]
    ];

/// A street of buildings around the screen centre (extent 2048, 16
/// extent units to the pixel): a terraced pair sharing a wall, the
/// taller one further out; a U-shaped block open to the north; a
/// building round a courtyard; a tower.
List<(List<List<List<int>>>, num)> get _street => [
      ([_box(2848, 448, 3488, 1088)], 20),
      ([_box(3488, 448, 3968, 1088)], 45),
      (
        [
          [
            [248, 2648],
            [448, 2648],
            [448, 3348],
            [848, 3348],
            [848, 2648],
            [1048, 2648],
            [1048, 3548],
            [248, 3548],
          ],
        ],
        30
      ),
      (
        [
          _box(2748, 2748, 3748, 3748),
          // The courtyard, counter-clockwise: a hole.
          [
            [3048, 3048],
            [3048, 3448],
            [3448, 3448],
            [3448, 3048],
          ],
        ],
        25
      ),
      ([_box(648, 548, 1048, 948)], 120),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a street, looking straight down', () async {
    await _expectGolden(await _paint(_layout(_street)), 'extrusion_street');
  });

  test('the same street, the map turned 30°', () async {
    await _expectGolden(
        await _paint(_layout(_street), rotation: 30), 'extrusion_street_30');
  });

  test('only walls facing the screen centre are drawn', () async {
    // A square 80..110 px right of the centre, straddling its axis: of
    // its four walls only the west one faces the centre.
    final tiles = _layout([
      ([_box(3328, 1808, 3808, 2288)], 200),
    ]);
    final before = ExtrusionPainter.debugVertices;
    (await _paint(tiles, size: 512)).dispose();
    // The roof's four corners and the one wall's four.
    expect(ExtrusionPainter.debugVertices - before, 8);
  });

  group('tiles taken off offer and put back', () {
    // The street on three tiles, the camera on the corner [_tile],
    // [_east] and [_south] share, so all three are on screen.
    final a = _layout(_street);
    final b = _layout(_street, tile: _east);
    final c = _layout(_street, tile: _south);
    final corner = displayTileRect(_tile, 16).bottomRight;

    Future<Uint8List> pixels(List<ExtrusionTile> tiles,
        {ExtrusionPainter? painter, int generation = 1}) async {
      final image = await _paint(tiles,
          size: 512, painter: painter, generation: generation, center: corner);
      final bytes = await image.toByteData();
      image.dispose();
      return bytes!.buffer.asUint8List();
    }

    test(
        'drawing fewer of them sorts nothing, and draws them as a fresh '
        'painter would', () async {
      // What fresh painters draw (their sorts count too, so first).
      final freshA = await pixels(a);
      final freshBoth = await pixels([...a, ...b]);
      final painter = ExtrusionPainter();
      await pixels([...a, ...b], painter: painter);
      final sorts = ExtrusionPainter.debugRebuilds;
      final onlyA = await pixels(a, painter: painter, generation: 2);
      final both = await pixels([...a, ...b], painter: painter, generation: 3);
      expect(ExtrusionPainter.debugRebuilds, sorts);
      expect(onlyA, freshA);
      expect(both, freshBoth);
      expect(onlyA, isNot(freshBoth), reason: 'b is on screen');
      painter.reset();
    });

    test('a skip mask applies without a sort', () async {
      final freshA = await pixels(a);
      final painter = ExtrusionPainter();
      await pixels([...a, ...b], painter: painter);
      final sorts = ExtrusionPainter.debugRebuilds;
      // One cell over the whole tile, marked: none of b's buildings.
      final skipped = [
        for (final t in b)
          (layout: t.layout, skip: Uint8List.fromList([1]), side: 1),
      ];
      final masked =
          await pixels([...a, ...skipped], painter: painter, generation: 2);
      expect(ExtrusionPainter.debugRebuilds, sorts);
      expect(masked, freshA);
      painter.reset();
    });

    test(
        'a tile not seen before sorts; one off offer past the grace '
        'period is left out of that sort', () async {
      ExtrusionPainter.keepInactiveFor = Duration.zero;
      addTearDown(
          () => ExtrusionPainter.keepInactiveFor = const Duration(seconds: 2));
      final freshAC = await pixels([...a, ...c]);
      final painter = ExtrusionPainter();
      await pixels([...a, ...b], painter: painter);
      await pixels(a, painter: painter, generation: 2);
      final sorts = ExtrusionPainter.debugRebuilds;
      final ac = await pixels([...a, ...c], painter: painter, generation: 3);
      expect(ExtrusionPainter.debugRebuilds, sorts + 1, reason: 'c is new');
      expect(ac, freshAC);
      await pixels([...a, ...b], painter: painter, generation: 4);
      expect(ExtrusionPainter.debugRebuilds, sorts + 2,
          reason: 'b was left out of the sort for c');
      painter.reset();
    });
  });

  test('a frame that changed nothing redraws the last one', () async {
    final painter = ExtrusionPainter();
    final tiles = _layout(_street);
    (await _paint(tiles, painter: painter)).dispose();
    final built = ExtrusionPainter.debugVertices;
    (await _paint(tiles, painter: painter)).dispose();
    expect(ExtrusionPainter.debugVertices, built);
    (await _paint(tiles, painter: painter, rotation: 1)).dispose();
    expect(ExtrusionPainter.debugVertices, greaterThan(built));
    painter.reset();
  });
}
