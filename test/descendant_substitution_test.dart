import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Theme;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_zoom.dart';
import 'package:flutter_map_vector_tiles/src/grid/raster_tile_store.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/lifecycle_harness.dart';

/// Zoom-in has always had ancestor substitution: a display tile whose
/// data is still loading renders a cached ancestor's sub-region rather
/// than a blank. These tests pin its zoom-out counterpart — composing
/// cached *descendants* into the display tile, each shrunk into its
/// sub-square — so a cold zoom-out shows the pixels it just had instead
/// of the background.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('findDescendants', () {
    test('collects a full cover of children', () {
      final cached = {
        for (var dx = 0; dx <= 1; dx++)
          for (var dy = 0; dy <= 1; dy++) TileKey(6, 6 + dx, 14 + dy): 'z6',
      };
      final found =
          findDescendants(const TileKey(5, 3, 7), 20, (k) => cached[k]);
      expect(found, hasLength(4));
    });

    test('a missing child is searched one level deeper, and no further', () {
      final cached = <TileKey, String>{
        const TileKey(6, 6, 14): 'child',
        // Two grandchildren under the missing child (6,7,14).
        const TileKey(7, 14, 28): 'grand',
        const TileKey(7, 15, 29): 'grand',
        // A great-grandchild under the missing chain below (6,6,15) —
        // beyond the two-level walk, must not be found.
        const TileKey(8, 24, 60): 'too deep',
      };
      final found =
          findDescendants(const TileKey(5, 3, 7), 20, (k) => cached[k]);
      expect(found, unorderedEquals(['child', 'grand', 'grand']));
    });

    test('never walks past the source maximum zoom', () {
      final cached = <TileKey, String>{
        const TileKey(6, 6, 14): 'child',
        const TileKey(7, 14, 30): 'grand',
      };
      expect(findDescendants(const TileKey(5, 3, 7), 5, (k) => cached[k]),
          isEmpty);
      // One level of headroom finds the child but must not recurse to a
      // depth the source cannot serve.
      expect(findDescendants(const TileKey(5, 3, 7), 6, (k) => cached[k]),
          ['child']);
    });
  });

  group('descendant rasterization', () {
    test('a descendant renders into its sub-square, and only there', () async {
      final image = TileRasterizer.rasterize(
        theme: _theme(),
        data: _descendantData([_preparedChild(const TileKey(2, 1, 0))]),
        styleZoom: 1,
        devicePixelRatio: 1,
      )!;
      // (2,1,0) is the top-right quadrant of display tile (1,0,0).
      expect(await _alphaAt(image, 192, 64), 255);
      expect(await _alphaAt(image, 64, 64), 0);
      expect(await _alphaAt(image, 192, 192), 0);
      expect(await _alphaAt(image, 64, 192), 0);
    });

    test('several descendants compose one display tile', () async {
      final image = TileRasterizer.rasterize(
        theme: _theme(),
        data: _descendantData([
          _preparedChild(const TileKey(2, 0, 0)),
          _preparedChild(const TileKey(2, 1, 1)),
        ]),
        styleZoom: 1,
        devicePixelRatio: 1,
      )!;
      expect(await _alphaAt(image, 64, 64), 255);
      expect(await _alphaAt(image, 192, 192), 255);
      expect(await _alphaAt(image, 192, 64), 0);
      expect(await _alphaAt(image, 64, 192), 0);
    });

    test('buffer geometry stays inside the descendant sub-square', () async {
      // The polygon spills 300 extent units past its tile's left edge —
      // MVT buffer geometry. Un-clipped it would paint ~9px into the
      // top-left quadrant, whose own descendant may be missing.
      final spilling = PreparedTile(
        key: const TileKey(2, 1, 0),
        layers: {
          'geo': PreparedSourceLayer(extent: extent, features: [
            _feature(PreparedGeomType.polygon, [
              [-300, 0, 4096, 0, 4096, 4096, -300, 4096],
            ]),
          ]),
        },
        byteSize: 0,
      );
      final image = TileRasterizer.rasterize(
        theme: _theme(),
        data: _descendantData([spilling]),
        styleZoom: 1,
        devicePixelRatio: 1,
      )!;
      // The quadrant boundary is x=128; the spill zone would be ~119..128.
      expect(await _alphaAt(image, 122, 64), 0,
          reason: 'buffer spill must be clipped at the sub-square edge');
      expect(await _alphaAt(image, 134, 64), 255);
    });

    test('a raster-source descendant lands in its sub-square', () async {
      final tile = RasterTile(const TileKey(2, 1, 0), _solidImage(8));
      final image = TileRasterizer.rasterize(
        theme: _rasterTheme(),
        data: DisplayTileData(
          displayKey: const TileKey(1, 0, 0),
          sources: const {},
          descendantRasters: {
            'r': [tile],
          },
        ),
        styleZoom: 1,
        devicePixelRatio: 1,
      )!;
      tile.dispose();
      expect(await _alphaAt(image, 192, 64), 255);
      expect(await _alphaAt(image, 64, 64), 0);
      expect(await _alphaAt(image, 64, 192), 0);
    });
  });

  group('through the layer', () {
    setUp(VectorTileLayer.clearMemoryCache);

    testWidgets(
        'a screen below the cached level paints from its descendants '
        'while its own tiles never arrive', (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      // Visit z14 normally, filling the shared decoded-tile cache.
      final provider = _ZoomFloorProvider(fullTile());
      await tester.pumpWidget(app(MapController(), provider));
      await settleLoads(tester, provider);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      // Reopen one level out with a network that never answers again:
      // no z13 tile, no ancestor, no retained level — only the z14
      // descendants in the memory cache can put pixels on this screen.
      provider.floor = 99;
      await tester.pumpWidget(app(MapController(), provider, initialZoom: 13));
      expect(
        await pumpUntil(tester, () async {
          // Tolerant of the hairline seams between composed sub-squares:
          // land red over background blue, not an exact colour match.
          final c = await centrePixel(tester);
          return c.r > 0.5 && c.b < 0.5;
        }),
        isTrue,
        reason: 'with its own tiles unavailable the screen must compose '
            'provisional imagery from cached descendants instead of '
            'showing the background',
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

Theme _theme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'land',
          'type': 'fill',
          'source': 's',
          'source-layer': 'geo',
          'paint': {'fill-color': '#ff0000'},
        },
      ],
    });

Theme _rasterTheme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'photo',
          'type': 'raster',
          'source': 'r',
        },
      ],
    });

