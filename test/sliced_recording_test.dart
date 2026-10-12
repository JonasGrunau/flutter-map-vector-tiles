import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// A square over the tile's left half and a line across its middle.
DisplayTileData _tile() {
  final tile = PreparedTile(
    key: const TileKey(2, 1, 1),
    layers: {
      'area': PreparedSourceLayer(extent: 4096, features: [
        PreparedFeature(
          id: 1,
          type: PreparedGeomType.polygon,
          parts: [
            Float32List.fromList([0, 0, 2048, 0, 2048, 4096, 0, 4096]),
          ],
          properties: const {},
        ),
      ]),
      'road': PreparedSourceLayer(extent: 4096, features: [
        PreparedFeature(
          id: 2,
          type: PreparedGeomType.line,
          parts: [
            Float32List.fromList([0, 2048, 4096, 2048]),
          ],
          properties: const {},
        ),
      ]),
    },
    byteSize: 100,
  );
  return DisplayTileData(
      displayKey: const TileKey(2, 1, 1), sources: {'s': tile});
}

/// Three layers that draw, in an order the pixels show — the line is
/// translucent, so it blends with whatever lies under it — with a
/// symbol layer and a layer outside the zoom range between them, which
/// draw nothing here.
Theme _theme() => const ThemeReader().read({
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#0000ff'},
        },
        {
          'id': 'area',
          'type': 'fill',
          'source': 's',
          'source-layer': 'area',
          'paint': {'fill-color': '#ff0000'},
        },
        {
          'id': 'labels',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'area',
          'layout': {'text-field': 'x'},
        },
        {
          'id': 'later',
          'type': 'fill',
          'source': 's',
          'source-layer': 'area',
          'minzoom': 20,
          'paint': {'fill-color': '#ffffff'},
        },
        {
          'id': 'road',
          'type': 'line',
          'source': 's',
          'source-layer': 'road',
          'paint': {
            'line-color': '#00ff00',
            'line-width': 40,
            'line-opacity': 0.5,
          },
        },
      ],
    });

Future<Uint8List> _pixels(ui.Picture picture) async {
  final image = TileRasterizer.toImage(picture, 1);
  final data = await image.toByteData();
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one layer per slice stacks into the picture one recording makes',
      () async {
    final theme = _theme();
    final data = _tile();
    final whole = TileRasterizer.record(
        theme: theme, data: data, styleZoom: 2, devicePixelRatio: 1)!;

    final rasterized = TileRasterizer.debugRasterizeCount;
    final slices = TileRasterizer.debugSliceCount;
    final parts = <ui.Picture>[];
    var next = 0;
    while (next < theme.layers.length) {
      final slice = TileRasterizer.recordSlice(
        theme: theme,
        data: data,
        styleZoom: 2,
        devicePixelRatio: 1,
        from: next,
        // Out of time before the first layer: every slice still draws
        // one, so the recording always moves on.
        outOfBudget: () => true,
      );
      expect(slice.next, greaterThan(next));
      if (slice.picture case final picture?) parts.add(picture);
      next = slice.next;
    }

    // bg, area and road; the symbol and out-of-zoom layers get no slice
    // of their own.
    expect(TileRasterizer.debugSliceCount - slices, 3);
    expect(parts, hasLength(3));
    expect(TileRasterizer.debugRasterizeCount - rasterized, 1,
        reason: 'a sliced recording is still one tile rasterized');
    expect(await _pixels(TileRasterizer.compose(parts)!), await _pixels(whole));
  });

  test('records every layer in one slice while there is time', () {
    final theme = _theme();
    final slice = TileRasterizer.recordSlice(
      theme: theme,
      data: _tile(),
      styleZoom: 2,
      devicePixelRatio: 1,
      outOfBudget: () => false,
    );
    expect(slice.next, theme.layers.length);
    slice.picture!.dispose();
  });

  test(
      'a slice stops before the next layer that draws, not before one that does not',
      () {
    // Out of time after "area": what is left is a symbol layer, a layer
    // outside the zoom range, and "road". The slice stops before "road"
    // — not before the two that draw nothing, which would cost the
    // tile a frame for an empty slice.
    final theme = _theme();
    var calls = 0;
    final slice = TileRasterizer.recordSlice(
      theme: theme,
      data: _tile(),
      styleZoom: 2,
      devicePixelRatio: 1,
      outOfBudget: () => ++calls > 1,
    );
    expect(theme.layers[slice.next].id, 'road');
    slice.picture!.dispose();
  });

  test('compose returns a single part as it is, and nothing as null', () {
    expect(TileRasterizer.compose([]), isNull);
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = const Color(0xff000000));
    final part = recorder.endRecording();
    expect(identical(TileRasterizer.compose([part]), part), isTrue);
    part.dispose();
  });
}
