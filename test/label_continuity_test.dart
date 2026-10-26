import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter_map_vector_tiles/src/render/label_continuity.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/label_ids.dart';

SymbolThemeLayer _layer() {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'place',
        'type': 'symbol',
        'source': 's',
        'source-layer': 'place',
        'layout': {'text-field': '{name}'},
      },
    ],
  });
  return theme.layers.single as SymbolThemeLayer;
}

SymbolInstance _symbol(
  SymbolThemeLayer layer, {
  String text = 'Feldkirchen',
  String? iconName,
  int layerIndex = 0,
  Offset anchor = Offset.zero,
  bool alongLine = false,
}) =>
    SymbolInstance(
      layer: layer,
      layerIndex: layerIndex,
      anchor: anchor,
      angle: 0,
      alongLine: alongLine,
      text: text,
      iconName: iconName,
      sortKey: 0,
      properties: const {},
      geometryType: alongLine ? 'LineString' : 'Point',
      featureId: null,
    );

/// An instance projected to screen space, as the label pass sees it.
/// Every instance is its own label unless [id] says otherwise — pass
/// the id of the instance it succeeds (or twins) to model what
/// `LabelIdentityIndex` matches.
PlacedSymbol _placedAt(
  SymbolInstance instance, {
  Offset anchor = const Offset(200, 200),
  int order = 0,
  bool ghostOnly = false,
  int? id,
}) =>
    PlacedSymbol(
      instance: instance,
      id: id ?? labelIdOf(instance),
      screenAnchor: anchor,
      screenAngle: 0,
      order: order,
      ghostOnly: ghostOnly,
    );

/// One label pass with fades disabled — for stories about placement
/// alone, where fade state would only be noise.
List<PlacedSymbol> _paint(List<PlacedSymbol> symbols, {double styleZoom = 14}) {
  final painter = LabelPainter();
  final drawn = _frame(painter, symbols, styleZoom: styleZoom);
  painter.dispose();
  return drawn;
}

/// One label pass on a persistent [painter] — for stories that follow
/// fade state across frames. A non-null [now] enables the per-label
/// fades at [_fadeDuration], and with them the throttled placement:
/// frames closer together than that replay the last decision — a
/// swapped candidate set included, which is only picked up by the next
/// due pass (a publish no longer forces an immediate one). Each call
/// models changed placement input by default; pass the same explicit
/// [placementGeneration] to model ticker-only repaints of an idle map.
List<PlacedSymbol> _frame(
  LabelPainter painter,
  List<PlacedSymbol> symbols, {
  double styleZoom = 14,
  DateTime? now,
  Duration? labelFadeDuration,
  int? placementGeneration,
}) {
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: ui.Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: styleZoom,
    symbols: symbols,
    labelFadeDuration:
        labelFadeDuration ?? (now == null ? Duration.zero : _fadeDuration),
    placementGeneration: placementGeneration ?? _nextPlacementGeneration++,
    now: now,
  );
  recorder.endRecording().dispose();
  return drawn;
}

var _nextPlacementGeneration = 0;

const _fadeDuration = Duration(milliseconds: 100);
final _t0 = DateTime(2026, 1, 1);
DateTime _at(int ms) => _t0.add(Duration(milliseconds: ms));