/// A data tile whose single polygon covers its whole extent.
PreparedTile _preparedChild(TileKey key) => PreparedTile(
      key: key,
      layers: {
        'geo': PreparedSourceLayer(extent: extent, features: [
          _feature(PreparedGeomType.polygon, [
            [0, 0, 4096, 0, 4096, 4096, 0, 4096],
          ]),
        ]),
      },
      byteSize: 0,
    );

DisplayTileData _descendantData(List<PreparedTile> descendants) =>
    DisplayTileData(
      displayKey: const TileKey(1, 0, 0),
      sources: const {},
      descendantSources: {'s': descendants},
    );

/// Builds a feature with decode-style bounds, so it participates in
/// culling like production features do.
PreparedFeature _feature(PreparedGeomType type, List<List<double>> parts) {
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

Future<int> _alphaAt(ui.Image image, int x, int y) async {
  final data = (await image.toByteData())!;
  return data.getUint8((y * image.width + x) * 4 + 3);
}

ui.Image _solidImage(int size) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = const Color(0xff00ff00),
  );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(size, size);
  picture.dispose();
  return image;
}

/// Serves [bytes] for any tile at or above [floor]; below it the load
/// never completes — a network that has gone cold.
class _ZoomFloorProvider extends CountingProvider {
  final Uint8List bytes;
  var floor = 0;

  _ZoomFloorProvider(this.bytes);

  @override
  String get cacheKey => 'zoom-floor';

  @override
  Future<TileResponse> load(TileKey tile, {CancellationToken? cancellation}) {
    note(tile);
    if (tile.z >= floor) {
      return Future.value(TileResponseData(bytes));
    }
    return Completer<TileResponse>().future;
  }
}
