import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

/// A replay frame — between placement passes — sorts only the last
/// pass's winners instead of every candidate. These pin down that it
/// draws exactly what the pass decided, whatever order the candidate
/// list arrives in.

const _fadeDuration = Duration(milliseconds: 100);
final _t0 = DateTime(2026, 1, 1);
DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

(SymbolThemeLayer, SymbolThemeLayer) _layers() {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'street',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'road',
        'layout': {'text-field': '{name}'},
      },
      {
        'id': 'poi',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': {'text-field': '{name}'},
      },
    ],
  });
  return (
    theme.layers[0] as SymbolThemeLayer,
    theme.layers[1] as SymbolThemeLayer,
  );
}

SymbolInstance _instance(
  SymbolThemeLayer layer,
  int layerIndex,
  String text, {
  double sortKey = 0,
}) =>
    SymbolInstance(
      layer: layer,
      layerIndex: layerIndex,
      anchor: Offset.zero,
      angle: 0,
      alongLine: false,
      text: text,
      iconName: null,
      sortKey: sortKey,
      properties: const {},
      geometryType: 'Point',
      featureId: null,
    );

/// One candidate as the layer builds it each frame: a fresh
/// [PlacedSymbol] around a persistent instance, with its `order`.
typedef _Candidate = ({
  SymbolInstance instance,
  Offset anchor,
  int order,
  bool ghostOnly,
});

List<PlacedSymbol> _frame(
  LabelPainter painter,
  List<_Candidate> candidates, {
  required int generation,
  required DateTime now,
}) {
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: ui.Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: 14,
    symbols: [
      for (final c in candidates)
        PlacedSymbol(
          instance: c.instance,
          screenAnchor: c.anchor,
          screenAngle: 0,
          order: c.order,
          ghostOnly: c.ghostOnly,
        ),
    ],
    labelFadeDuration: _fadeDuration,
    placementGeneration: generation,
    now: now,
  );
  recorder.endRecording().dispose();
  return drawn;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final (street, poi) = _layers();

  test('replay frames draw what the pass placed, in the same order', () {
    // A crowded block: two layers, mixed sort keys, rows 12 px apart
    // under 16 px text, so neighbours collide and many candidates lose.
    final candidates = <_Candidate>[
      for (var i = 0; i < 36; i++)
        (
          instance: i.isEven
              ? _instance(poi, 1, 'P$i', sortKey: (i % 5).toDouble())
              : _instance(street, 0, 'S$i', sortKey: (i % 3).toDouble()),
          anchor: Offset(40.0 + (i % 6) * 55, 40.0 + (i ~/ 6) * 12),
          order: i,
          ghostOnly: i % 11 == 0,
        ),
    ];
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    final placed = _frame(painter, candidates, generation: 1, now: _t0);
    final contenders = candidates.where((c) => !c.ghostOnly).length;
    expect(placed.length, inInclusiveRange(2, contenders - 2),
        reason: 'the pass has both winners and losers');
    expect(placed.any((s) => s.ghostOnly), isFalse);

    final random = math.Random(7);
    // Mid-fade (all keys share one opacity bucket) and settled.
    for (final ms in [16, 40, 500]) {
      final scrambled = [...candidates]..shuffle(random);
      final replayed = _frame(painter, scrambled, generation: 1, now: _at(ms));
      expect(
        [for (final s in replayed) s.instance],
        [for (final s in placed) s.instance],
        reason: 'replay at $ms ms',
      );
    }
  });

  test('a replay frame keeps fading out a label that lost the last pass', () {
    final street1 = _instance(street, 0, 'Leopoldstraße');
    final poi1 = _instance(poi, 1, 'Siegestor');
    const anchor = Offset(200, 200);
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    final alone = <_Candidate>[
      (instance: street1, anchor: anchor, order: 0, ghostOnly: false),
    ];
    expect(_frame(painter, alone, generation: 1, now: _t0), hasLength(1));
    expect(_frame(painter, alone, generation: 1, now: _at(200)), hasLength(1),
        reason: 'faded in fully');

    // A higher layer arrives on top: the next pass evicts the street
    // name, which starts fading out behind the newcomer.
    final contested = <_Candidate>[
      (instance: poi1, anchor: anchor, order: 0, ghostOnly: false),
      (instance: street1, anchor: anchor, order: 1, ghostOnly: false),
    ];
    final pass = _frame(painter, contested, generation: 2, now: _at(220));
    expect(pass.map((s) => s.instance), containsAll([poi1, street1]),
        reason: 'the loser is drawn as a fading ghost');

    // The replay finds the ghost's drawable among the non-winners —
    // in either input order.
    for (final candidates in [contested, contested.reversed.toList()]) {
      final replay = _frame(painter, candidates, generation: 2, now: _at(240));
      expect(replay.map((s) => s.instance), containsAll([poi1, street1]));
    }
  });
}
