/// Verifies the mechanism behind "street names jump at a zoom crossing":
/// along-line anchors are parametrized per display-tile layout, so the
/// same street's label anchors land at *different world positions* at
/// zoom z and z+1 — while the label fade's continuity key is
/// position-free, so the fade tracker hands the label over at full
/// opacity. The result on screen is a hard jump (or a momentary
/// duplicate followed by a hard cut), never a cross-fade.
///
/// This is investigation evidence, not a regression gate: the numbers
/// quantify how far the anchors move for a plain straight street.
// ignore_for_file: implementation_imports
library;

import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

const _extent = 4096;

Theme _theme(Map<String, Object?> layout) => const ThemeReader().read({
      'layers': [
        {
          'id': 'label',
          'type': 'symbol',
          'source': 's',
          'source-layer': 'road',
          'layout': {'text-field': '{name}', 'text-size': 14, ...layout},
        },
      ],
    });

PreparedFeature _line(List<double> coords) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (var i = 0; i + 1 < coords.length; i += 2) {
    if (coords[i] < minX) minX = coords[i];
    if (coords[i] > maxX) maxX = coords[i];
    if (coords[i + 1] < minY) minY = coords[i + 1];
    if (coords[i + 1] > maxY) maxY = coords[i + 1];
  }
  return PreparedFeature(
    id: null,
    type: PreparedGeomType.line,
    parts: [Float32List.fromList(coords)],
    properties: const {'name': 'Hauptstraße'},
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
  );
}

PreparedFeature _point(double x, double y) => PreparedFeature(
      id: null,
      type: PreparedGeomType.point,
      parts: [
        Float32List.fromList([x, y])
      ],
      properties: const {'name': 'Museum'},
    );

PreparedTile _tile(TileKey key, PreparedFeature feature) => PreparedTile(
      key: key,
      layers: {
        'road': PreparedSourceLayer(extent: _extent, features: [feature]),
      },
      byteSize: 1024,
    );

/// Anchors of one display tile's layout, in world pixels at [atZoom].
List<Offset> _anchors(
  Theme theme,
  TileKey displayKey,
  PreparedTile data,
  double styleZoom,
  int atZoom,
) {
  final f = 1 << (atZoom - displayKey.z);
  return [
    for (final s in SymbolLayouter.layout(
      theme: theme,
      data: DisplayTileData(displayKey: displayKey, sources: {'s': data}),
      styleZoom: styleZoom,
    ))
      Offset(
        (displayKey.x * 256 + s.anchor.dx) * f,
        (displayKey.y * 256 + s.anchor.dy) * f,
      ),
  ];
}

double _nearest(Offset p, Iterable<Offset> candidates) {
  var best = double.infinity;
  for (final c in candidates) {
    final d = (c - p).distance;
    if (d < best) best = d;
  }
  return best;
}

void main() {
  test('along-line anchors move across a zoom crossing, same continuity key',
      () {
    final theme = _theme({'symbol-placement': 'line', 'symbol-spacing': 250});

    // One straight west-east street across the whole z16 tile, at a
    // quarter of the tile height (so it falls inside the northern z17
    // children rather than on their boundary).
    final z16Data = _tile(
      const TileKey(16, 0, 0),
      _line([0, 1024, _extent.toDouble(), 1024]),
    );
    // The same world street as z17 data tiles: each child carries its
    // half, in its own extent coordinates (what the decoder would see
    // for ideal per-zoom tiling of this geometry).
    final z17West = _tile(
      const TileKey(17, 0, 0),
      _line([0, 2048, _extent.toDouble(), 2048]),
    );
    final z17East = _tile(
      const TileKey(17, 1, 0),
      _line([0, 2048, _extent.toDouble(), 2048]),
    );

    // The outgoing level's instances and the arriving level's.
    final outgoing = SymbolLayouter.layout(
      theme: theme,
      data: DisplayTileData(
          displayKey: const TileKey(16, 0, 0), sources: {'s': z16Data}),
      styleZoom: 16,
    );
    final arrivingInstances = SymbolLayouter.layout(
      theme: theme,
      data: DisplayTileData(
          displayKey: const TileKey(17, 0, 0), sources: {'s': z17West}),
      styleZoom: 17,
    );
    expect(outgoing, isNotEmpty);
    expect(arrivingInstances, isNotEmpty);

    // The fade layer sees one and the same label on both levels…
    expect(outgoing.first.continuityKey,
        equals(arrivingInstances.first.continuityKey));

    // …but the anchors sit at different world positions. Distances in
    // world pixels at z17, which is screen pixels at the crossing.
    final outgoingAnchors =
        _anchors(theme, const TileKey(16, 0, 0), z16Data, 16, 17);
    final arriving = [
      ..._anchors(theme, const TileKey(17, 0, 0), z17West, 17, 17),
      ..._anchors(theme, const TileKey(17, 1, 0), z17East, 17, 17),
    ];
    final jumps = [
      for (final p in outgoingAnchors) _nearest(p, arriving),
    ];
    // ignore: avoid_print
    print('outgoing (z16 layout) anchors @z17 world px: $outgoingAnchors');
    // ignore: avoid_print
    print('arriving (z17 layout) anchors @z17 world px: $arriving');
    // ignore: avoid_print
    print('handoff jump per outgoing anchor: $jumps px');

    // A straight street with default symbol-spacing: the handoff moves
    // the label by a large fraction of the spacing — far beyond the
    // sub-pixel noise a position-aware match would absorb.
    expect(jumps, anyElement(greaterThan(50)));
  });

  test(
      'provisional overzoom layout of the SAME data also moves along-line '
      'anchors', () {
    final theme = _theme({'symbol-placement': 'line', 'symbol-spacing': 250});
    final z16Data = _tile(
      const TileKey(16, 0, 0),
      _line([0, 1024, _extent.toDouble(), 1024]),
    );

    // z16 display layout vs the provisional z17 display layout the layer
    // produces from the very same z16 data while the real z17 tiles load.
    final outgoing = _anchors(theme, const TileKey(16, 0, 0), z16Data, 16, 17);
    final provisional = [
      ..._anchors(theme, const TileKey(17, 0, 0), z16Data, 17, 17),
      ..._anchors(theme, const TileKey(17, 1, 0), z16Data, 17, 17),
    ];
    final jumps = [for (final p in outgoing) _nearest(p, provisional)];
    // ignore: avoid_print
    print('outgoing anchors @z17 world px: $outgoing');
    // ignore: avoid_print
    print('provisional anchors @z17 world px: $provisional');
    // ignore: avoid_print
    print('handoff jump per outgoing anchor: $jumps px');
    expect(jumps, anyElement(greaterThan(50)));
  });

  test('point-label anchors are world-stable across the same crossing', () {
    final theme = _theme(const {});
    // Same world point in the z16 tile and in its z17 child.
    final z16 = _tile(const TileKey(16, 0, 0), _point(1000, 1000));
    final z17 = _tile(const TileKey(17, 0, 0), _point(2000, 2000));

    final a = _anchors(theme, const TileKey(16, 0, 0), z16, 16, 17);
    final b = _anchors(theme, const TileKey(17, 0, 0), z17, 17, 17);
    expect(a, hasLength(1));
    expect(b, hasLength(1));
    expect((a.first - b.first).distance, lessThan(0.5));
  });
}
