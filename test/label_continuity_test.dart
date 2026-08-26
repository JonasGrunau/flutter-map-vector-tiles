import 'dart:ui' as ui;
import 'dart:ui' show Offset, Size;

import 'package:flutter_map_vector_tiles/src/render/label_continuity.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart';
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart';
import 'package:flutter_map_vector_tiles/src/style/theme.dart';
import 'package:flutter_map_vector_tiles/src/style/theme_reader.dart';
import 'package:flutter_test/flutter_test.dart';

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
PlacedSymbol _placedAt(
  SymbolInstance instance, {
  Offset anchor = const Offset(200, 200),
  int order = 0,
  bool ghostOnly = false,
}) =>
    PlacedSymbol(
      instance: instance,
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
/// due pass (a publish no longer forces an immediate one).
List<PlacedSymbol> _frame(
  LabelPainter painter,
  List<PlacedSymbol> symbols, {
  double styleZoom = 14,
  DateTime? now,
}) {
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: ui.Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: styleZoom,
    symbols: symbols,
    labelFadeDuration: now == null ? Duration.zero : _fadeDuration,
    now: now,
  );
  recorder.endRecording().dispose();
  return drawn;
}

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
    test('a new key rises from zero to one over the fade duration', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      expect(tracker.showAt('k', Offset.zero), 0,
          reason: 'no time has elapsed yet');
      expect(tracker.anyActive, isTrue);

      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.showAt('k', Offset.zero), 0.5);

      tracker.beginFrame(_at(100), _fadeDuration);
      expect(tracker.showAt('k', Offset.zero), 1);
      tracker.sweep((_, __, ___) => fail('nothing is fading out'));
      expect(tracker.anyActive, isFalse, reason: 'the fade has finished');
    });

    test('a key shown every frame stays at one', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', Offset.zero);
      tracker.beginFrame(_at(500), _fadeDuration);
      expect(tracker.showAt('k', Offset.zero), 1,
          reason: 'a long gap completes the fade');
      tracker.beginFrame(_at(516), _fadeDuration);
      expect(tracker.showAt('k', Offset.zero), 1);
    });

    test('an unshown key fades out through the sweep and is dropped', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', Offset.zero);
      tracker.beginFrame(_at(100), _fadeDuration);
      tracker.showAt('k', Offset.zero); // fully visible

      final fading = <double>[];
      tracker.beginFrame(_at(125), _fadeDuration);
      tracker.sweep((key, position, opacity) {
        fading.add(opacity);
        return null;
      });
      tracker.beginFrame(_at(150), _fadeDuration);
      tracker.sweep((key, position, opacity) {
        fading.add(opacity);
        return null;
      });
      expect(fading, [0.75, 0.5]);
      expect(tracker.isTracked('k'), isTrue);
      expect(tracker.anyActive, isTrue);

      tracker.beginFrame(_at(250), _fadeDuration);
      tracker.sweep((_, __, ___) => fail('the fade has completed'));
      expect(tracker.isTracked('k'), isFalse, reason: 'self-pruning');
      expect(tracker.anyActive, isFalse);
    });

    test('a key re-shown mid-fade-out resumes from its current opacity', () {
      // The anti-blink property: a label briefly unplaced — a republish,
      // a lost frame of collision, a level swap — dips instead of
      // restarting from zero and never cross-fades against itself.
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', Offset.zero);
      tracker.beginFrame(_at(100), _fadeDuration);
      tracker.showAt('k', Offset.zero);
      tracker.beginFrame(_at(150), _fadeDuration);
      tracker.sweep((_, __, ___) => null); // down to 0.5
      tracker.beginFrame(_at(175), _fadeDuration);
      expect(tracker.showAt('k', Offset.zero), 0.75,
          reason: 'rising again from 0.5');
    });

    test('is idempotent within a frame', () {
      // Seam twins and the retained copy of a carried-over label all
      // show the same key; only the first call advances it.
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', Offset.zero);
      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.showAt('k', Offset.zero), 0.5);
      expect(tracker.showAt('k', Offset.zero), 0.5);
      tracker.beginFrame(_at(100), _fadeDuration);
      expect(tracker.showAt('k', Offset.zero), 1);
    });

    test('a zero duration completes everything immediately', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), Duration.zero);
      tracker.showAt('k', Offset.zero);
      tracker.beginFrame(_at(1), Duration.zero);
      expect(tracker.showAt('k', Offset.zero), 1);
      tracker.beginFrame(_at(2), Duration.zero);
      tracker.sweep((_, __, ___) => fail('a zero duration never draws ghosts'));
      expect(tracker.isTracked('k'), isFalse);
    });

    test('clear forgets everything', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', Offset.zero);
      tracker.clear();
      expect(tracker.isTracked('k'), isFalse);
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
    test('a key arriving mid-fade starts rising immediately', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('early', Offset.zero);

      // Half way through the first label's fade a second one lands. It
      // starts its own fade now; waiting for the first to land would
      // leave it painting nothing for up to a whole fade duration.
      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.showAt('early', Offset.zero), 0.5);
      expect(tracker.showAt('late', Offset.zero), 0,
          reason: 'no elapsed time yet');
      tracker.beginFrame(_at(75), _fadeDuration);
      expect(tracker.showAt('late', Offset.zero), greaterThan(0),
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
          if (tracker.showAt('k$i', Offset.zero) > 0) firstVisible.add(i);
        }
        tracker.sweep((_, __, ___) => null);
      }
      // Every label that arrived with a frame left to rise in became
      // visible, rather than the handful a burst schedule admits.
      expect(firstVisible, hasLength(59));
    });

    test('a departing key decays from where it got to', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('a', Offset.zero);
      tracker.showAt('b', Offset.zero);
      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.showAt('a', Offset.zero), 0.5);
      expect(tracker.showAt('b', Offset.zero), 0.5);

      tracker.beginFrame(_at(75), _fadeDuration);
      tracker.showAt('a', Offset.zero);
      final ghosts = <Object, double>{};
      tracker.sweep((key, position, opacity) {
        ghosts[key] = opacity;
        return null;
      });
      expect(ghosts.keys, ['b']);
      expect(ghosts['b'], closeTo(0.25, 1e-9));

      // Re-placed mid-fade-out it resumes from where it is, rather than
      // restarting from zero.
      tracker.beginFrame(_at(90), _fadeDuration);
      final resumed = tracker.showAt('b', Offset.zero);
      expect(resumed, greaterThan(0.25));
      expect(resumed, lessThan(1));
    });
  });

  group('LabelFadeTracker along-line sittings', () {
    // Along-line anchors are re-derived from `symbol-spacing` per
    // display layout, so a zoom crossing genuinely moves them — half
    // the spacing for a straight street. One opacity per key would
    // hand the new position the old one's full opacity: the name
    // teleports. Each sitting fades on its own instead, matched by
    // position within [LabelFadeTracker.matchRadius].
    const here = Offset(100, 100);
    const nearby = Offset(110, 105); // within the match radius
    const there = Offset(225, 100); // a re-spaced anchor, far outside it

    test('a moved sitting fades in at the new position', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', here);
      tracker.beginFrame(_at(100), _fadeDuration);
      expect(tracker.showAt('k', here), 1);

      // The crossing: the same key arrives at the re-spaced position.
      tracker.beginFrame(_at(150), _fadeDuration);
      expect(tracker.showAt('k', there), 0,
          reason: 'a new sitting, not the old one at full opacity');
      final ghosts = <Offset?, double>{};
      tracker.sweep((key, position, opacity) {
        ghosts[position] = opacity;
        return null;
      });
      expect(ghosts, {here: 0.5},
          reason: 'the old sitting fades out where it was');
    });

    test('a sitting that only drifted resumes its fade', () {
      // Simplification noise, a provisional→final swap, the camera
      // between two frames: all move an anchor a few pixels. Those must
      // keep their state, or every republish would re-fade the street.
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', here);
      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.showAt('k', nearby), 0.5, reason: 'the same sitting');
      expect(tracker.opacityNear('k', here), 0.5);
    });

    test('seam twins share one sitting within a frame', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', here);
      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.showAt('k', here), 0.5);
      expect(tracker.showAt('k', nearby), 0.5,
          reason: 'idempotent: the twin reads, it does not advance');
    });

    test('the repeats of one street fade independently', () {
      // Two sittings of the same name, spacing apart: a newly appearing
      // repeat fades in even while the established one sits at 1.
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', here);
      tracker.beginFrame(_at(100), _fadeDuration);
      expect(tracker.showAt('k', here), 1);
      expect(tracker.showAt('k', there), 0, reason: 'its own fade');
      tracker.beginFrame(_at(150), _fadeDuration);
      expect(tracker.showAt('k', here), 1);
      expect(tracker.showAt('k', there), 0.5);
      expect(tracker.anyActive, isTrue);
    });

    test('a fading sitting follows where its ghost is drawn', () {
      // The sweep hands back where the ghost actually painted; the
      // sitting adopts it, so a fade-out tracks the camera and a
      // re-appearance still matches the sitting.
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', here);
      tracker.beginFrame(_at(100), _fadeDuration);
      tracker.showAt('k', here);

      // Two ghost frames, the camera dragging the label 20px per frame.
      tracker.beginFrame(_at(125), _fadeDuration);
      tracker.sweep((key, position, opacity) {
        expect(position, here);
        return here + const Offset(20, 0);
      });
      tracker.beginFrame(_at(150), _fadeDuration);
      tracker.sweep((key, position, opacity) {
        expect(position, here + const Offset(20, 0));
        return here + const Offset(40, 0);
      });

      // Re-placed where the camera has taken it: still the same
      // sitting, resuming from 0.5 rather than restarting.
      tracker.beginFrame(_at(175), _fadeDuration);
      expect(tracker.showAt('k', here + const Offset(45, 2)), 0.75);
    });

    test('sittings prune like point keys do', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.showAt('k', here);
      expect(tracker.isTracked('k'), isTrue);
      tracker.beginFrame(_at(500), _fadeDuration);
      tracker.sweep((_, __, ___) => null);
      expect(tracker.isTracked('k'), isFalse, reason: 'self-pruning');
      expect(tracker.anyActive, isFalse);
    });
  });

  group('along-line fades through the painter', () {
    test('a re-spaced street name cross-fades instead of teleporting', () {
      // The zoom-crossing story: the arriving level lays the same
      // street's label out somewhere else along the road. The old
      // instance is only on offer as a fallback (its tile has been
      // covered); the new one fades in at its position while the old
      // position draws a fading ghost — never a full-opacity jump.
      final painter = LabelPainter();
      final outgoing = _symbol(layer, text: 'Hauptstraße', alongLine: true);
      final arriving = _symbol(layer, text: 'Hauptstraße', alongLine: true);
      const oldSpot = Offset(120, 200);
      const newSpot = Offset(290, 200);

      _frame(painter, [_placedAt(outgoing, anchor: oldSpot)], now: _at(0));
      _frame(painter, [_placedAt(outgoing, anchor: oldSpot)], now: _at(100));
      expect(
          painter.debugFades.opacityNear(outgoing.continuityKey, oldSpot), 1);

      // The swap lands mid-interval: that frame replays — the old
      // position holds as a full-opacity ghost (only a pass may start a
      // fade-out) while the arriving copy waits for the next due pass.
      // At the pass both move: the old sitting starts its fade, the new
      // one starts rising.
      final offered = [
        _placedAt(arriving, anchor: newSpot),
        _placedAt(outgoing, anchor: oldSpot, order: 1, ghostOnly: true),
      ];
      _frame(painter, offered, now: _at(150));
      final crossing = _frame(painter, offered, now: _at(200));
      expect(crossing.map((p) => p.instance).toSet(), {arriving, outgoing},
          reason: 'the new position fades in while the old ghosts out');
      final key = arriving.continuityKey;
      expect(painter.debugFades.opacityNear(key, newSpot), lessThan(1),
          reason: 'fading in at the new position, not inheriting 1');
      expect(painter.debugFades.opacityNear(key, oldSpot), lessThan(1),
          reason: 'fading out at the old one');

      // Settled: one sitting at the new position, at full opacity.
      _frame(painter, [_placedAt(arriving, anchor: newSpot)], now: _at(400));
      final settled = _frame(painter, [_placedAt(arriving, anchor: newSpot)],
          now: _at(700));
      expect(settled.map((p) => p.instance), [arriving]);
      expect(painter.debugFades.opacityNear(key, newSpot), 1);
      expect(painter.debugFades.opacityNear(key, oldSpot), isNull,
          reason: 'the old sitting has been swept out');
      painter.dispose();
    });

    test('a ghost is not drawn from a repeat far from the fading sitting', () {
      // With every candidate of a key on offer, the fading sitting must
      // take the one where it was — not the priority-first repeat at
      // the other end of the street.
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
          orElse: () => fail('the south sitting should ghost out'));
      expect(ghost.screenAnchor, south,
          reason: 'the ghost draws where the sitting was, not at the '
              'north repeat');
      painter.dispose();
    });
  });

  group('PlacementThrottle', () {
    const screen = Size(400, 400);
    bool place(
      PlacementThrottle throttle,
      int ms, {
      Size screenSize = screen,
      Duration interval = _fadeDuration,
    }) =>
        throttle.shouldPlace(
          now: _at(ms),
          interval: interval,
          screenSize: screenSize,
        );

    test('places once, then holds the decision for an interval', () {
      final throttle = PlacementThrottle();
      expect(place(throttle, 0), isTrue, reason: 'nothing to replay yet');
      expect(place(throttle, 50), isFalse);
      expect(throttle.deferred, isTrue, reason: 'a pass is owed');
      expect(place(throttle, 100), isTrue);
      expect(throttle.deferred, isFalse);
      // The interval runs from the last pass, not from fixed multiples.
      expect(place(throttle, 150), isFalse);
      expect(place(throttle, 200), isTrue);
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
      expect(place(throttle, 10), isFalse,
          reason: 'a publish alone must not buy a collision pass');
      expect(throttle.deferred, isTrue, reason: 'a pass is owed');
      expect(place(throttle, 100), isTrue);
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
      expect(place(throttle, 10), isFalse);
      throttle.reset();
      expect(place(throttle, 20), isTrue);
      expect(throttle.deferred, isFalse);
    });
  });

  group('PlacementMemory', () {
    const key = 'road-label/Hauptstraße';

    test('a label near where it was sits back down at its own entry', () {
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(key, const Offset(200, 200)).flip = true;

      memory.beginFrame(prune: true);
      expect(memory.sitting(key, const Offset(204, 203)).flip, isTrue,
          reason: 'the same label, a few pixels along');
      expect(memory.sitting(key, const Offset(200, 500)).flip, isNull,
          reason: 'the same name further down the street decides its own');
    });

    test('the entry follows the label it was matched to', () {
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(key, const Offset(100, 100)).anchor = 'bottom';
      // Twenty pixels a frame for five frames: never more than the match
      // radius at once, so the entry travels with it.
      for (var i = 1; i <= 5; i++) {
        memory.beginFrame(prune: true);
        expect(
            memory.sitting(key, Offset(100 + 20.0 * i, 100)).anchor, 'bottom');
      }
      expect(memory.lookup(key, const Offset(100, 100)), isNull,
          reason: 'it is no longer where it started');
    });

    test('different labels never share an entry', () {
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(key, const Offset(200, 200)).flip = true;
      expect(memory.sitting('other-key', const Offset(200, 200)).flip, isNull);
    });

    test('an entry expires once its label has been gone a while', () {
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(key, const Offset(200, 200)).anchor = 'bottom';
      for (var i = 0; i < 200; i++) {
        memory.beginFrame(prune: true);
      }
      expect(memory.lookup(key, const Offset(200, 200)), isNull);
    });

    test('clear forgets everything', () {
      final memory = PlacementMemory();
      memory.beginFrame(prune: true);
      memory.sitting(key, const Offset(200, 200)).anchor = 'bottom';
      memory.clear();
      expect(memory.lookup(key, const Offset(200, 200)), isNull);
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

    test('a label present at both zoom levels never re-fades', () {
      // The "Munich blink": the arriving level's copy is a brand-new
      // instance, but it carries the same continuity key — one key, one
      // opacity, so the swap is invisible.
      final painter = LabelPainter();
      final outgoing = _symbol(layer, text: 'München');
      final arriving = _symbol(layer, text: 'München');
      final key = outgoing.continuityKey;

      _frame(painter, [_placedAt(outgoing)], now: _at(0));
      _frame(painter, [_placedAt(outgoing)], now: _at(100));
      expect(painter.debugFades.opacityNear(key, const Offset(200, 200)), 1);

      // Both copies are on offer while the levels overlap; only one
      // draws (mid-interval the incumbent replays, at a pass the
      // collision keeps one) …
      final overlap = _frame(
          painter, [_placedAt(arriving), _placedAt(outgoing, order: 1)],
          now: _at(116));
      expect(overlap, hasLength(1), reason: 'one copy of one label');
      expect(painter.debugFades.opacityNear(key, const Offset(200, 200)), 1,
          reason: 'no restart');

      // … and the hand-over to the new copy alone — picked up at the
      // next due pass — changes nothing either.
      _frame(painter, [_placedAt(arriving)], now: _at(216));
      expect(painter.debugFades.opacityNear(key, const Offset(200, 200)), 1);
      expect(painter.hasActiveFades, isFalse);
      painter.dispose();
    });

    test('a republish mid-interval never fades a label into itself', () {
      // The throttled-placement regression: winners are matched by
      // instance identity and a republish replaces every instance, so
      // between the churn and the next due pass nothing "shows" the
      // key. Decaying through that window dimmed the label and faded
      // its successor back in — the same label cross-fading into
      // itself at every crossing. Un-shown keys hold on replay frames
      // instead: the ghost draws from the successor candidate at full
      // opacity until the pass adopts it, seamlessly.
      final painter = LabelPainter();
      final first = _symbol(layer, text: 'München');
      final key = first.continuityKey;

      _frame(painter, [_placedAt(first)], now: _at(0));
      _frame(painter, [_placedAt(first)], now: _at(100));
      expect(painter.debugFades.opacityNear(key, const Offset(200, 200)), 1);

      // Republished: same label, brand-new instance, mid-interval.
      final successor = _symbol(layer, text: 'München');
      for (final ms in [110, 130, 150, 170, 190]) {
        final drawn = _frame(painter, [_placedAt(successor)], now: _at(ms));
        expect(drawn.map((p) => p.instance), [successor],
            reason: 'keeps painting through the churn window at ${ms}ms');
        expect(painter.debugFades.opacityNear(key, const Offset(200, 200)), 1,
            reason: 'no dip at ${ms}ms');
      }

      // The pass adopts the successor; still nothing to see.
      final passed = _frame(painter, [_placedAt(successor)], now: _at(200));
      expect(passed.map((p) => p.instance), [successor]);
      expect(painter.debugFades.opacityNear(key, const Offset(200, 200)), 1);
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
      expect(painter.debugFades.isTracked(departing.continuityKey), isFalse);
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

      // The camera drifts them together a step per frame — between two
      // painted frames an anchor moves only as far as the gesture does,
      // well inside the fade tracker's sitting match radius.
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
      expect(
          painter.debugFades
              .opacityNear(west.continuityKey, const Offset(198, 200)),
          1);
      expect(
          painter.debugFades
              .opacityNear(east.continuityKey, const Offset(202, 200)),
          lessThan(1),
          reason: 'the loser eases out instead of blinking away');
      painter.dispose();
    });

    test('a label with two candidates keeps the one it is drawn from', () {
      // A street name reaching the pass twice — the two carriageways of
      // one road, or the outgoing and arriving level of a zoom. Which
      // copy the priority sort puts first is decided by their screen y,
      // so a pan that reorders them walks the name across the street.
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

  group('per-sitting fades split what position separates', () {
    const westAt = Offset(100, 200);
    const eastAt = Offset(300, 200);

    test('two same-named POIs fade independently', () {
      // One fade state per key held every copy at the key's opacity
      // while *any* of them was placed: the other copies appeared and
      // vanished as hard pops, never fading at all — every parking
      // icon, every housenumber "12", every chain store. Per-sitting
      // states give each its own fade.
      final painter = LabelPainter();
      final west = _symbol(layer, text: 'Bäckerei');
      final east = _symbol(layer, text: 'Bäckerei');
      final key = west.continuityKey;

      List<PlacedSymbol> both() => [
            _placedAt(west, anchor: westAt),
            _placedAt(east, anchor: eastAt, order: 1),
          ];
      _frame(painter, both(), now: _at(0));
      _frame(painter, both(), now: _at(100));
      expect(painter.debugFades.opacityNear(key, westAt), 1);
      expect(painter.debugFades.opacityNear(key, eastAt), 1);

      // East's tile expires; the pass confirms its disappearance. West
      // being on screen must not hold east's spot at full opacity.
      _frame(painter, [_placedAt(west, anchor: westAt)], now: _at(150));
      _frame(painter, [_placedAt(west, anchor: westAt)], now: _at(200));
      expect(painter.debugFades.opacityNear(key, westAt), 1);
      expect(painter.debugFades.opacityNear(key, eastAt), lessThan(1),
          reason: 'eases out on its own instead of popping');
      painter.dispose();
    });

    test('a same-named POI arriving elsewhere fades in', () {
      final painter = LabelPainter();
      final west = _symbol(layer, text: 'Bäckerei');
      final east = _symbol(layer, text: 'Bäckerei');
      final key = west.continuityKey;

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
      expect(painter.debugFades.opacityNear(key, eastAt), lessThan(1),
          reason: 'fades in on its own');
      expect(painter.debugFades.opacityNear(key, westAt), 1);
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
      // Winners are matched by instance identity, and a republish or
      // level swap replaces every instance — precisely when incumbency
      // matters most. The fade tracker's full-opacity sitting carries
      // it across: the successor instance inherits the incumbency.
      final painter = LabelPainter();
      final original = _symbol(layer, text: 'Feldkirchen');

      _frame(painter, [_placedAt(original)], now: _at(0));
      _frame(painter, [_placedAt(original)], now: _at(100));

      final successor = _symbol(layer, text: 'Feldkirchen');
      final arrival = _symbol(layer, text: 'Aschheim');
      final offered = [
        _placedAt(arrival, anchor: const Offset(200, 199)),
        _placedAt(successor, order: 1),
      ];
      _frame(painter, offered, now: _at(150));
      final passed = _frame(painter, offered, now: _at(200));
      expect(passed.map((p) => p.instance), [successor],
          reason: 'the sitting label wins through its successor instance');
      painter.dispose();
    });

    test('a higher-layer arrival still outranks an incumbent', () {
      // Incumbency is scoped to the layer: the style author's hierarchy
      // decides across layers, and the evicted label eases out.
      final painter = LabelPainter();
      final sitting = _symbol(layer, text: 'Feldkirchen');
      final arrival = _symbol(layer, text: 'Aschheim', layerIndex: 1);
      final key = sitting.continuityKey;

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
      expect(painter.debugFades.opacityNear(key, const Offset(200, 200)),
          lessThan(1),
          reason: 'the evicted label eases out instead of blinking away');
      painter.dispose();
    });
  });

  group('two copies of one label in one frame', () {
    test('draw once, whichever copy wins collision', () {
      // A zoom crossing (and any tile seam) offers the same label twice
      // for a few frames; the collision pass keeps exactly one.
      for (final arrivingFirst in [true, false]) {
        final drawn = _paint([
          _placedAt(_symbol(layer),
              anchor: Offset(200, arrivingFirst ? 199.7 : 200.3)),
          _placedAt(_symbol(layer), anchor: const Offset(200, 200), order: 1),
        ]);
        expect(drawn, hasLength(1), reason: 'the two copies collide');
      }
    });
  });

  group('drawnLabels', () {
    test('keeps only what the last frame drew, in order', () {
      final a = _symbol(layer, text: 'A');
      final b = _symbol(layer, text: 'B');
      final c = _symbol(layer, text: 'C');
      expect(drawnLabels([a, b, c], {c, a}), [a, c]);
    });

    test('returns the input list itself when everything was drawn', () {
      final a = _symbol(layer);
      final cohort = [a];
      expect(identical(drawnLabels(cohort, {a}), cohort), isTrue);
    });

    test('nothing drawn: the cohort is emptied', () {
      expect(drawnLabels([_symbol(layer)], const {}), isEmpty);
    });

    test('membership is by identity, not label equality', () {
      // Two instances of the same feature (seam twins) are distinct
      // candidates; drawing one must not pin the other.
      final drawnTwin = _symbol(layer);
      final otherTwin = _symbol(layer);
      expect(drawnLabels([otherTwin], {drawnTwin}), isEmpty);
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
      final pinned = drawnLabels(cohort, {for (final p in drawn) p.instance});
      expect(
        _paint([for (final s in pinned) _placedAt(s)], styleZoom: 12.9),
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
