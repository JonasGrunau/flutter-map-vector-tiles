import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a feature with decode-style bounds, so it participates in
/// culling like production features do.
PreparedFeature _feature(
  PreparedGeomType type,
  List<List<double>> parts,
) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final part in parts) {
    for (var i = 0; i + 1 < part.length; i += 2) {
      if (part[i] < minX) minX = part[i];
      if (part[i] > maxX) maxX = part[i];
      if (part[i + 1] < minY) minY = part[i + 1];
      if (part[i + 1] > maxY) maxY = part[i + 1];
    }
  }
  return PreparedFeature(
    id: null,
    type: type,
    parts: [for (final part in parts) Float32List.fromList(part)],
    properties: const {},
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
  );
}

DisplayTileData _data(
  TileKey displayKey,
  TileKey dataKey, {
  List<PreparedFeature> geo = const [],
  List<PreparedFeature> dash = const [],
}) =>
    DisplayTileData(
      displayKey: displayKey,
      sources: {
        's': PreparedTile(
          key: dataKey,
          layers: {
            'geo': PreparedSourceLayer(extent: 4096, features: geo),
            'dash': PreparedSourceLayer(extent: 4096, features: dash),
          },
          byteSize: 0,
        ),
      },
    );

Theme _theme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'water',
          'type': 'fill',
          'source': 's',
          'source-layer': 'geo',
          'paint': {'fill-color': '#2244aa'},
        },
        {
          'id': 'roads',
          'type': 'line',
          'source': 's',
          'source-layer': 'geo',
          'paint': {'line-color': '#ffffff', 'line-width': 4},
        },
        {
          'id': 'casing',
          'type': 'line',
          'source': 's',
          'source-layer': 'geo',
          'paint': {
            'line-color': '#222222',
            'line-width': 2,
            'line-gap-width': 5,
          },
        },
        {
          'id': 'dashed',
          'type': 'line',
          'source': 's',
          'source-layer': 'dash',
          'paint': {
            'line-color': '#ff8800',
            'line-width': 4,
            'line-dasharray': [3, 2],
          },
        },
      ],
    });

/// The dense overzoom fixture: geometry sized for a z2 data tile viewed
/// through z5 display tiles (shift 3).
DisplayTileData _denseTile(TileKey displayKey) => _data(
      displayKey,
      const TileKey(2, 1, 1),
      geo: [
        // Diagonal and axis-aligned lines crossing the whole data tile.
        _feature(PreparedGeomType.line, [
          [0, 0, 4096, 4096],
        ]),
        _feature(PreparedGeomType.line, [
          [0, 1800, 4096, 1800],
        ]),
        _feature(PreparedGeomType.line, [
          [1900, 0, 1900, 4096],
        ]),
        // Polygon with a hole, straddling the display window.
        _feature(PreparedGeomType.polygon, [
          [1000, 1000, 3000, 1000, 3000, 3000, 1000, 3000],
          [1500, 1500, 1500, 2500, 2500, 2500, 2500, 1500],
        ]),
        // A ring enclosing every display tile of the data tile.
        _feature(PreparedGeomType.polygon, [
          [-500, -500, 4600, -500, 4600, 4600, -500, 4600],
        ]),
        // Far away from the tested display tiles: culled on one side,
        // drawn-then-clipped-away on the other — same pixels.
        _feature(PreparedGeomType.line, [
          [50, 50, 300, 50],
        ]),
      ],
      dash: [
        _feature(PreparedGeomType.line, [
          [0, 1700, 4096, 1700],
        ]),
      ],
    );

Future<int> _maxByteDiff(ui.Image a, ui.Image b) async {
  final da = (await a.toByteData())!;
  final db = (await b.toByteData())!;
  expect(da.lengthInBytes, db.lengthInBytes);
  var max = 0;
  for (var i = 0; i < da.lengthInBytes; i++) {
    final d = (da.getUint8(i) - db.getUint8(i)).abs();
    if (d > max) max = d;
  }
  return max;
}

