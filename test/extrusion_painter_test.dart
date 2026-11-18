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
import 'package:flutter_map_vector_tiles/src/style/feature_state.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
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

/// [features] — `(rings, properties)` in tile-extent units, MVT winding,
/// ids counting from 1 — decoded over [tile] as the worker decodes a
/// tile with 3D buildings on.
PreparedTile _prepare(
    List<(List<List<List<int>>>, Map<String, Object>)> features,
    {TileKey tile = _tile}) {
  final layer = MvtTileBuilder().layer('building');
  var id = 0;
  for (final (rings, properties) in features) {
    layer.feature(
        type: 3, id: ++id, geometry: _polygon(rings), properties: properties);
  }
  return prepareTileSync(PrepareInput(
    z: tile.z,
    x: tile.x,
    y: tile.y,
    bytes: layer.done().build(),
    layerProperties: const {'building': null},
    extrusionLayers: const {'building'},
  ));
}

/// A style of one `fill-extrusion` layer, `b`, over source layer
/// `building`, with a root [light] when given.
Theme _style(
        {Object color = '#e0d8cc',
        Object height = const ['get', 'h'],
        bool? verticalGradient,
        Map<String, Object?>? light}) =>
    const ThemeReader().read({
      if (light != null) 'light': light,
      'layers': [
        {
          'id': 'b',
          'type': 'fill-extrusion',
          'source': 's',
          'source-layer': 'building',
          'paint': {
            'fill-extrusion-color': color,
            'fill-extrusion-height': height,
            if (verticalGradient != null)
              'fill-extrusion-vertical-gradient': verticalGradient,
          },
        },
      ],
    });

/// The buildings [layers] lay out of [prepared] over [tile] at
/// [styleZoom], under [featureStates].
List<ExtrusionTile> _layOut(PreparedTile prepared, List<FillThemeLayer> layers,
        {TileKey tile = _tile,
        double styleZoom = 16,
        FeatureStates? featureStates}) =>
    [
      for (final layout in ExtrusionLayouter.layout(
        layers: layers,
        data: DisplayTileData(
            displayKey: tile,
            sources: <String, PreparedTile>{'s': prepared},
            featureStates: featureStates),
        styleZoom: styleZoom,
      )!)
        (layout: layout, skip: null, side: 1),
    ];

/// [features] — `(rings, height)` — with each height as the property
/// `h`.
List<(List<List<List<int>>>, Map<String, Object>)> _withHeights(
        List<(List<List<List<int>>>, num)> features) =>
    [
      for (final (rings, height) in features) (rings, {'h': height})
    ];

/// Lays [features] — `(rings, height)` in tile-extent units, MVT winding
/// — out as one `fill-extrusion` layer over [tile].
List<ExtrusionTile> _layout(List<(List<List<List<int>>>, num)> features,
        {String color = '#e0d8cc', TileKey tile = _tile}) =>
    _layOut(_prepare(_withHeights(features), tile: tile),
        ExtrusionLayouter.layersOf(_style(color: color)),
        tile: tile);

/// [tiles] painted on a [size]² canvas over blue, the camera at zoom
/// 16 on the tile's centre turned by [rotation] degrees, the style at
/// [styleZoom]. [layers] are the theme's 3D layers, those of [tiles] by
/// default.
Future<ui.Image> _paint(List<ExtrusionTile> tiles,
    {int size = 256,
    double rotation = 0,
    ExtrusionPainter? painter,
    int generation = 1,
    Offset? center,
    double styleZoom = 16,
    List<FillThemeLayer>? layers,
    StyleLight? light}) async {
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
    layers: layers ?? _layersOf(tiles),
    cameraZoom: 16,
    styleZoom: styleZoom,
    worldCenter: center ?? displayTileRect(_tile, 16).center,
    latitude: 0,
    viewport: Size(size.toDouble(), size.toDouble()),
    rotation: radians,
    light: light,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  return image;
}

