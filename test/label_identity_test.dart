import 'dart:typed_data';

import 'package:flutter_map_vector_tiles/src/core/tile_key.dart';
import 'package:flutter_map_vector_tiles/src/pipeline/prepared_tile.dart';
import 'package:flutter_map_vector_tiles/src/render/display_tile_data.dart';
import 'package:flutter_map_vector_tiles/src/render/label_identity.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

const _extent = 4096;

final _theme = const ThemeReader().read({
  'layers': [
    {
      'id': 'poi',
      'type': 'symbol',
      'source': 's',
      'source-layer': 'poi',
      'layout': {'text-field': '{name}'},
    },
    {
      'id': 'street',
      'type': 'symbol',
      'source': 's',
      'source-layer': 'road',
      'layout': {
        'text-field': '{name}',
        'symbol-placement': 'line',
        'symbol-spacing': 100,
      },
    },
  ],
});
final _poi = _theme.layers[0] as SymbolThemeLayer;

/// A point label at [anchor], in the logical coordinates of the display
/// tile it is laid out for (0..256).
SymbolInstance _label(Offset anchor, {String text = 'Bäckerei'}) =>
    SymbolInstance(
      layer: _poi,
      layerIndex: 0,
      anchor: anchor,
      angle: 0,
      alongLine: false,
      text: text,
      iconName: null,
      sortKey: 0,
      properties: const {},
      geometryType: 'Point',
      featureId: null,
    );

/// The layouter's candidates for display tile [display], cut from one
/// data tile [data] holding [features] in [sourceLayer].
List<SymbolInstance> _layout(
  TileKey display,
  TileKey data,
  String sourceLayer,
  List<PreparedFeature> features,
) =>
    SymbolLayouter.layout(
      theme: _theme,
      data: DisplayTileData(
        displayKey: display,
        sources: {
          's': PreparedTile(
            key: data,
            layers: {
              sourceLayer:
                  PreparedSourceLayer(extent: _extent, features: features),
            },
            byteSize: 0,
          ),
        },
        rasters: const {},
      ),
      styleZoom: display.z.toDouble(),
    );

PreparedFeature _line(List<double> coords, String name) {
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
    properties: {'name': name},
    minX: minX,
    minY: minY,
    maxX: maxX,
    maxY: maxY,
  );
}

PreparedFeature _point(double x, double y, String name) => PreparedFeature(
      id: null,
      type: PreparedGeomType.point,
      parts: [
        Float32List.fromList([x, y])
      ],
      properties: {'name': name},
      minX: x,
      minY: y,
      maxX: x,
      maxY: y,
    );

/// World position of [symbol] laid out for [tile], in level-[z] pixels.
Offset _world(TileKey tile, SymbolInstance symbol, int z) {
  final scale = 1 << (z - tile.z);
  return Offset((tile.x * 256 + symbol.anchor.dx) * scale,
      (tile.y * 256 + symbol.anchor.dy) * scale);
}

