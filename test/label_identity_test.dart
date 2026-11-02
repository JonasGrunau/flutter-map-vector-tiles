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
  // Every case runs both ways a name's labels are searched: scanned
  // (rare names, the common case) and looked up by position (names with
  // hundreds of labels, see LabelIdentityIndex.gridFrom). Both must
  // match exactly the same.
  for (final (way, newIndex) in [
    ('scanning names', LabelIdentityIndex.new),
    ('looking names up by position', () => LabelIdentityIndex(gridFrom: 0)),
  ]) {
    group(way, () => _cases(newIndex));
  }

  group('a common name', () {
    // Hundreds of icon-only labels share one key (an empty text): a
    // one-way arrow every few pixels. Laid out on a jittered lattice,
    // republished jittered again, carried across a zoom crossing and
    // across a seam, scanning and looking up by position must hand out
    // the same ids, every one.
    const tile = TileKey(14, 8000, 5000);
    List<SymbolInstance> lattice(double shift, {int step = 9}) => [
          for (var y = 4; y < 252; y += step)
            for (var x = 4; x < 252; x += step)
              _label(
                Offset(x + shift * ((x * 7 + y * 3) % 5 - 2),
                    y + shift * ((x * 3 + y * 7) % 5 - 2)),
                text: '',
              ),
        ];
    // The parent's labels as child tile [child] lays them out: its
    // quarter, a pixel of buffer, and every anchor 2 px off.
    List<SymbolInstance> child(TileKey child, List<SymbolInstance> parent) {
      final origin = Offset(
          (child.x - tile.x * 2) * 256.0, (child.y - tile.y * 2) * 256.0);
      return [
        for (final s in parent)
          if (s.anchor * 2 - origin case final at
              when at.dx >= -1 && at.dx <= 257 && at.dy >= -1 && at.dy <= 257)
            _label(at + const Offset(1.5, -1.5), text: ''),
      ];
    }

    test('scanning and looking up agree on every id', () {
      final scan = LabelIdentityIndex(gridFrom: 1 << 30);
      final grid = LabelIdentityIndex();
      final first = lattice(0);
      expect(first.length, greaterThan(500));
      final runs = <List<Int32List>>[];
      for (final index in [scan, grid]) {
        final ids = <Int32List>[];
        var held = index.assign(tile, first);
        ids.add(held);
        held = index.assign(tile, lattice(1.5), replacing: held);
        ids.add(held);
        final children = [
          for (final (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)])
            TileKey(15, tile.x * 2 + dx, tile.y * 2 + dy),
        ];
        final childIds = [
          for (final c in children) index.assign(c, child(c, lattice(1.5))),
        ];
        ids.addAll(childIds);
        // The neighbour's copies of the labels on the seam.
        const east = TileKey(14, 8001, 5000);
        ids.add(index.assign(east, [
          for (final s in lattice(1.5))
            if (s.anchor.dx > 240)
              _label(s.anchor - const Offset(256, 0), text: ''),
        ]));
        index.release(tile, held);
        for (var i = 0; i < children.length; i++) {
          index.release(children[i], childIds[i]);
        }
        index.release(east, ids.last);
        expect(index.length, 0, reason: 'everything handed back');
        runs.add(ids);
      }
      for (var i = 0; i < runs[0].length; i++) {
        expect(runs[1][i], runs[0][i], reason: 'publish $i');
      }
      // And the lookup did its job: the republish kept every id, the
      // crossing found most of them.
      expect(runs[1][1], runs[1][0]);
      final parent = runs[1][1].toSet();
      final crossed = [for (final c in runs[1].sublist(2, 6)) ...c];
      expect(crossed.where(parent.contains).length,
          greaterThan(crossed.length * 0.9));
    });
  });
}

void _cases(LabelIdentityIndex Function() newIndex) {
  const tile = TileKey(14, 8000, 5000);
  const east = TileKey(14, 8001, 5000);

  group('a republished tile', () {
    test('keeps every id, and holds nothing twice', () {
      final index = newIndex();
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
      final index = newIndex();
      final first = index.assign(tile, [_label(const Offset(40, 40))]);
      final moved =
          index.assign(tile, [_label(const Offset(40, 80))], replacing: first);
      expect(moved.single, isNot(first.single));
      expect(index.length, 1, reason: 'the label that left was forgotten');
    });

    test('prefers its own previous ids over a neighbour twin', () {
      // The label on screen came from this tile; if the neighbour's copy
      // took over its id instead, the label would fade out and back in.
      final index = newIndex();
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
      final index = newIndex();
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
      final index = newIndex();
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
      final index = newIndex();
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
      final index = newIndex();
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
      final index = newIndex();
      final west = index.assign(tile, [_label(const Offset(252, 100))]);
      final eastIds = index.assign(east, [_label(const Offset(3, 100))]);
      expect(eastIds.single, isNot(west.single));
    });
  });

  group('one tile', () {
    test('never gives two of its labels one id', () {
      final index = newIndex();
      final ids = index.assign(tile, [
        _label(const Offset(100, 100)),
        _label(const Offset(110, 100)),
      ]);
      expect(ids[0], isNot(ids[1]));
    });

    test('matches each of its labels to the nearest predecessor', () {
      final index = newIndex();
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
      final index = newIndex();
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
      final index = newIndex();
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
      final index = newIndex();
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
      final index = newIndex();
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
      final index = newIndex();
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
      final index = newIndex();
      final parked = index.assign(tile, [_label(const Offset(50, 50))]);
      final current = index.assign(tile, [_label(const Offset(50.3, 50))]);
      expect(current, parked);
      index.release(tile, parked);
      expect(index.length, 1, reason: 'the current tile still holds it');
    });

    test('releasing an empty or unknown holding is harmless', () {
      final index = newIndex();
      final ids = index.assign(tile, [_label(const Offset(50, 50))]);
      index.release(east, ids);
      index.release(tile, Int32List(0));
      expect(index.length, 1);
      expect(index.assign(tile, const []), isEmpty);
    });

    test('clear forgets everything', () {
      final index = newIndex();
      index.assign(tile, [_label(const Offset(50, 50))]);
      index.clear();
      expect(index.length, 0);
    });
  });
}