/// A street-name layer under a POI layer that only exists from zoom 13
/// up — the shape of the pre-transition flash: the POI suppresses the
/// street name until a zoom-out cuts the POI layer at its minzoom.
(SymbolThemeLayer, SymbolThemeLayer) _streetAndPoiLayers() {
  final theme = const ThemeReader().read({
    'layers': [
      {
        'id': 'street-name',
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
        'minzoom': 13,
        'layout': {'text-field': '{name}'},
      },
    ],
  });
  return (
    theme.layers[0] as SymbolThemeLayer,
    theme.layers[1] as SymbolThemeLayer,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final layer = _layer();

  group('labelContinuityKey', () {
    test('ignores the anchor', () {
      // The whole point: the same feature is simplified differently at
      // two zoom levels, so its anchor lands a fraction of a pixel apart
      // and a position-sensitive key would miss the match.
      expect(
        labelContinuityKey(_symbol(layer, anchor: const Offset(10, 10))),
        labelContinuityKey(_symbol(layer, anchor: const Offset(10.4, 9.7))),
      );
    });

    test('separates different text, layers and icons', () {
      final base = labelContinuityKey(_symbol(layer));
      expect(base, isNot(labelContinuityKey(_symbol(layer, text: 'Aschheim'))));
      expect(base, isNot(labelContinuityKey(_symbol(layer, layerIndex: 3))));
      expect(
        labelContinuityKey(_symbol(layer, text: '', iconName: 'cafe')),
        isNot(labelContinuityKey(_symbol(layer, text: '', iconName: 'bar'))),
      );
    });

    test('matches icon-only symbols on their icon', () {
      expect(
        labelContinuityKey(_symbol(layer, text: '', iconName: 'cafe')),
        labelContinuityKey(_symbol(layer,
            text: '', iconName: 'cafe', anchor: const Offset(80, 20))),
      );
    });
  });

  group('LabelFadeTracker', () {
    test('a new label rises from zero to one over the fade duration', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      expect(tracker.show(1), 0, reason: 'no time has elapsed yet');
      expect(tracker.anyActive, isTrue);

      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.show(1), 0.5);

      tracker.beginFrame(_at(100), _fadeDuration);
      expect(tracker.show(1), 1);
      tracker.sweep((_, __) => fail('nothing is fading out'));
      expect(tracker.anyActive, isFalse, reason: 'the fade has finished');
    });

    test('a label shown every frame stays at one', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show(1);
      tracker.beginFrame(_at(500), _fadeDuration);
      expect(tracker.show(1), 1, reason: 'a long gap completes the fade');
      tracker.beginFrame(_at(516), _fadeDuration);
      expect(tracker.show(1), 1);
    });

    test('an unshown label fades out through the sweep and is dropped', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show(1);
      tracker.beginFrame(_at(100), _fadeDuration);
      tracker.show(1); // fully visible

      final fading = <double>[];
      tracker.beginFrame(_at(125), _fadeDuration);
      tracker.sweep((id, opacity) => fading.add(opacity));
      tracker.beginFrame(_at(150), _fadeDuration);
      tracker.sweep((id, opacity) => fading.add(opacity));
      expect(fading, [0.75, 0.5]);
      expect(tracker.isTracked(1), isTrue);
      expect(tracker.anyActive, isTrue);

      tracker.beginFrame(_at(250), _fadeDuration);
      tracker.sweep((_, __) => fail('the fade has completed'));
      expect(tracker.isTracked(1), isFalse, reason: 'self-pruning');
      expect(tracker.anyActive, isFalse);
    });

    test('a label re-shown mid-fade-out resumes from its opacity', () {
      // The anti-blink property: a label briefly unplaced — a lost
      // frame of collision — dips instead of restarting from zero.
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show(1);
      tracker.beginFrame(_at(100), _fadeDuration);
      tracker.show(1);
      tracker.beginFrame(_at(150), _fadeDuration);
      tracker.sweep((_, __) {}); // down to 0.5
      tracker.beginFrame(_at(175), _fadeDuration);
      expect(tracker.show(1), 0.75, reason: 'rising again from 0.5');
    });

    test('is idempotent within a frame', () {
      // However many copies of a label a frame offers, only the first
      // show advances it.
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show(1);
      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.show(1), 0.5);
      expect(tracker.show(1), 0.5);
      tracker.beginFrame(_at(100), _fadeDuration);
      expect(tracker.show(1), 1);
    });

    test('a zero duration completes everything immediately', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), Duration.zero);
      tracker.show(1);
      tracker.beginFrame(_at(1), Duration.zero);
      expect(tracker.show(1), 1);
      tracker.beginFrame(_at(2), Duration.zero);
      tracker.sweep((_, __) => fail('a zero duration never draws ghosts'));
      expect(tracker.isTracked(1), isFalse);
    });

    test('clear forgets everything', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show(1);
      tracker.clear();
      expect(tracker.isTracked(1), isFalse);
      expect(tracker.anyActive, isFalse);
    });
  });

  // 2.7.0 briefly grouped arrivals into waves that shared one opacity,
  // to collapse the painter's per-opacity `saveLayer` buckets. A label
  // arriving mid-wave waited, invisible, for the wave in flight to land.
  // It cost far more than it bought — the raster thread it was meant to
  // relieve was never the bottleneck — so these pin the behaviour it
  // replaced, which is the behaviour that does not flash.
  group('LabelFadeTracker never holds a placed label invisible', () {
    test('a label arriving mid-fade starts rising immediately', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show(1);

      // Half way through the first label's fade a second one lands. It
      // starts its own fade now; waiting for the first to land would
      // leave it painting nothing for up to a whole fade duration.
      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.show(1), 0.5);
      expect(tracker.show(2), 0, reason: 'no elapsed time yet');
      tracker.beginFrame(_at(75), _fadeDuration);
      expect(tracker.show(2), greaterThan(0),
          reason: 'its own clock, started on arrival');
    });

    test('a label arriving mid-interval draws from its first placed frame', () {
      // The wave mechanism held an *placed* label invisible until the
      // fade already in flight had landed — while it kept the collision
      // space it won, so nothing else could fill the gap either. The
      // throttle is different in both ways an arrival can go wrong: the
      // arriving label waits for the next due pass (at most one
      // interval), but until then it claims no space, and from the
      // first frame a pass places it, it paints.
      final painter = LabelPainter();
      final early = _symbol(layer, text: 'Feldkirchen');
      final arriving = _symbol(layer, text: 'Aschheim');
      const here = Offset(100, 100);
      const there = Offset(300, 300);

      _frame(painter, [_placedAt(early, anchor: here)], now: _at(0));
      final offered = [
        _placedAt(early, anchor: here),
        _placedAt(arriving, anchor: there, order: 1),
      ];
      final midInterval = _frame(painter, offered, now: _at(50));
      expect(midInterval.map((p) => p.instance), [early],
          reason: 'the arrival waits for the next pass, claiming nothing');
      expect(painter.placementPending, isTrue,
          reason: 'frames keep coming until the owed pass runs');
      final placed = _frame(painter, offered, now: _at(100));
      expect(placed.map((p) => p.instance), containsAll([early, arriving]),
          reason: 'both are placed, so both paint');
      painter.dispose();
    });

    test('a label placed on and off through a gesture keeps painting', () {
      // Parked at exactly zero, one missed frame took `opacity -= step`
      // below zero and dropped the key, so it re-arrived brand new and
      // queued behind the next wave — indefinitely, while tiles kept
      // republishing. It is the flashing in its sharpest form.
      final painter = LabelPainter();
      final steady = _symbol(layer, text: 'Feldkirchen');
      final churner = _symbol(layer, text: 'Aschheim');
      const here = Offset(100, 100);
      const there = Offset(300, 300);
      var placed = 0;
      var painted = 0;

      for (var frame = 0; frame < 60; frame++) {
        // Every frame lands on a pass (one interval apart), and the
        // churner loses its spot every third pass, as a republish does.
        // The story is the fade tracker's: a key parked at zero must
        // ride through the churn instead of being dropped and queued —
        // the pass cadence itself is the throttle tests' story.
        final offered = [
          _placedAt(steady, anchor: here),
          if (frame % 3 != 0) _placedAt(churner, anchor: there, order: 1),
        ];
        final drawn = _frame(painter, offered, now: _at(frame * 100));
        if (frame % 3 != 0) {
          placed++;
          if (drawn.any((p) => identical(p.instance, churner))) painted++;
        }
      }
      expect(placed, 40);
      expect(painted, placed,
          reason: 'every frame it is placed on is a frame it is drawn on');
      painter.dispose();
    });

    test('a continuous stream of arrivals fades in continuously', () {
      // The wave mechanism let labels become visible only when a wave
      // started, so a steady stream of arrivals appeared in bursts one
      // fade duration apart — the flashing this replaced.
      final tracker = LabelFadeTracker();
      final firstVisible = <int>{};
      for (var frame = 0; frame < 60; frame++) {
        tracker.beginFrame(_at(frame * 8), _fadeDuration);
        for (var i = 0; i <= frame; i++) {
          if (tracker.show(i) > 0) firstVisible.add(i);
        }
        tracker.sweep((_, __) {});
      }
      // Every label that arrived with a frame left to rise in became
      // visible, rather than the handful a burst schedule admits.
      expect(firstVisible, hasLength(59));
    });

    test('a departing label decays from where it got to', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show(1);
      tracker.show(2);
      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.show(1), 0.5);
      expect(tracker.show(2), 0.5);

      tracker.beginFrame(_at(75), _fadeDuration);
      tracker.show(1);
      final ghosts = <int, double>{};
      tracker.sweep((id, opacity) => ghosts[id] = opacity);
      expect(ghosts.keys, [2]);
      expect(ghosts[2], closeTo(0.25, 1e-9));

      // Re-placed mid-fade-out it resumes from where it is, rather than
      // restarting from zero.
      tracker.beginFrame(_at(90), _fadeDuration);
      final resumed = tracker.show(2);
      expect(resumed, greaterThan(0.25));
      expect(resumed, lessThan(1));
    });
  });

  group('along-line fades through the painter', () {
    test('a re-spaced street name cross-fades instead of teleporting', () {
      // The zoom-crossing story: the arriving level lays the same
      // street's label out somewhere else along the road — too far for
      // the identity index to call it the same label, so it gets an id
      // of its own. The old instance is only on offer as a fallback (its
      // tile has been covered); the new one fades in at its position
      // while the old position draws a fading ghost — never a
      // full-opacity jump.
      final painter = LabelPainter();
      final outgoing = _symbol(layer, text: 'Hauptstraße', alongLine: true);
      final arriving = _symbol(layer, text: 'Hauptstraße', alongLine: true);
      const oldSpot = Offset(120, 200);
      const newSpot = Offset(290, 200);
      final oldId = labelIdOf(outgoing);
      final newId = labelIdOf(arriving);

      _frame(painter, [_placedAt(outgoing, anchor: oldSpot)], now: _at(0));
      _frame(painter, [_placedAt(outgoing, anchor: oldSpot)], now: _at(100));
      expect(painter.debugFades.opacityOf(oldId), 1);

      // The swap lands mid-interval: that frame replays — the old label
      // holds as a full-opacity ghost (only a pass may start a
      // fade-out) while the arriving one waits for the next due pass.
      // At the pass both move: the old label starts its fade, the new
      // one starts rising.
      final offered = [
        _placedAt(arriving, anchor: newSpot),
        _placedAt(outgoing, anchor: oldSpot, order: 1, ghostOnly: true),
      ];
      _frame(painter, offered, now: _at(150));
      final crossing = _frame(painter, offered, now: _at(200));
      expect(crossing.map((p) => p.instance).toSet(), {arriving, outgoing},
          reason: 'the new position fades in while the old ghosts out');
      expect(painter.debugFades.opacityOf(newId), lessThan(1),
          reason: 'fading in at the new position, not inheriting 1');
      expect(painter.debugFades.opacityOf(oldId), lessThan(1),
          reason: 'fading out at the old one');

      // Settled: only the new label, at full opacity.
      _frame(painter, [_placedAt(arriving, anchor: newSpot)], now: _at(400));
      final settled = _frame(painter, [_placedAt(arriving, anchor: newSpot)],
          now: _at(700));
      expect(settled.map((p) => p.instance), [arriving]);
      expect(painter.debugFades.opacityOf(newId), 1);
      expect(painter.debugFades.opacityOf(oldId), isNull,
          reason: 'the old label has been swept out');
      painter.dispose();
    });

    test('a ghost draws from its own label, not a repeat of its name', () {
      // Two repeats of one street name are two labels. When one fades
      // out, its ghost is drawn from its own copy — not from the
      // priority-first candidate of the name at the other end of the
      // street.
      final painter = LabelPainter();
      final northRepeat = _symbol(layer, text: 'Ring', alongLine: true);
      final southRepeat = _symbol(layer, text: 'Ring', alongLine: true);
      const north = Offset(200, 60);
      const south = Offset(200, 340);

      List<PlacedSymbol> both() => [
            _placedAt(northRepeat, anchor: north),
            _placedAt(southRepeat, anchor: south, order: 1),
          ];
      _frame(painter, both(), now: _at(0));
      _frame(painter, both(), now: _at(100));

      // The south repeat loses its spot; both remain on offer (the
      // north one live, the south one as a fallback candidate).
      final drawn = _frame(
        painter,
        [
          _placedAt(northRepeat, anchor: north),
          _placedAt(southRepeat, anchor: south, order: 1, ghostOnly: true),
        ],
        now: _at(150),
      );
      final ghost = drawn.singleWhere((p) => identical(p.instance, southRepeat),
          orElse: () => fail('the south repeat should ghost out'));
      expect(ghost.screenAnchor, south,
          reason: 'the ghost draws where its label was, not at the north '
              'repeat');
      painter.dispose();
    });
  });

  group('PlacementThrottle', () {
    const screen = Size(400, 400);
    bool place(
      PlacementThrottle throttle,
      int ms, {
      int generation = 0,
      Size screenSize = screen,
      Duration interval = _fadeDuration,
    }) =>
        throttle.shouldPlace(
          now: _at(ms),
          interval: interval,
          generation: generation,
          screenSize: screenSize,
        );

    test('places once, then holds the decision for an interval', () {
      final throttle = PlacementThrottle();
      expect(place(throttle, 0), isTrue, reason: 'nothing to replay yet');
      expect(place(throttle, 50, generation: 1), isFalse);
      expect(throttle.deferred, isTrue, reason: 'a pass is owed');
      expect(place(throttle, 100, generation: 1), isTrue);
      expect(throttle.deferred, isFalse);
      // The interval runs from the last pass, not from fixed multiples.
      expect(place(throttle, 150, generation: 2), isFalse);
      expect(place(throttle, 200, generation: 2), isTrue);
    });

    test('a publish mid-interval stays a replay, with a pass owed', () {
      // The candidate set churns every few frames during a zoom
      // crossing, and a full collision pass per churn is a 10ms+
      // UI-thread spike on a symbol-heavy style — so a publish no
      // longer jumps the queue. Its labels wait out at most one
      // interval (the same duration their fade-in takes), and
      // [PlacementThrottle.deferred] keeps frames coming until the
      // owed pass runs.
      final throttle = PlacementThrottle();
      expect(place(throttle, 0), isTrue);
      expect(place(throttle, 10, generation: 1), isFalse,
          reason: 'a publish alone must not buy a collision pass');
      expect(throttle.deferred, isTrue, reason: 'a pass is owed');
      expect(place(throttle, 100, generation: 1), isTrue);
    });

    test('a settling repaint does not create another placement debt', () {
      final throttle = PlacementThrottle();
      expect(place(throttle, 0), isTrue);
      expect(place(throttle, 10, generation: 1), isFalse);
      expect(throttle.deferred, isTrue);

      expect(place(throttle, 100, generation: 1), isTrue,
          reason: 'the changed input is placed when its interval is due');
      expect(throttle.deferred, isFalse);

      expect(place(throttle, 101, generation: 1), isFalse,
          reason: 'an animation-only repaint has no new input to place');
      expect(throttle.deferred, isFalse,
          reason: 'the fade ticker must be allowed to stop');
    });

    test('a resize places without waiting', () {
      final throttle = PlacementThrottle();
      expect(place(throttle, 0), isTrue);
      expect(place(throttle, 10, screenSize: const Size(400, 800)), isTrue);
    });

    test('without fades every frame places', () {
      final throttle = PlacementThrottle();
      expect(place(throttle, 0, interval: Duration.zero), isTrue);
      expect(place(throttle, 1, interval: Duration.zero), isTrue);
      expect(throttle.deferred, isFalse);
    });

    test('a clock that steps backwards places again', () {
      final throttle = PlacementThrottle();
      expect(place(throttle, 500), isTrue);
      expect(place(throttle, 400), isTrue,
          reason: 'otherwise placement freezes until the clock catches up');
    });

    test('reset places on the next frame', () {
      final throttle = PlacementThrottle();
      expect(place(throttle, 0), isTrue);
      expect(place(throttle, 10, generation: 1), isFalse);
      throttle.reset();
      expect(place(throttle, 20, generation: 1), isTrue);
      expect(throttle.deferred, isFalse);
    });
  });

  group('PlacementMemory', () {
    const id = 7;

    test('a label sits back down at its own entry', () {
      // Whatever instance draws it: the entry is the label id's, and the
      // id is what a successor instance inherits.
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(id).flip = true;

      memory.beginFrame(prune: true);
      expect(memory.sitting(id).flip, isTrue);
    });

    test('different labels never share an entry', () {
      // Two labels of one name (the same street further along, the same
      // housenumber elsewhere) have ids of their own, so they never share
      // a side of the street.
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(id).flip = true;
      expect(memory.sitting(id + 1).flip, isNull);
    });

    test('an entry expires once its label has been gone a while', () {
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(id).anchor = 'bottom';
      for (var i = 0; i < 200; i++) {
        memory.beginFrame(prune: true);
      }
      expect(memory.lookup(id), isNull);
    });

    test('a label seen every frame never expires', () {
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(id).anchor = 'bottom';
      for (var i = 0; i < 200; i++) {
        memory.beginFrame(prune: true);
        memory.sitting(id);
      }
      expect(memory.lookup(id)?.anchor, 'bottom');
    });

    test('clear forgets everything', () {
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(id).anchor = 'bottom';
      memory.clear();
      expect(memory.lookup(id), isNull);
    });
  });

  group('per-label fades through the painter', () {
    test('a brand-new label draws from its very first frame', () {
      final painter = LabelPainter();
      final a = _symbol(layer);
      final drawn = _frame(painter, [_placedAt(a)], now: _at(0));
      expect(drawn.map((p) => p.instance), [a],
          reason: 'one opacity step from the start, never invisible');
      expect(painter.hasActiveFades, isTrue);
      painter.dispose();
    });

    test('an idle repaint after a due pass leaves no work pending', () {
      final painter = LabelPainter();
      final label = _symbol(layer);

      _frame(painter, [_placedAt(label)], now: _at(0), placementGeneration: 0);
      _frame(painter, [_placedAt(label)], now: _at(10), placementGeneration: 1);
      expect(painter.placementPending, isTrue,
          reason: 'camera motion inside the interval owes one pass');

      _frame(painter, [_placedAt(label)],
          now: _at(100), placementGeneration: 1);
      expect(painter.placementPending, isFalse,
          reason: 'the changed input has now been placed');

      _frame(painter, [_placedAt(label)],
          now: _at(101), placementGeneration: 1);
      expect(painter.hasActiveFades, isFalse);
      expect(painter.placementPending, isFalse,
          reason: 'the settling repaint must not restart the fade ticker');
      painter.dispose();
    });

    test('disabling fades clears an in-progress fade', () {
      final painter = LabelPainter();
      final label = _symbol(layer);
      final id = labelIdOf(label);

      _frame(painter, [_placedAt(label)], now: _at(0));
      expect(painter.hasActiveFades, isTrue);
      expect(painter.debugFades.isTracked(id), isTrue);

      final drawn = _frame(
        painter,
        [_placedAt(label)],
        now: _at(10),
        labelFadeDuration: Duration.zero,
      );
      expect(drawn.map((placed) => placed.instance), [label],
          reason: 'disabling fades makes placed labels fully opaque');
      expect(painter.hasActiveFades, isFalse,
          reason: 'the widget fade ticker must be allowed to settle');
      expect(painter.debugFades.isTracked(id), isFalse,
          reason: 'reenabling fades must not resume stale opacity state');
      painter.dispose();
    });

    test('a label present at both zoom levels never re-fades', () {
      // The "Munich blink": the arriving level's copy is a brand-new
      // instance, but the identity index gives it the label's id — one
      // id, one opacity, so the swap is invisible.
      final painter = LabelPainter();
      final outgoing = _symbol(layer, text: 'München');
      final arriving = _symbol(layer, text: 'München');
      final id = labelIdOf(outgoing);

      _frame(painter, [_placedAt(outgoing)], now: _at(0));
      _frame(painter, [_placedAt(outgoing)], now: _at(100));
      expect(painter.debugFades.opacityOf(id), 1);

      // Both copies are on offer while the levels overlap; only one
      // draws …
      for (final ms in [116, 216]) {
        final overlap = _frame(painter,
            [_placedAt(arriving, id: id), _placedAt(outgoing, order: 1)],
            now: _at(ms));
        expect(overlap, hasLength(1),
            reason: 'one copy of one label, replay (${ms}ms) or pass');
        expect(painter.debugFades.opacityOf(id), 1, reason: 'no restart');
      }

      // … and the hand-over to the new copy alone changes nothing
      // either.
      _frame(painter, [_placedAt(arriving, id: id)], now: _at(316));
      expect(painter.debugFades.opacityOf(id), 1);
      expect(painter.hasActiveFades, isFalse);
      painter.dispose();
    });

    test('a republish mid-interval never fades a label into itself', () {
      // The throttled-placement regression: a republish replaces every
      // instance between two passes. With winners kept by instance,
      // nothing "showed" the label until the next pass, and decaying
      // through that window dimmed it and faded its successor back in —
      // the same label cross-fading into itself at every crossing. The
      // successor carries the label's id, so it is the winner from its
      // first frame: drawn at full opacity, no dip, no hand-over.
      final painter = LabelPainter();
      final first = _symbol(layer, text: 'München');
      final id = labelIdOf(first);

      _frame(painter, [_placedAt(first)], now: _at(0));
      _frame(painter, [_placedAt(first)], now: _at(100));
      expect(painter.debugFades.opacityOf(id), 1);

      // Republished: same label, brand-new instance, mid-interval.
      final successor = _symbol(layer, text: 'München');
      for (final ms in [110, 130, 150, 170, 190]) {
        final drawn =
            _frame(painter, [_placedAt(successor, id: id)], now: _at(ms));
        expect(drawn.map((p) => p.instance), [successor],
            reason: 'keeps painting through the churn window at ${ms}ms');
        expect(painter.debugFades.opacityOf(id), 1,
            reason: 'no dip at ${ms}ms');
      }

      // The pass confirms it; still nothing to see.
      final passed =
          _frame(painter, [_placedAt(successor, id: id)], now: _at(200));
      expect(passed.map((p) => p.instance), [successor]);
      expect(painter.debugFades.opacityOf(id), 1);
      painter.dispose();
    });

    test('a winner whose tile is gone holds until a pass decides', () {
      // Only a pass may start a fade-out: between passes a winner with
      // no copy on offer may just be between tiles. It holds its
      // opacity, and a successor arriving before the pass resumes it.
      final painter = LabelPainter();
      final first = _symbol(layer, text: 'München');
      final other = _symbol(layer, text: 'Aschheim');
      final id = labelIdOf(first);
      const elsewhere = Offset(100, 100);

      _frame(painter, [_placedAt(first), _placedAt(other, anchor: elsewhere)],
          now: _at(0));
      _frame(painter, [_placedAt(first), _placedAt(other, anchor: elsewhere)],
          now: _at(100));
      _frame(painter, [_placedAt(other, anchor: elsewhere)], now: _at(150));
      expect(painter.debugFades.opacityOf(id), 1,
          reason: 'a replay frame never starts a fade-out');

      final successor = _symbol(layer, text: 'München');
      final back = _frame(
          painter,
          [
            _placedAt(successor, id: id),
            _placedAt(other, anchor: elsewhere, order: 1),
          ],
          now: _at(170));
      expect(back.map((p) => p.instance), contains(successor));
      expect(painter.debugFades.opacityOf(id), 1);
      painter.dispose();
    });

    test('a departing label fades out as a ghost that blocks nothing', () {
      final painter = LabelPainter();
      final departing = _symbol(layer, text: 'Feldkirchen');
      final replacement = _symbol(layer, text: 'Aschheim');

      _frame(painter, [_placedAt(departing)], now: _at(0));
      _frame(painter, [_placedAt(departing)], now: _at(100));

      // The next level replaces it with a different label in the same
      // spot; the departing instance is only on offer as a fallback.
      // The swap frame replays — the ghost holds at full opacity — and
      // the next due pass places the replacement into the space the
      // ghost never claimed, starting the ghost's fade-out.
      final offered = [
        _placedAt(replacement),
        _placedAt(departing, order: 1, ghostOnly: true)
      ];
      _frame(painter, offered, now: _at(150));
      final crossfade = _frame(painter, offered, now: _at(200));
      expect(crossfade.map((p) => p.instance).toSet(), {replacement, departing},
          reason: 'the ghost keeps drawing but frees its space, so the '
              'replacement fades in over it instead of popping later');

      // The ghost expires; the replacement finishes its fade-in.
      final settled = _frame(
        painter,
        [
          _placedAt(replacement),
          _placedAt(departing, order: 1, ghostOnly: true)
        ],
        now: _at(300),
      );
      expect(settled.map((p) => p.instance), [replacement]);
      expect(painter.debugFades.isTracked(labelIdOf(departing)), isFalse);
      painter.dispose();
    });

    test('a label cut by its layer minzoom eases out instead of popping', () {
      // Zooming out across the POI layer's minzoom: the gate stops the
      // label from being *placed*, but its ghost draws one last ramp —
      // this is the moment that used to be a hard one-frame cut.
      final (_, poi) = _streetAndPoiLayers();
      final painter = LabelPainter();
      final bakery = _symbol(poi, text: 'Bäckerei', layerIndex: 1);

      _frame(painter, [_placedAt(bakery)], styleZoom: 13.2, now: _at(0));
      _frame(painter, [_placedAt(bakery)], styleZoom: 13.2, now: _at(100));

      final fadingOut =
          _frame(painter, [_placedAt(bakery)], styleZoom: 12.9, now: _at(150));
      expect(fadingOut.map((p) => p.instance), [bakery],
          reason: 'below minzoom, but mid-fade-out');

      final gone =
          _frame(painter, [_placedAt(bakery)], styleZoom: 12.9, now: _at(300));
      expect(gone, isEmpty);
      painter.dispose();
    });

    test('a candidate that was never visible does not fade out', () {
      // Losing candidates come and go every frame; only keys that were
      // actually shown may draw a ghost, or labels would appear out of
      // nowhere purely to fade away.
      final painter = LabelPainter();
      final winner = _symbol(layer, text: 'Feldkirchen');
      final loser = _symbol(layer, text: 'Aschheim');

      // The loser collides with the winner every frame …
      _frame(
          painter,
          [
            _placedAt(winner),
            _placedAt(loser, anchor: const Offset(200, 201), order: 1)
          ],
          now: _at(0));
      // … and once it stops being offered at all, nothing of it draws.
      final drawn = _frame(painter, [_placedAt(winner)], now: _at(50));
      expect(drawn.map((p) => p.instance), [winner]);
      painter.dispose();
    });
  });

  group('placement frozen between passes', () {
    test('a collision the camera creates mid-interval is not acted on', () {
      // Two labels with room to spare when the decision is taken; the
      // camera then drifts them into each other. Deciding afresh every
      // frame is what makes a label vanish for a moment and come back
      // — between passes the pair is simply allowed to overlap.
      final painter = LabelPainter();
      final west = _symbol(layer, text: 'Feldkirchen');
      final east = _symbol(layer, text: 'Aschheim');

      List<PlacedSymbol> frame(int ms, double gap) => _frame(
            painter,
            [
              _placedAt(west, anchor: Offset(200 - gap, 200)),
              _placedAt(east, anchor: Offset(200 + gap, 200), order: 1),
            ],
            now: _at(ms),
          );

      expect(frame(0, 80).map((p) => p.instance).toSet(), {west, east});
      frame(100, 80); // a second pass; both are fully faded in by now

      // The camera drifts them together a step per frame.
      for (final (ms, gap) in [(120, 56.0), (140, 32.0), (160, 8.0)]) {
        expect(frame(ms, gap).map((p) => p.instance).toSet(), {west, east},
            reason: 'the decision taken at the last pass still stands');
      }
      expect(frame(180, 2).map((p) => p.instance).toSet(), {west, east},
          reason: 'the decision taken at the last pass still stands');
      expect(painter.placementPending, isTrue,
          reason: 'the layer keeps painting until the pass it owes runs');

      // The next pass resolves the overlap — once, and through a fade.
      frame(200, 2);
      expect(painter.debugFades.opacityOf(labelIdOf(west)), 1);
      expect(painter.debugFades.opacityOf(labelIdOf(east)), lessThan(1),
          reason: 'the loser eases out instead of blinking away');
      painter.dispose();
    });

    test('a name on two carriageways stays on the one it is drawn on', () {
      // A street name reaching the pass twice, as two labels: the two
      // carriageways of one road. Which one the priority sort puts first
      // is decided by their screen y, so a pan that reorders them would
      // walk the name across the street — but only the one on screen is
      // an incumbent.
      final painter = LabelPainter();
      final north = _symbol(layer, text: 'Rosenheimer Straße');
      final south = _symbol(layer, text: 'Rosenheimer Straße');

      final first = _frame(
        painter,
        [
          _placedAt(north, anchor: const Offset(200, 198)),
          _placedAt(south, anchor: const Offset(200, 202), order: 1),
        ],
        now: _at(0),
      );
      expect(first.map((p) => p.instance), [north],
          reason: 'the copy higher up the screen sorts first');

      // The pan reverses their order; the sitting copy is tried first.
      final panned = _frame(
        painter,
        [
          _placedAt(south, anchor: const Offset(200, 198)),
          _placedAt(north, anchor: const Offset(200, 202), order: 1),
        ],
        now: _at(100),
      );
      expect(panned.map((p) => p.instance), [north],
          reason: 'the name stays on the side of the street it is already on');
      painter.dispose();
    });
  });

  group('labels of one name fade apart', () {
    const westAt = Offset(100, 200);
    const eastAt = Offset(300, 200);

    test('two same-named POIs fade independently', () {
      // One fade state per name held every copy at the name's opacity
      // while *any* of them was placed: the others appeared and vanished
      // as hard pops, never fading at all — every parking icon, every
      // housenumber "12", every chain store. Each has its own label id,
      // so each has its own fade.
      final painter = LabelPainter();
      final west = _symbol(layer, text: 'Bäckerei');
      final east = _symbol(layer, text: 'Bäckerei');
      final westId = labelIdOf(west);
      final eastId = labelIdOf(east);

      List<PlacedSymbol> both() => [
            _placedAt(west, anchor: westAt),
            _placedAt(east, anchor: eastAt, order: 1),
          ];
      _frame(painter, both(), now: _at(0));
      _frame(painter, both(), now: _at(100));
      expect(painter.debugFades.opacityOf(westId), 1);
      expect(painter.debugFades.opacityOf(eastId), 1);

      // East's tile expires; the pass confirms its disappearance. West
      // being on screen must not hold east at full opacity.
      _frame(painter, [_placedAt(west, anchor: westAt)], now: _at(150));
      _frame(painter, [_placedAt(west, anchor: westAt)], now: _at(200));
      expect(painter.debugFades.opacityOf(westId), 1);
      expect(painter.debugFades.opacityOf(eastId), lessThan(1),
          reason: 'eases out on its own instead of popping');
      painter.dispose();
    });

    test('a same-named POI arriving elsewhere fades in', () {
      final painter = LabelPainter();
      final west = _symbol(layer, text: 'Bäckerei');
      final east = _symbol(layer, text: 'Bäckerei');

      _frame(painter, [_placedAt(west, anchor: westAt)], now: _at(0));
      _frame(painter, [_placedAt(west, anchor: westAt)], now: _at(100));

      // East arrives at the next pass: its own fade-in from zero, not
      // west's full opacity teleported across the screen.
      _frame(
          painter,
          [
            _placedAt(west, anchor: westAt),
            _placedAt(east, anchor: eastAt, order: 1),
          ],
          now: _at(200));
      expect(painter.debugFades.opacityOf(labelIdOf(east)), lessThan(1),
          reason: 'fades in on its own');
      expect(painter.debugFades.opacityOf(labelIdOf(west)), 1);
      painter.dispose();
    });
  });

  group('incumbents keep their space', () {
    test('a same-layer arrival never evicts a visible label', () {
      // The visible→hidden→visible twitch: during a crossing the
      // arriving level injects candidates that outrank a label already
      // on screen, evict it, and hand the space back half a level
      // later. An incumbent is tried ahead of same-layer newcomers, so
      // the arrival waits for genuinely free space instead.
      final painter = LabelPainter();
      final sitting = _symbol(layer, text: 'Feldkirchen');
      final arrival = _symbol(layer, text: 'Aschheim');

      _frame(painter, [_placedAt(sitting)], now: _at(0));
      _frame(painter, [_placedAt(sitting)], now: _at(100));

      // The arrival overlaps and sorts higher on screen y.
      final offered = [
        _placedAt(arrival, anchor: const Offset(200, 199)),
        _placedAt(sitting, order: 1),
      ];
      _frame(painter, offered, now: _at(150));
      final passed = _frame(painter, offered, now: _at(200));
      expect(passed.map((p) => p.instance), [sitting],
          reason: 'the label on screen keeps its space');
      painter.dispose();
    });

    test('incumbency survives a republish', () {
      // A republish or level swap replaces every instance — precisely
      // when incumbency matters most. Winners are label ids, so the
      // successor instance is an incumbent from its first pass, with or
      // without fades.
      for (final fades in [true, false]) {
        final painter = LabelPainter();
        final original = _symbol(layer, text: 'Feldkirchen');
        final id = labelIdOf(original);
        DateTime? at(int ms) => fades ? _at(ms) : null;

        _frame(painter, [_placedAt(original)], now: at(0));
        _frame(painter, [_placedAt(original)], now: at(100));

        final successor = _symbol(layer, text: 'Feldkirchen');
        final arrival = _symbol(layer, text: 'Aschheim');
        final offered = [
          _placedAt(arrival, anchor: const Offset(200, 199)),
          _placedAt(successor, order: 1, id: id),
        ];
        _frame(painter, offered, now: at(150));
        final passed = _frame(painter, offered, now: at(200));
        expect(passed.map((p) => p.instance), [successor],
            reason: 'the sitting label wins through its successor instance '
                '(fades: $fades)');
        painter.dispose();
      }
    });

    test('a higher-layer arrival still outranks an incumbent', () {
      // Incumbency is scoped to the layer: the style author's hierarchy
      // decides across layers, and the evicted label eases out.
      final painter = LabelPainter();
      final sitting = _symbol(layer, text: 'Feldkirchen');
      final arrival = _symbol(layer, text: 'Aschheim', layerIndex: 1);

      _frame(painter, [_placedAt(sitting)], now: _at(0));
      _frame(painter, [_placedAt(sitting)], now: _at(100));

      final offered = [
        _placedAt(arrival, anchor: const Offset(200, 199)),
        _placedAt(sitting, order: 1),
      ];
      _frame(painter, offered, now: _at(150));
      final passed = _frame(painter, offered, now: _at(200));
      expect(passed.map((p) => p.instance).toSet(), contains(arrival),
          reason: 'the higher layer takes the space');
      expect(painter.debugFades.opacityOf(labelIdOf(sitting)), lessThan(1),
          reason: 'the evicted label eases out instead of blinking away');
      painter.dispose();
    });
  });

  group('two copies of one label in one frame', () {
    test('draw once, whichever copy sorts first', () {
      // A zoom crossing (and any tile seam) offers the same label twice
      // for a few frames; one label draws once.
      for (final arrivingFirst in [true, false]) {
        final id = labelIdOf(('twin', arrivingFirst));
        final drawn = _paint([
          _placedAt(_symbol(layer),
              anchor: Offset(200, arrivingFirst ? 199.7 : 200.3), id: id),
          _placedAt(_symbol(layer),
              anchor: const Offset(200, 200), order: 1, id: id),
        ]);
        expect(drawn, hasLength(1), reason: 'one label, one copy drawn');
      }
    });

    test('draw once even where nothing would collide', () {
      // Collision used to be what removed the second copy. A layer that
      // allows overlap never collides, so it drew a seam label twice,
      // one copy over the other.
      final theme = const ThemeReader().read({
        'layers': [
          {
            'id': 'place',
            'type': 'symbol',
            'source': 's',
            'source-layer': 'place',
            'layout': {
              'text-field': '{name}',
              'text-allow-overlap': true,
            },
          },
        ],
      });
      final overlapping = theme.layers.single as SymbolThemeLayer;
      final id = labelIdOf('overlapping twin');
      final drawn = _paint([
        _placedAt(_symbol(overlapping), id: id),
        _placedAt(_symbol(overlapping), order: 1, id: id),
        _placedAt(_symbol(overlapping), order: 2),
      ]);
      expect(drawn, hasLength(2),
          reason: 'the twin draws once; another label at the same spot '
              'still draws, overlap being allowed');
    });

    test('the copy that draws is the one that fits', () {
      // Only a *drawn* copy settles its label: one that lost collision
      // leaves the next copy to try.
      final blocker = _symbol(layer, text: 'Aschheim', layerIndex: 1);
      final id = labelIdOf('fitting twin');
      final blocked = _symbol(layer);
      final free = _symbol(layer);
      final drawn = _paint([
        _placedAt(blocker, anchor: const Offset(200, 200)),
        _placedAt(blocked, anchor: const Offset(200, 200), order: 1, id: id),
        _placedAt(free, anchor: const Offset(200, 260), order: 2, id: id),
      ]);
      expect(drawn.map((p) => p.instance).toSet(), {blocker, free});
    });
  });

  group('drawnLabels', () {
    test('keeps only what the last frame drew, in order', () {
      expect(drawnLabels(Int32List.fromList([1, 2, 3]), {3, 1}), [0, 2]);
    });

    test('everything drawn: nothing to cut', () {
      expect(drawnLabels(Int32List.fromList([1, 2]), {1, 2}), isNull);
    });

    test('nothing drawn: the cohort is emptied', () {
      expect(drawnLabels(Int32List.fromList([1]), const {}), isEmpty);
    });

    test('membership is by label, whichever copy drew it', () {
      // The outgoing cohort's copy of a label the arriving level drew is
      // still a copy of a label on screen, so it stays.
      expect(drawnLabels(Int32List.fromList([5, 6]), {5}), [0]);
    });
  });

  group('an outgoing cohort is pinned to what was on screen', () {
    // The flash this prevents: a zoom-out crossing cuts the POI layer at
    // its minzoom in one frame, and the space its labels held would go
    // to whatever the outgoing cohort had been suppressing — street
    // names never seen before, appearing mid-transition only to be
    // faded straight back out once the new level arrives.
    final (street, poi) = _streetAndPoiLayers();

    test('a candidate a zoom-cut label was suppressing does not appear', () {
      final streetName = _symbol(street, text: 'Hauptstr', layerIndex: 0);
      final poiName = _symbol(poi, text: 'Bäckerei', layerIndex: 1);
      final cohort = [streetName, poiName];
      final ids = Int32List.fromList([for (final s in cohort) labelIdOf(s)]);

      // The last frame before the crossing: the POI wins the shared spot.
      final drawn = _paint(
        [_placedAt(streetName), _placedAt(poiName, order: 1)],
        styleZoom: 13.2,
      );
      expect(drawn.map((p) => p.instance), [poiName]);

      // The crossing pins the cohort to what was drawn. The next frame's
      // style zoom is below the POI layer's minzoom, so its label is
      // gone — and the freed space stays empty instead of flashing the
      // street name in.
      final kept = drawnLabels(ids, {for (final p in drawn) p.id})!;
      expect(
        _paint([for (final i in kept) _placedAt(cohort[i])], styleZoom: 12.9),
        isEmpty,
      );
    });

    test('without the pin, the freed space flashes the loser in', () {
      // The behaviour the pin removes, kept so a regression is loud.
      final streetName = _symbol(street, text: 'Hauptstr', layerIndex: 0);
      final poiName = _symbol(poi, text: 'Bäckerei', layerIndex: 1);
      final drawn = _paint(
        [_placedAt(streetName), _placedAt(poiName, order: 1)],
        styleZoom: 12.9,
      );
      expect(drawn.map((p) => p.instance), [streetName]);
    });
  });
}