void main() {
  const tile = TileKey(14, 8000, 5000);
  const east = TileKey(14, 8001, 5000);

  group('a republished tile', () {
    test('keeps every id, and holds nothing twice', () {
      final index = LabelIdentityIndex();
      final first = index.assign(tile, [
        _label(const Offset(40, 40)),
        _label(const Offset(200, 120), text: 'Post'),
      ]);
      // Provisional → final: brand-new instances of the same labels, a
      // little simplification noise apart.
      final second = index.assign(
        tile,
        [
          _label(const Offset(40.6, 39.7)),
          _label(const Offset(201, 120), text: 'Post'),
        ],
        replacing: first,
      );
      expect(second, first);
      expect(index.length, 2, reason: 'the old holding was handed back');
    });

    test('gives a label that moved too far a new id', () {
      // A re-spaced street name, or a centroid the next data clips
      // elsewhere: it cross-fades from the old spot to the new one.
      final index = LabelIdentityIndex();
      final first = index.assign(tile, [_label(const Offset(40, 40))]);
      final moved =
          index.assign(tile, [_label(const Offset(40, 80))], replacing: first);
      expect(moved.single, isNot(first.single));
      expect(index.length, 1, reason: 'the label that left was forgotten');
    });

    test('prefers its own previous ids over a neighbour twin', () {
      // The label on screen came from this tile; if the neighbour's copy
      // took over its id instead, the label would fade out and back in.
      final index = LabelIdentityIndex();
      final own = index.assign(tile, [_label(const Offset(254, 100))]);
      // The neighbour, still provisional, lays the seam label out two
      // pixels off: no twin, so an id of its own.
      final neighbour = index.assign(east, [_label(const Offset(0.2, 100))]);
      expect(neighbour.single, isNot(own.single));
      // Republished, this tile's copy lands nearer the neighbour's (0.4
      // px, a twin) than its own previous one (1.8 px).
      final republished = index.assign(tile, [_label(const Offset(255.8, 100))],
          replacing: own);
      expect(republished, own);
    });
  });

  group('a zoom crossing', () {
    test('a point label keeps its id across levels, both ways', () {
      final index = LabelIdentityIndex();
      const parent = TileKey(14, 8000, 5000);
      const child = TileKey(15, 16001, 10000);
      // The same world point: (8000·256 + 200, …) at z14 is
      // (16001·256 + 144, …) at z15.
      final atParent = index.assign(parent, [_label(const Offset(200, 50))]);
      final atChild = index.assign(child, [_label(const Offset(144, 100))]);
      expect(atChild, atParent);
      // And back out: the parent level republished while the child
      // still offers the label.
      final back = index.assign(parent, [_label(const Offset(200.2, 50.1))],
          replacing: atParent);
      expect(back, atParent);
    });

    test('nested along-line anchors keep their ids at the next level', () {
      // Over the same data, level z+1's anchors are a superset of level
      // z's (`SymbolLayouter._placeAlongLine`), so every street name on
      // screen keeps its id across the crossing and the level only adds
      // new ones between them.
      const data = TileKey(14, 8000, 5000);
      final road = _line([200, 1800, 3900, 2100], 'Leopoldstraße');
      final index = LabelIdentityIndex();
      final coarse = _layout(data, data, 'road', [road]);
      final coarseIds = index.assign(data, coarse);
      expect(coarse, hasLength(greaterThan(1)));

      final children = [
        for (final dy in [0, 1])
          for (final dx in [0, 1]) TileKey(15, 16000 + dx, 10000 + dy),
      ];
      final fineById = <int, List<Offset>>{};
      for (final child in children) {
        final fine = _layout(child, data, 'road', [road]);
        final ids = index.assign(child, fine);
        for (var i = 0; i < fine.length; i++) {
          (fineById[ids[i]] ??= []).add(_world(child, fine[i], 15));
        }
      }
      for (var i = 0; i < coarse.length; i++) {
        final positions = fineById[coarseIds[i]];
        expect(positions, isNotNull,
            reason: 'anchor $i of the coarse level has a successor');
        for (final p in positions!) {
          expect((p - _world(data, coarse[i], 15)).distance, lessThan(0.01),
              reason: 'at the same place');
        }
      }
      expect(fineById.length, greaterThan(coarse.length),
          reason: 'the finer level adds anchors between them');
    });

    test('a coarser level matches at the finer level\'s tolerance', () {
      // 32 px at z15 is 16 px at z14: a label 20 z14-pixels off is a
      // different one, though it would be close enough between two z14
      // layouts.
      final index = LabelIdentityIndex();
      const child = TileKey(15, 16000, 10000);
      final fine = index.assign(child, [_label(const Offset(100, 100))]);
      final coarse = index.assign(tile, [_label(const Offset(70, 50))]);
      expect(coarse.single, isNot(fine.single));
    });
  });

  group('a seam', () {
    test('both neighbours\' copies of a seam label share its id', () {
      // The layouter lets both tiles claim a feature on their shared
      // edge (rather than risk neither doing so).
      const data = TileKey(14, 8000, 5000);
      final index = LabelIdentityIndex();
      final seam = _point(2048, 2048, 'Marienplatz');
      const west = TileKey(15, 16000, 10000);
      const eastChild = TileKey(15, 16001, 10000);
      final westLabels = _layout(west, data, 'poi', [seam]);
      final eastLabels = _layout(eastChild, data, 'poi', [seam]);
      expect(westLabels, hasLength(1));
      expect(eastLabels, hasLength(1));
      final westIds = index.assign(west, westLabels);
      final eastIds = index.assign(eastChild, eastLabels);
      expect(eastIds, westIds);

      // Either tile can go first without the label losing its id.
      index.release(west, westIds);
      expect(index.length, 1, reason: 'the east copy still holds it');
      final again = index.assign(west, _layout(west, data, 'poi', [seam]));
      expect(again, westIds);
    });

    test('two labels of one name on either side stay two labels', () {
      // Two bakeries a few pixels apart across a tile edge are not
      // twins: sharing an id, only one of them could ever draw.
      final index = LabelIdentityIndex();
      final west = index.assign(tile, [_label(const Offset(252, 100))]);
      final eastIds = index.assign(east, [_label(const Offset(3, 100))]);
      expect(eastIds.single, isNot(west.single));
    });
  });

  group('one tile', () {
    test('never gives two of its labels one id', () {
      final index = LabelIdentityIndex();
      final ids = index.assign(tile, [
        _label(const Offset(100, 100)),
        _label(const Offset(110, 100)),
      ]);
      expect(ids[0], isNot(ids[1]));
    });

    test('matches each of its labels to the nearest predecessor', () {
      final index = LabelIdentityIndex();
      final first = index.assign(tile, [
        _label(const Offset(100, 100)),
        _label(const Offset(120, 100)),
      ]);
      final second = index.assign(
          tile,
          [
            _label(const Offset(119, 100)),
            _label(const Offset(101, 100)),
          ],
          replacing: first);
      expect(second, [first[1], first[0]]);
    });

    test('separates names, layers and icons', () {
      final index = LabelIdentityIndex();
      final ids = index.assign(tile, [
        _label(const Offset(100, 100)),
        _label(const Offset(100, 100), text: 'Post'),
      ]);
      expect(ids[0], isNot(ids[1]));
    });
  });

  group('the twin rule', () {
    // Judged against each same-level holder's own copy, never against
    // whichever copy happens to have registered last.
    const a = TileKey(15, 16000, 10000);
    const b = TileKey(15, 16001, 10000);
    // A z16 tile over the a/b seam's east side.
    const child = TileKey(16, 32002, 20000);

    test('a neighbour\'s different label stays apart', () {
      final index = LabelIdentityIndex();
      final cafe = index.assign(a, [_label(const Offset(254, 100))]);
      // The next level's copy, 5 z15-pixels off (z16 (6, 200) is z15
      // world 16001·256 + 3, i.e. a-local 259).
      final copy = index.assign(child, [_label(const Offset(6, 200))]);
      expect(copy, cafe);
      // A different café on b, 5.4 px from a's: next to the other
      // level's copy, but no twin of the one a holds.
      final other = index.assign(b, [_label(const Offset(3.4, 100))]);
      expect(other.single, isNot(cafe.single));
    });

    test('a true seam twin joins, however far another level\'s copy is', () {
      final index = LabelIdentityIndex();
      final cafe = index.assign(a, [_label(const Offset(255.9, 100))]);
      final copy = index.assign(child, [_label(const Offset(9.8, 200))]);
      expect(copy, cafe);
      final twin = index.assign(b, [_label(const Offset(-0.1, 100))]);
      expect(twin, cafe);
    });
  });

  group('nearest first', () {
    test('a label keeps its nearest predecessor whatever the order', () {
      // Greedy matching in layout order let the first symbol take the
      // label 18 px away, leaving the one 2 px from it a fresh id.
      final index = LabelIdentityIndex();
      final before = index.assign(tile, [
        _label(const Offset(100, 100)),
        _label(const Offset(140, 100)),
      ]);
      final after = index.assign(
          tile,
          [
            _label(const Offset(118, 100)),
            _label(const Offset(98, 100)),
          ],
          replacing: before);
      expect(after, [before[1], before[0]]);
    });
  });

  group('holders', () {
    test('a label lives as long as anything offers it', () {
      final index = LabelIdentityIndex();
      const child = TileKey(15, 16000, 10000);
      final coarse = index.assign(tile, [_label(const Offset(50, 50))]);
      final fine = index.assign(child, [_label(const Offset(100, 100))]);
      expect(fine, coarse);
      index.release(tile, coarse);
      expect(index.length, 1);
      index.release(child, fine);
      expect(index.length, 0);
      // Gone for good: the next sighting is a new label.
      expect(index.assign(tile, [_label(const Offset(50, 50))]).single,
          isNot(coarse.single));
    });

    test('a parked cohort hands its ids over and back', () {
      // A retained tile disposed while its labels fade: the parked
      // cohort holds the same ids under the same tile key, and a tile
      // of that key arriving again (zooming back) resumes them.
      final index = LabelIdentityIndex();
      final parked = index.assign(tile, [_label(const Offset(50, 50))]);
      final current = index.assign(tile, [_label(const Offset(50.3, 50))]);
      expect(current, parked);
      index.release(tile, parked);
      expect(index.length, 1, reason: 'the current tile still holds it');
    });

    test('releasing an empty or unknown holding is harmless', () {
      final index = LabelIdentityIndex();
      final ids = index.assign(tile, [_label(const Offset(50, 50))]);
      index.release(east, ids);
      index.release(tile, Int32List(0));
      expect(index.length, 1);
      expect(index.assign(tile, const []), isEmpty);
    });

    test('clear forgets everything', () {
      final index = LabelIdentityIndex();
      index.assign(tile, [_label(const Offset(50, 50))]);
      index.clear();
      expect(index.length, 0);
    });
  });
}
