import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/label_ids.dart';

/// A placement pass spread over frames (`placementOutOfBudget`): it
/// decides what a whole pass decides, from the frame it started in, and
/// nothing of that decision reaches the screen before the frame it
/// finishes in — the frames in between replay the decision before it.

const _fadeDuration = Duration(milliseconds: 100);
final _t0 = DateTime(2026, 1, 1);
DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

SymbolThemeLayer _layer({List<String>? variableAnchor}) {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'poi',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'poi',
        'layout': {
          'text-field': '{name}',
          'text-size': 14,
          if (variableAnchor != null) 'text-variable-anchor': variableAnchor,
          if (variableAnchor != null) 'text-radial-offset': 0.5,
        },
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

SymbolInstance _instance(SymbolThemeLayer layer, String text,
        {int layerIndex = 0, double sortKey = 0}) =>
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

/// One candidate as the layer offers it: a persistent instance at a
/// screen position.
typedef _Candidate = (SymbolInstance, Offset);

/// One painted frame. [perSlice] candidates are placed per frame; null
/// places a whole pass in the frame it starts in.
List<SymbolInstance> _frame(
  LabelPainter painter,
  List<_Candidate> candidates, {
  required int generation,
  required DateTime now,
  int? perSlice,
  Size screenSize = const Size(400, 400),
}) {
  var checks = 0;
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: ui.Canvas(recorder),
    screenSize: screenSize,
    styleZoom: 14,
    symbols: [
      for (var i = 0; i < candidates.length; i++)
        PlacedSymbol(
          instance: candidates[i].$1,
          // One label per text: a republished copy of a label, a new
          // instance with the same text, keeps its id.
          id: labelIdOf(candidates[i].$1.text),
          screenAnchor: candidates[i].$2,
          screenAngle: 0,
          order: i,
        ),
    ],
    labelFadeDuration: _fadeDuration,
    placementGeneration: generation,
    now: now,
    placementOutOfBudget: perSlice == null ? null : () => ++checks >= perSlice,
  );
  recorder.endRecording().dispose();
  return [for (final symbol in drawn) symbol.instance];
}

