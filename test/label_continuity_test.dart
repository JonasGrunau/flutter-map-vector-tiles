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
}) =>
    SymbolInstance(
      layer: layer,
      layerIndex: layerIndex,
      anchor: anchor,
      angle: 0,
      alongLine: false,
      text: text,
      iconName: iconName,
      sortKey: 0,
      properties: const {},
      geometryType: 'Point',
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
/// frames closer together than that replay the last decision.
///
/// [generation] defaults to one derived from the offered instances,
/// modelling the layer's contract — it bumps its placement generation
/// whenever the candidate set changes, so a story that swaps a level's
/// labels in gets a real placement pass rather than a frozen one. Pass
/// it explicitly to hold the set constant across frames.
List<PlacedSymbol> _frame(
  LabelPainter painter,
  List<PlacedSymbol> symbols, {
  double styleZoom = 14,
  DateTime? now,
  int? generation,
}) {
  final recorder = ui.PictureRecorder();
  final drawn = painter.paint(
    canvas: ui.Canvas(recorder),
    screenSize: const Size(400, 400),
    styleZoom: styleZoom,
    symbols: symbols,
    labelFadeDuration: now == null ? Duration.zero : _fadeDuration,
    placementGeneration: generation ?? _generationOf(symbols),
    now: now,
  );
  recorder.endRecording().dispose();
  return drawn;
}

/// A placement generation that changes exactly when the offered
/// instances do.
int _generationOf(List<PlacedSymbol> symbols) => Object.hashAll(
    [for (final symbol in symbols) identityHashCode(symbol.instance)]);

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
      expect(tracker.show('k'), 0, reason: 'no time has elapsed yet');
      expect(tracker.anyActive, isTrue);

      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.show('k'), 0.5);

      tracker.beginFrame(_at(100), _fadeDuration);
      expect(tracker.show('k'), 1);
      tracker.sweep((_, __) => fail('nothing is fading out'));
      expect(tracker.anyActive, isFalse, reason: 'the fade has finished');
    });

    test('a key shown every frame stays at one', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show('k');
      tracker.beginFrame(_at(500), _fadeDuration);
      expect(tracker.show('k'), 1, reason: 'a long gap completes the fade');
      tracker.beginFrame(_at(516), _fadeDuration);
      expect(tracker.show('k'), 1);
    });

    test('an unshown key fades out through the sweep and is dropped', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show('k');
      tracker.beginFrame(_at(100), _fadeDuration);
      tracker.show('k'); // fully visible

      final fading = <double>[];
      tracker.beginFrame(_at(125), _fadeDuration);
      tracker.sweep((key, opacity) => fading.add(opacity));
      tracker.beginFrame(_at(150), _fadeDuration);
      tracker.sweep((key, opacity) => fading.add(opacity));
      expect(fading, [0.75, 0.5]);
      expect(tracker.isTracked('k'), isTrue);
      expect(tracker.anyActive, isTrue);

      tracker.beginFrame(_at(250), _fadeDuration);
      tracker.sweep((_, __) => fail('the fade has completed'));
      expect(tracker.isTracked('k'), isFalse, reason: 'self-pruning');
      expect(tracker.anyActive, isFalse);
    });

    test('a key re-shown mid-fade-out resumes from its current opacity', () {
      // The anti-blink property: a label briefly unplaced — a republish,
      // a lost frame of collision, a level swap — dips instead of
      // restarting from zero and never cross-fades against itself.
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show('k');
      tracker.beginFrame(_at(100), _fadeDuration);
      tracker.show('k');
      tracker.beginFrame(_at(150), _fadeDuration);
      tracker.sweep((_, __) {}); // down to 0.5
      tracker.beginFrame(_at(175), _fadeDuration);
      expect(tracker.show('k'), 0.75, reason: 'rising again from 0.5');
    });

    test('is idempotent within a frame', () {
      // Seam twins and the retained copy of a carried-over label all
      // show the same key; only the first call advances it.
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show('k');
      tracker.beginFrame(_at(50), _fadeDuration);
      expect(tracker.show('k'), 0.5);
      expect(tracker.show('k'), 0.5);
      tracker.beginFrame(_at(100), _fadeDuration);
      expect(tracker.show('k'), 1);
    });

    test('a zero duration completes everything immediately', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), Duration.zero);
      tracker.show('k');
      tracker.beginFrame(_at(1), Duration.zero);
      expect(tracker.show('k'), 1);
      tracker.beginFrame(_at(2), Duration.zero);
      tracker.sweep((_, __) => fail('a zero duration never draws ghosts'));
      expect(tracker.isTracked('k'), isFalse);
    });

    test('clear forgets everything', () {
      final tracker = LabelFadeTracker();
      tracker.beginFrame(_at(0), _fadeDuration);
      tracker.show('k');
      tracker.clear();
      expect(tracker.isTracked('k'), isFalse);
      expect(tracker.anyActive, isFalse);
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
      expect(place(throttle, 50), isFalse);
      expect(throttle.deferred, isTrue, reason: 'a pass is owed');
      expect(place(throttle, 100), isTrue);
      expect(throttle.deferred, isFalse);
      // The interval runs from the last pass, not from fixed multiples.
      expect(place(throttle, 150), isFalse);
      expect(place(throttle, 200), isTrue);
    });

    test('a changed candidate set places without waiting', () {
      final throttle = PlacementThrottle();
      expect(place(throttle, 0), isTrue);
      expect(place(throttle, 10, generation: 1), isTrue,
          reason: 'a tile just published labels — they must not wait out '
              'the interval invisible');
      expect(place(throttle, 20, generation: 1), isFalse);
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
      expect(painter.debugFades.opacityOf(key), 1);

      // Both copies compete for the frames the levels overlap …
      final overlap = _frame(
          painter, [_placedAt(arriving), _placedAt(outgoing, order: 1)],
          now: _at(116));
      expect(overlap, hasLength(1), reason: 'the two copies collide');
      expect(painter.debugFades.opacityOf(key), 1, reason: 'no restart');

      // … and the hand-over to the new copy alone changes nothing.
      _frame(painter, [_placedAt(arriving)], now: _at(133));
      expect(painter.debugFades.opacityOf(key), 1);
      expect(painter.hasActiveFades, isFalse);
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
      final crossfade = _frame(
        painter,
        [
          _placedAt(replacement),
          _placedAt(departing, order: 1, ghostOnly: true)
        ],
        now: _at(150),
      );
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
      const generation = 7;

      List<PlacedSymbol> frame(int ms, double gap) => _frame(
            painter,
            [
              _placedAt(west, anchor: Offset(200 - gap, 200)),
              _placedAt(east, anchor: Offset(200 + gap, 200), order: 1),
            ],
            now: _at(ms),
            generation: generation,
          );

      expect(frame(0, 80).map((p) => p.instance).toSet(), {west, east});
      frame(100, 80); // a second pass; both are fully faded in by now

      expect(frame(150, 2).map((p) => p.instance).toSet(), {west, east},
          reason: 'the decision taken at the last pass still stands');
      expect(painter.placementPending, isTrue,
          reason: 'the layer keeps painting until the pass it owes runs');

      // The next pass resolves the overlap — once, and through a fade.
      frame(200, 2);
      expect(painter.debugFades.opacityOf(west.continuityKey), 1);
      expect(painter.debugFades.opacityOf(east.continuityKey), lessThan(1),
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
      const generation = 3;

      final first = _frame(
        painter,
        [
          _placedAt(north, anchor: const Offset(200, 198)),
          _placedAt(south, anchor: const Offset(200, 202), order: 1),
        ],
        now: _at(0),
        generation: generation,
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
        generation: generation,
      );
      expect(panned.map((p) => p.instance), [north],
          reason: 'the name stays on the side of the street it is already on');
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