Future<int> _alphaAt(ui.Image image, int x, int y) async {
  final data = (await image.toByteData())!;
  return data.getUint8((y * image.width + x) * 4 + 3);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => TileRasterizer.debugDisableCulling = false);

  test('features far outside the display window are culled entirely', () {
    // Data covers extent 0..4096; display tile (5,15,15) shows
    // [3584, 4096]^2. A feature near the extent origin cannot reach it.
    final image = TileRasterizer.rasterize(
      theme: _theme(),
      data: _data(
        const TileKey(5, 15, 15),
        const TileKey(2, 1, 1),
        geo: [
          _feature(PreparedGeomType.line, [
            [0, 50, 400, 50],
          ]),
        ],
      ),
      styleZoom: 5,
      devicePixelRatio: 1,
    );
    expect(image, isNull, reason: 'nothing visible should mean no image');

    final near = TileRasterizer.rasterize(
      theme: _theme(),
      data: _data(
        const TileKey(5, 8, 8),
        const TileKey(2, 1, 1),
        geo: [
          _feature(PreparedGeomType.line, [
            [0, 50, 400, 50],
          ]),
        ],
      ),
      styleZoom: 5,
      devicePixelRatio: 1,
    );
    expect(near, isNotNull);
    near!.dispose();
  });

  test('features without bounds are never culled', () {
    // Hand-built features default to unknown (infinite) bounds and must
    // render exactly as before culling existed.
    final image = TileRasterizer.rasterize(
      theme: _theme(),
      data: _data(
        const TileKey(5, 8, 8),
        const TileKey(2, 1, 1),
        geo: [
          PreparedFeature(
            id: null,
            type: PreparedGeomType.line,
            parts: [
              Float32List.fromList([0, 50, 400, 50])
            ],
            properties: const {},
          ),
        ],
      ),
      styleZoom: 5,
      devicePixelRatio: 1,
    );
    expect(image, isNotNull);
    image!.dispose();
  });

  test(
      'culling and clipping are pixel-equivalent to the full render '
      'at overzoom', () async {
    // Two adjacent shift-3 display tiles: equivalence per tile also
    // proves dash phase stays continuous across the display-tile seam,
    // because the unclipped renders are seam-continuous by construction.
    for (final displayKey in const [TileKey(5, 11, 11), TileKey(5, 12, 11)]) {
      final clipped = TileRasterizer.rasterize(
        theme: _theme(),
        data: _denseTile(displayKey),
        styleZoom: 5,
        devicePixelRatio: 1,
      )!;
      TileRasterizer.debugDisableCulling = true;
      final full = TileRasterizer.rasterize(
        theme: _theme(),
        data: _denseTile(displayKey),
        styleZoom: 5,
        devicePixelRatio: 1,
      )!;
      TileRasterizer.debugDisableCulling = false;

      expect(await _maxByteDiff(clipped, full), lessThanOrEqualTo(2),
          reason: '$displayKey must render identically with culling');
      clipped.dispose();
      full.dispose();
    }
  });

  test('circles just outside the window still paint their visible arc',
      () async {
    final theme = const ThemeReader().read({
      'layers': [
        {
          'id': 'dot',
          'type': 'circle',
          'source': 's',
          'source-layer': 'geo',
          'paint': {'circle-color': '#ff0000', 'circle-radius': 20},
        },
      ],
    });
    // extent -160 maps to logical -10: the centre is outside the tile,
    // the 20px radius reaches 10px into it.
    final image = TileRasterizer.rasterize(
      theme: theme,
      data: _data(
        const TileKey(3, 4, 4),
        const TileKey(3, 4, 4),
        geo: [
          _feature(PreparedGeomType.point, [
            [-160, 2048],
          ]),
        ],
      ),
      styleZoom: 3,
      devicePixelRatio: 1,
    );
    expect(image, isNotNull);
    expect(await _alphaAt(image!, 4, 128), greaterThan(0));
    image.dispose();
  });
}