/// [image]'s RGBA bytes; disposes it.
Future<Uint8List> _rgba(ui.Image image) async {
  final bytes = await image.toByteData();
  image.dispose();
  return bytes!.buffer.asUint8List();
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

/// The layers of [tiles], one per id, as the theme's memo hands them to
/// the painter: the same list for the same ids.
List<FillThemeLayer> _layersOf(Iterable<ExtrusionTile> tiles) {
  final byId = <String, FillThemeLayer>{};
  for (final t in tiles) {
    byId.putIfAbsent(t.layout.layer.id, () => t.layout.layer);
  }
  return _layerLists.putIfAbsent(
      (byId.keys.toList()..sort()).join('\n'), () => byId.values.toList());
}

final _layerLists = <String, List<FillThemeLayer>>{};

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

  test('one building too big for a single draw goes out over several',
      () async {
    // A square whose sides are fine combs: 28,000 vertices in one ring,
    // within the mesh builder's per-polygon cap. Seen from just north of
    // it, the roof and the walls facing the camera need more vertices
    // than one draw takes.
    final ring = <List<int>>[];
    for (var x = 300; x < 3800; x += 2) {
      ring.addAll([
        [x, 300],
        [x, 290],
        [x + 1, 290],
        [x + 1, 300]
      ]);
    }
    for (var y = 300; y < 3800; y += 2) {
      ring.addAll([
        [3800, y],
        [3810, y],
        [3810, y + 1],
        [3800, y + 1]
      ]);
    }
    for (var x = 3800; x > 300; x -= 2) {
      ring.addAll([
        [x, 3800],
        [x, 3810],
        [x - 1, 3810],
        [x - 1, 3800]
      ]);
    }
    for (var y = 3800; y > 300; y -= 2) {
      ring.addAll([
        [300, y],
        [290, y],
        [290, y - 1],
        [300, y - 1]
      ]);
    }
    final tiles = _layout([
      ([ring], 100)
    ]);
    expect(tiles.single.layout.mesh.length, 1);
    final rect = displayTileRect(_tile, 16);
    final before = ExtrusionPainter.debugVertices;
    (await _paint(tiles, center: Offset(rect.center.dx, rect.top + 8)))
        .dispose();
    expect(ExtrusionPainter.debugVertices - before, greaterThan(65535));
  });

  group('heights ramping in with the zoom', () {
    // MapLibre's 3D-buildings example: every building rises out of the
    // ground over zoom 15.
    const ramp = [
      'interpolate',
      ['linear'],
      ['zoom'],
      15,
      0,
      16,
      ['get', 'h']
    ];

    test('halfway up they draw as the same heights given outright', () async {
      // A tower near the centre, first in the tile, and a low house just
      // outward of it: the tower leans out over the house, so the house
      // must be drawn first. Each has its own colour and the walls no
      // gradient: only the order they are drawn in tells the two styles
      // apart.
      final prepared = _prepare([
        (
          [_box(2400, 1900, 2800, 2200)],
          {'h': 400, 'half': 200, 'c': '#ff0000'}
        ),
        ([_box(2850, 1900, 3500, 2200)], {'h': 6, 'half': 3, 'c': '#00ff00'}),
      ]);
      List<FillThemeLayer> layers(Object height) =>
          ExtrusionLayouter.layersOf(_style(
              color: const ['get', 'c'],
              height: height,
              verticalGradient: false));
      final ramped = layers(ramp);
      final outright = layers(const ['get', 'half']);
      final rampedTiles = _layOut(prepared, ramped, styleZoom: 15.5);
      final outrightTiles = _layOut(prepared, outright, styleZoom: 15.5);
      final layout = rampedTiles.single.layout;
      // At the foot of the band every ramped roof is on the ground;
      // halfway through, both styles' roofs stand at the same heights.
      expect(layout.heights, everyElement(0));
      expect(layout.heightAt(0, 15.5), 200);
      expect(layout.heightAt(1, 15.5), 3);
      expect(outrightTiles.single.layout.heightAt(0, 15.5), 200);
      expect(outrightTiles.single.layout.heightAt(1, 15.5), 3);

      expect(
          await _rgba(
              await _paint(rampedTiles, styleZoom: 15.5, layers: ramped)),
          await _rgba(
              await _paint(outrightTiles, styleZoom: 15.5, layers: outright)),
          reason: 'the same buildings at the same heights, drawn in a '
              'different order');
    });

    test('halfway up a terraced pair still shares its wall', () {
      // The taller one further out: the shorter one's roof stands in
      // front of the lower part of its wall.
      final prepared = _prepare([
        ([_box(2848, 448, 3488, 1088)], {'h': 40, 'half': 20}),
        ([_box(3488, 448, 3968, 1088)], {'h': 90, 'half': 45}),
      ]);
      List<ExtrusionTile> at(Object height) =>
          _layOut(prepared, ExtrusionLayouter.layersOf(_style(height: height)),
              styleZoom: 15.5);
      expect(at(const ['get', 'half']).single.layout.wallCoveredBy, isNotNull);
      expect(at(ramp).single.layout.wallCoveredBy, isNotNull,
          reason: 'covers judged from the roofs at the foot of the band, '
              'all on the ground, cover nothing');
    });
  });

  group('two 3D layers', () {
    const west = _tile, middle = _east, east = TileKey(16, 32770, 32768);

    /// Two `fill-extrusion` layers in this style order: [first] red,
    /// then [second] green, each drawing the buildings of its own
    /// `kind`.
    Theme twoLayers(String first, String second, {double secondOpacity = 1}) =>
        const ThemeReader().read({
          'layers': [
            {
              'id': first,
              'type': 'fill-extrusion',
              'source': 's',
              'source-layer': 'building',
              'filter': [
                '==',
                ['get', 'kind'],
                'r'
              ],
              'paint': {
                'fill-extrusion-color': '#ff0000',
                'fill-extrusion-height': ['get', 'h'],
              },
            },
            {
              'id': second,
              'type': 'fill-extrusion',
              'source': 's',
              'source-layer': 'building',
              'filter': [
                '==',
                ['get', 'kind'],
                'g'
              ],
              'paint': {
                'fill-extrusion-color': '#00ff00',
                'fill-extrusion-height': ['get', 'h'],
                'fill-extrusion-opacity': secondOpacity,
              },
            },
          ],
        });

    /// The same 50 px box at [tile]'s centre, 20 m tall, once per kind
    /// in [kinds].
    List<ExtrusionTile> boxes(Theme theme, TileKey tile, List<String> kinds) =>
        _layOut(
            _prepare([
              for (final kind in kinds)
                ([_box(1648, 1648, 2448, 2448)], {'h': 20, 'kind': kind}),
            ], tile: tile),
            ExtrusionLayouter.layersOf(theme),
            tile: tile);

    /// The RGBA of the screen centre, the camera on [tile]'s centre and
    /// [theme] the current one.
    Future<List<int>> centre(List<ExtrusionTile> tiles, Theme theme,
        {required TileKey tile,
        ExtrusionPainter? painter,
        int generation = 1}) async {
      final bytes = await _rgba(await _paint(tiles,
          painter: painter,
          generation: generation,
          center: displayTileRect(tile, 16).center,
          layers: ExtrusionLayouter.layersOf(theme)));
      const i = (128 * 256 + 128) * 4;
      return bytes.sublist(i, i + 4);
    }

    bool green(List<int> p) => p[1] > p[0] && p[1] > 100;

    test('the later one in the style draws over the earlier, whatever ids',
        () async {
      // Ids sorting in style order, and against it.
      for (final second in ['landmarks', 'a-landmarks']) {
        final theme = twoLayers('buildings', second);
        final p =
            await centre(boxes(theme, west, ['r', 'g']), theme, tile: west);
        expect(green(p), isTrue, reason: '$second: pixel $p');
      }
    });

    test('they keep their order as the map pans', () async {
      ExtrusionPainter.keepInactiveFor = Duration.zero;
      addTearDown(
          () => ExtrusionPainter.keepInactiveFor = const Duration(seconds: 2));
      final theme = twoLayers('buildings', 'a-landmarks');
      final painter = ExtrusionPainter();
      // Only the first layer's buildings to the west, both layers'
      // coincident in the middle, only the second's to the east.
      final w = boxes(theme, west, ['r']);
      final m = boxes(theme, middle, ['r', 'g']);
      final e = boxes(theme, east, ['g']);
      final before = await centre([...w, ...m], theme,
          tile: middle, painter: painter, generation: 1);
      // Panned east: the west tile off screen, the east one in, the
      // camera on the middle one all along.
      final after = await centre([...m, ...e], theme,
          tile: middle, painter: painter, generation: 2);
      expect(after, before,
          reason: 'the middle tile is drawn the same, whichever '
              'neighbours are on offer');
      painter.reset();
    });

    test(
        'opacity comes from the current theme, not one tiles were laid out '
        'under', () async {
      // A retained lower level laid out under the old style, the current
      // level under the new one, in which the second layer is hidden.
      final old = twoLayers('buildings', 'landmarks');
      final current = twoLayers('buildings', 'landmarks', secondOpacity: 0);
      final painter = ExtrusionPainter();
      const lower = TileKey(15, 16384, 16384);
      final retained = boxes(old, lower, ['g']);
      final fresh = boxes(current, middle, ['g']);
      await centre([...retained, ...fresh], current,
          tile: middle, painter: painter, generation: 1);
      // The crossing ends: only the current level is on offer.
      final p = await centre(fresh, current,
          tile: middle, painter: painter, generation: 2);
      expect(green(p), isFalse,
          reason: 'fill-extrusion-opacity is 0 in the current theme; '
              'pixel $p');
      painter.reset();
    });
  });

  test('two maps sharing a layout each draw it under their own light',
      () async {
    // One decoded tile, as the process-wide decoded-tile store hands it
    // to every layer over the same source, and one theme, as two maps
    // built from it share: the light's colour and intensity follow the
    // zoom.
    final prepared = _prepare(_withHeights([
      ([_box(2848, 448, 3488, 1088)], 20),
      ([_box(648, 548, 1048, 948)], 120),
      ([_box(2748, 2748, 3748, 3748)], 25),
    ]));
    final theme = _style(light: {
      'intensity': [
        'interpolate',
        ['linear'],
        ['zoom'],
        14,
        0.1,
        18,
        1.0
      ],
      'color': [
        'interpolate',
        ['linear'],
        ['zoom'],
        14,
        '#ffffff',
        18,
        '#ff0000'
      ],
    });
    expect(theme.light, isNotNull);
    final layers = ExtrusionLayouter.layersOf(theme);
    // The main map at style zoom 15, an inset at 17: the height reads no
    // zoom, so both get the very same layout.
    final main = _layOut(prepared, layers, styleZoom: 15);
    final inset = _layOut(prepared, layers, styleZoom: 17);
    expect(identical(main.single.layout, inset.single.layout), isTrue);

    final center = displayTileRect(_tile, 16).center;
    Future<Uint8List> paint(ExtrusionPainter painter, List<ExtrusionTile> t,
            {required double styleZoom, double dx = 0}) async =>
        _rgba(await _paint(t,
            painter: painter,
            styleZoom: styleZoom,
            center: center + Offset(dx, 0),
            layers: layers,
            light: theme.light));

    // What a painter alone draws for the main map's second frame, panned
    // by a pixel, and what the inset's light would draw instead.
    final alone = ExtrusionPainter();
    final expected = await paint(alone, main, styleZoom: 15, dx: 1);
    alone.reset();
    final other = ExtrusionPainter();
    final underInsetLight = await paint(other, main, styleZoom: 17, dx: 1);
    other.reset();
    expect(underInsetLight, isNot(expected),
        reason: 'the two lights shade the buildings differently');

    // The two maps, frame by frame.
    final mainPainter = ExtrusionPainter();
    final insetPainter = ExtrusionPainter();
    await paint(mainPainter, main, styleZoom: 15);
    await paint(insetPainter, inset, styleZoom: 17);
    // The main map pans by a pixel: the same zoom, the same light.
    final panned = await paint(mainPainter, main, styleZoom: 15, dx: 1);
    mainPainter.reset();
    insetPainter.reset();
    expect(panned, expected,
        reason: "the main map drew in the inset map's light");
  });

  test('an absurd height draws, held at the near plane', () async {
    // Past what a Float32 holds: stored as such it would be infinite.
    final tiles = _layout([
      ([_box(3328, 1808, 3808, 2288)], 1e39),
    ]);
    expect(tiles.single.layout.heights.single.isFinite, isTrue);
    (await _paint(tiles, size: 512)).dispose();
  });

  group('tiles taken off offer and put back', () {
    // The street on three tiles, the camera on the corner [_tile],
    // [_east] and [_south] share, so all three are on screen.
    final a = _layout(_street);
    final b = _layout(_street, tile: _east);
    final c = _layout(_street, tile: _south);
    final corner = displayTileRect(_tile, 16).bottomRight;
    // The theme's 3D layers stay what they are, whatever is on offer.
    final layers = _layersOf([...a, ...b, ...c]);

    Future<Uint8List> pixels(List<ExtrusionTile> tiles,
            {ExtrusionPainter? painter, int generation = 1}) async =>
        _rgba(await _paint(tiles,
            size: 512,
            painter: painter,
            generation: generation,
            center: corner,
            layers: layers));

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

    test('nothing on offer past the grace period lets go of them all',
        () async {
      ExtrusionPainter.keepInactiveFor = Duration.zero;
      addTearDown(
          () => ExtrusionPainter.keepInactiveFor = const Duration(seconds: 2));
      final painter = ExtrusionPainter();
      await pixels([...a, ...b], painter: painter);
      // Zoomed out below the buildings' minzoom: nothing on offer, for
      // many generations — label publishes, tiles loading — and no new
      // tile to sort for.
      for (var g = 2; g < 50; g++) {
        await pixels(const [], painter: painter, generation: g);
      }
      final sorts = ExtrusionPainter.debugRebuilds;
      await pixels([...a, ...b], painter: painter, generation: 50);
      expect(ExtrusionPainter.debugRebuilds, sorts + 1,
          reason: 'back on offer, a and b are new to the painter');
      painter.reset();
    });

    test('fewer on offer past the grace period lets go of the rest', () async {
      ExtrusionPainter.keepInactiveFor = Duration.zero;
      addTearDown(
          () => ExtrusionPainter.keepInactiveFor = const Duration(seconds: 2));
      final painter = ExtrusionPainter();
      await pixels([...a, ...b], painter: painter);
      for (var g = 2; g < 50; g++) {
        await pixels(a, painter: painter, generation: g);
      }
      final sorts = ExtrusionPainter.debugRebuilds;
      await pixels([...a, ...b], painter: painter, generation: 50);
      expect(ExtrusionPainter.debugRebuilds, sorts + 1,
          reason: 'back on offer, b is new to the painter');
      painter.reset();
    });

    test('trim lets go of those off offer at once, grace period or not',
        () async {
      final painter = ExtrusionPainter();
      await pixels([...a, ...b], painter: painter);
      await pixels(a, painter: painter, generation: 2);
      painter.trim();
      final sorts = ExtrusionPainter.debugRebuilds;
      await pixels([...a, ...b], painter: painter, generation: 3);
      expect(ExtrusionPainter.debugRebuilds, sorts + 1,
          reason: 'well within keepInactiveFor, yet b is new again');
      painter.reset();
    });
  });

  test('a layout replaced under a new feature state leaves the orders',
      () async {
    // A hover highlight, as in MapLibre's "highlight a building"
    // examples, on the terraced house.
    final prepared = _prepare(_withHeights(_street));
    final layers = ExtrusionLayouter.layersOf(_style(color: const [
      'case',
      [
        'boolean',
        ['feature-state', 'hover'],
        false
      ],
      '#ff0000',
      '#e0d8cc',
    ]));
    final states = FeatureStates();
    final painter = ExtrusionPainter();
    var generation = 0;
    final replaced = <List<ExtrusionTile>>[];
    for (var i = 0; i < 20; i++) {
      states.set('s', 'building', 1, {'hover': i.isEven});
      final tiles = _layOut(prepared, layers, featureStates: states);
      replaced.add(tiles);
      (await _paint(tiles,
              painter: painter, generation: ++generation, layers: layers))
          .dispose();
    }
    // Every layout but the last was replaced by one for the same data
    // tile, layer and zoom: offered again, each is new to the painter.
    var held = 0;
    for (final old in replaced.take(19)) {
      final sorts = ExtrusionPainter.debugRebuilds;
      (await _paint(old,
              painter: painter, generation: ++generation, layers: layers))
          .dispose();
      if (ExtrusionPainter.debugRebuilds == sorts) held++;
    }
    painter.reset();
    expect(held, 0,
        reason: 'a layout replaced by one for the same data tile and layer '
            'is never offered again, so the orders must not keep it');
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