/// A crowded block: rows 12 px apart under 14 px text, so neighbours
/// collide and many candidates lose; sort keys mixed.
List<_Candidate> _crowd(SymbolThemeLayer layer) => [
      for (var i = 0; i < 36; i++)
        (
          _instance(layer, 'L$i', sortKey: (i % 5).toDouble()),
          Offset(40.0 + (i % 6) * 55, 40.0 + (i ~/ 6) * 12),
        ),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => LabelPainter.debugDrawnProbe = null);

  test('a pass spread over frames places what a whole pass places', () {
    final layer = _layer();
    final crowd = _crowd(layer);
    final whole = LabelPainter();
    final sliced = LabelPainter();
    addTearDown(whole.dispose);
    addTearDown(sliced.dispose);

    final expected = _frame(whole, crowd, generation: 1, now: _t0);
    expect(expected.length, inInclusiveRange(2, crowd.length - 2),
        reason: 'the pass has both winners and losers');

    var frames = 0;
    List<SymbolInstance> drawn;
    do {
      drawn = _frame(sliced, crowd,
          generation: 1, now: _at(16 * frames), perSlice: 4);
      frames++;
      if (sliced.placementPending) {
        expect(drawn, isEmpty,
            reason: 'nothing was placed before, so nothing shows until '
                'the pass finishes (frame $frames)');
      }
    } while (sliced.placementPending && frames < 100);
    expect(frames, crowd.length ~/ 4, reason: 'four candidates a frame');
    expect(drawn, expected);
  });

  test('frames while a pass is in flight replay the decision before it', () {
    final layer = _layer();
    final crowd = _crowd(layer);
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    final before = _frame(painter, crowd, generation: 1, now: _t0);
    final evicted = before.first;
    final evictedAt = crowd.firstWhere((c) => c.$1 == evicted).$2;
    // A higher layer arrives on top of a label that is on screen: the
    // next pass gives it the space.
    final arrival = _instance(layer, 'Arrival', layerIndex: 1);
    final next = [...crowd, (arrival, evictedAt)];

    final opacities = <int, double>{};
    LabelPainter.debugDrawnProbe = (_, drawn) {
      opacities.clear();
      for (final label in drawn) {
        if (!label.ghost) opacities[label.id] = label.opacity;
      }
    };
    var frames = 0;
    List<SymbolInstance> drawn;
    for (;;) {
      drawn = _frame(painter, next,
          generation: 2, now: _at(200 + 16 * frames), perSlice: 1);
      frames++;
      if (!painter.placementPending) break;
      expect(drawn, before, reason: 'frame $frames is in flight');
      expect(opacities[labelIdOf(evicted.text)], 1,
          reason: 'only the pass that drops a label starts its fade-out');
    }
    expect(frames, next.length, reason: 'one candidate a frame');
    expect(drawn, contains(arrival));
    expect(opacities.containsKey(labelIdOf(evicted.text)), isFalse,
        reason: 'the evicted label is only a fade-out ghost from the '
            'commit on');
  });

  test('labels republished while a pass is in flight keep drawing', () {
    // Tiles republish constantly during a gesture, replacing every
    // instance under labels that never left the screen. A decision kept
    // by instance would lose its winners before the pass that replaces
    // it commits — the frames in flight drew about half the labels when
    // this was tried with instances. Kept by label id, nothing changes.
    final layer = _layer();
    final crowd = _crowd(layer);
    final painter = LabelPainter();
    addTearDown(painter.dispose);
    Set<String> texts(List<SymbolInstance> drawn) =>
        {for (final instance in drawn) instance.text};

    final before = texts(_frame(painter, crowd, generation: 1, now: _t0));
    var current = crowd;
    var frames = 0;
    for (;;) {
      if (frames.isOdd) {
        // A republish: the same labels, laid out anew.
        current = [
          for (final (instance, at) in current)
            (_instance(layer, instance.text, sortKey: instance.sortKey), at),
        ];
      }
      final drawn = _frame(painter, current,
          generation: 2 + frames, now: _at(200 + 16 * frames), perSlice: 4);
      frames++;
      expect(texts(drawn), before, reason: 'frame $frames');
      expect(drawn.every((d) => current.any((c) => identical(c.$1, d))), isTrue,
          reason: 'drawn from the current copies');
      if (!painter.placementPending) break;
      if (frames > 50) fail('the pass never finished');
    }
    expect(frames, greaterThan(2), reason: 'the pass spanned republishes');
  });

  test('a pass that spans frames draws the copies it placed from', () {
    // Two copies of one label, 40 px apart (seam twins). The label is
    // drawn from the upper one until a higher layer takes that spot:
    // the pass places the label from the lower copy, and the frame it
    // commits in must draw that copy, not the one drawn before it.
    final layer = _layer();
    final upper = _instance(layer, 'Twin');
    final lower = _instance(layer, 'Twin');
    final blocker = _instance(layer, 'Blocker', layerIndex: 1);
    final painter = LabelPainter();
    addTearDown(painter.dispose);
    const upperAt = Offset(200, 200);
    const lowerAt = Offset(200, 240);

    final before = _frame(painter, [(upper, upperAt), (lower, lowerAt)],
        generation: 1, now: _t0);
    expect(before, [upper], reason: 'the first copy in priority order');

    final next = [(blocker, upperAt), (upper, upperAt), (lower, lowerAt)];
    var frames = 0;
    List<SymbolInstance> drawn;
    for (;;) {
      drawn = _frame(painter, next,
          generation: 2, now: _at(200 + 16 * frames), perSlice: 1);
      frames++;
      if (!painter.placementPending) break;
      expect(drawn, [upper], reason: 'frame $frames is in flight');
    }
    expect(frames, greaterThan(1), reason: 'the pass spanned frames');
    expect(drawn, unorderedEquals([blocker, lower]));
  });

  test('choices a pass makes in flight stay out of the frames it spans', () {
    final layer = _layer(variableAnchor: ['top', 'bottom']);
    final alpha = _instance(layer, 'Alpha');
    final painter = LabelPainter();
    addTearDown(painter.dispose);
    String? anchor() =>
        painter.debugPlacement.lookup(labelIdOf(alpha.text))?.anchor;

    const here = Offset(200, 200);
    _frame(painter, [(alpha, here)], generation: 1, now: _t0);
    expect(anchor(), 'top', reason: 'the style order');

    // A higher layer takes the top anchor; the pass moves Alpha to the
    // bottom one. Lower-priority fillers far away keep the pass going
    // after Alpha is decided.
    final next = <_Candidate>[
      (_instance(layer, 'Beta', layerIndex: 1), const Offset(200, 190)),
      (alpha, here),
      for (var i = 0; i < 4; i++)
        (_instance(layer, 'F$i', sortKey: 1), Offset(40, 300.0 + 20 * i)),
    ];
    var frames = 0;
    for (;;) {
      _frame(painter, next,
          generation: 2, now: _at(200 + 16 * frames), perSlice: 1);
      frames++;
      if (!painter.placementPending) break;
      expect(anchor(), 'top', reason: 'frame $frames is in flight');
    }
    expect(frames, next.length);
    expect(anchor(), 'bottom', reason: 'the pass has committed');
  });

  test('a pass that spans frames commits at the camera they moved to', () {
    // Panning 20 px a frame: by the commit Alpha is drawn 80 px from
    // where the pass saw it. The choice belongs to the label, wherever
    // it is drawn now.
    final layer = _layer(variableAnchor: ['top', 'bottom']);
    final alpha = _instance(layer, 'Alpha');
    final beta = _instance(layer, 'Beta', layerIndex: 1);
    final fillers = [for (var i = 0; i < 2; i++) _instance(layer, 'F$i')];
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    List<_Candidate> at(double dx, {bool withBeta = true}) => [
          if (withBeta) (beta, Offset(100 + dx, 190)),
          (alpha, Offset(100 + dx, 200)),
          for (var i = 0; i < fillers.length; i++)
            (fillers[i], Offset(30 + dx, 320.0 + 20 * i)),
        ];
    _frame(painter, at(0, withBeta: false), generation: 1, now: _t0);

    var frames = 0;
    for (;;) {
      final dx = 20.0 * frames;
      _frame(painter, at(dx),
          generation: 2 + frames, now: _at(200 + 16 * frames), perSlice: 1);
      frames++;
      if (!painter.placementPending) break;
      if (frames > 10) fail('the pass never finished');
    }
    expect(
        painter.debugPlacement.lookup(labelIdOf(alpha.text))?.anchor, 'bottom');
  });

  test('a resize drops the pass in flight and starts over', () {
    final layer = _layer();
    final crowd = _crowd(layer).take(10).toList();
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    _frame(painter, crowd, generation: 1, now: _t0, perSlice: 1);
    _frame(painter, crowd, generation: 1, now: _at(16), perSlice: 1);
    expect(painter.placementPending, isTrue, reason: 'a pass is in flight');

    var frames = 0;
    do {
      _frame(painter, crowd,
          generation: 1,
          now: _at(32 + 16 * frames),
          perSlice: 1,
          screenSize: const Size(300, 400));
      frames++;
    } while (painter.placementPending && frames < 100);
    expect(frames, crowd.length,
        reason: 'the new screen size placed every candidate afresh');
  });

  test('reset drops the pass in flight', () {
    final layer = _layer();
    final painter = LabelPainter();
    addTearDown(painter.dispose);

    _frame(painter, _crowd(layer), generation: 1, now: _t0, perSlice: 1);
    expect(painter.placementPending, isTrue);
    painter.reset();
    expect(painter.placementPending, isFalse);
  });
}
