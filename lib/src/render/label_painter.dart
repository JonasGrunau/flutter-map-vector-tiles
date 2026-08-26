import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

import '../cache/lru_cache.dart';
import '../style/expression.dart';
import '../style/sprite_atlas.dart';
import '../style/theme.dart';
import 'fade.dart';
import 'label_continuity.dart';
import 'symbol_layouter.dart';

/// The affine transform from a display tile's logical coordinates to
/// screen pixels: uniform scale, rotation, translation. Lengths scale
/// by [scale]; angles shift by [rotation].
class TileTransform {
  final Offset origin;
  final double scale;
  final double rotation;
  final double _cosR;
  final double _sinR;

  TileTransform({
    required this.origin,
    required this.scale,
    required this.rotation,
  })  : _cosR = math.cos(rotation),
        _sinR = math.sin(rotation);

  Offset apply(Offset p) => Offset(
        origin.dx + (p.dx * _cosR - p.dy * _sinR) * scale,
        origin.dy + (p.dx * _sinR + p.dy * _cosR) * scale,
      );
}

/// A symbol candidate projected to screen coordinates.
class PlacedSymbol {
  final SymbolInstance instance;
  final Offset screenAnchor;

  /// Screen-space baseline angle for along-line labels (radians).
  final double screenAngle;

  /// Tile→screen transform, present for along-line symbols so curved
  /// text can project the line geometry.
  final TileTransform? transform;

  /// A ghost-only candidate never competes for placement: it exists
  /// solely as the drawable behind a label that is fading out, in case
  /// no live instance of its continuity key is placed this frame. The
  /// caller marks candidates from tiles that have stopped contributing
  /// labels (a retained level the new one already covers, or a disposed
  /// tile's parked cohort) this way.
  final bool ghostOnly;

  /// Insertion index within the frame's symbol list, the final
  /// placement tiebreaker: the caller adds current-level tiles before
  /// retained previous-level ones, so on an exact tie the current
  /// level's copy wins deterministically (`List.sort` is not stable).
  final int order;

  /// Whether this candidate's label is steadily visible on screen right
  /// now — set by the painter on placing frames, and sorted ahead of
  /// newcomers *within its style layer* so a label that is on screen is
  /// never evicted by a same-layer arrival competing for its space; the
  /// newcomer waits until the space is genuinely free. A higher style
  /// layer still wins, so the style author's hierarchy holds. MapLibre
  /// has no such rule — its labels do drop out and return while zooming,
  /// smoothed only by fades — and this is a deliberate divergence:
  /// during a crossing the arriving level's data re-ranks neighbouring
  /// symbols constantly, and re-electing winners from scratch each pass
  /// turns every rank flip into a visible blink.
  bool incumbent = false;

  PlacedSymbol({
    required this.instance,
    required this.screenAnchor,
    required this.screenAngle,
    this.transform,
    this.ghostOnly = false,
    this.order = 0,
  });
}

/// One label a paint actually drew, as reported to
/// [LabelPainter.debugDrawnProbe]: its continuity key, its screen
/// anchor, the opacity it drew at, whether it was a fade-out ghost,
/// and whether it is an along-line label.
typedef DrawnLabelRecord = ({
  Object key,
  Offset position,
  double opacity,
  bool ghost,
  bool alongLine,
});

/// Draws all visible labels/icons in one screen-space pass per frame,
/// with global collision detection across tile borders. Text stays
/// crisp at fractional zoom and upright under rotation.
class LabelPainter {
  /// Cache capacities, sized to survive one dense-city screen of
  /// distinct labels: when the per-frame distinct-label count exceeds
  /// the cache, every frame evicts entries the same frame still needs
  /// and the whole screen re-lays-out every frame. The memory ceiling is
  /// only reached on screens that actually carry that many labels; if a
  /// byte budget is ever needed, `LruCache.maxCost` is the ready hook.
  static const int textCacheEntries = 2500;
  static const int glyphCacheEntries = 4000;

  /// Steps per zoom level for the label eval zoom. Between steps every
  /// per-instance memo and zoom-only expression memo hits, so a pinch
  /// frame costs no evaluation at all; at a step the evaluated sizes
  /// drift by ~0.1-0.2px for typical `text-size` ramps — invisible, and
  /// since text is shaped at [_shapeSize] and drawn scaled, a step never
  /// re-shapes anything either.
  static const double _zoomStep = 8;

  /// Reference font size all text is shaped at. Drawing applies
  /// `evaluated size / _shapeSize` through the canvas transform, so one
  /// shaped paragraph serves every zoom: layout inputs are em-based
  /// (`letterSpacing`, `maxWidth` scale with the font size) and glyphs
  /// rasterize at device scale under the transform, so scaled text is
  /// pixel-equivalent to re-shaping at the evaluated size — the "crisp
  /// at fractional zoom" contract holds.
  static const double _shapeSize = 16.0;

  /// Evaluated text below this size is skipped like the icon path's
  /// `iconSize > 0` guard, instead of being clamped up to a visible
  /// floor: a style that shrinks labels toward zero must not flood the
  /// collision grid with tiny-but-visible text.
  static const double _minVisibleTextSize = 1.0;

  /// Slack added to a fade layer's bounds, covering halo strokes and the
  /// widest text halo a style is likely to ask for.
  static const double _fadeLayerPadding = 16.0;

  /// Draw opacities are quantized to this many steps so translucent
  /// symbols group into a handful of `saveLayer` buckets instead of one
  /// per label. Shared with the widget layer's fade-progress
  /// quantization — see [labelOpacitySteps].
  static const int _opacitySteps = labelOpacitySteps;

  /// Width, in style zoom levels, of the ramp that fades a symbol out
  /// approaching a declared edge of its layer's zoom range.
  static const double _zoomFadeWindow = 0.25;

  /// Ceiling on how stale a frozen placement decision may get. The
  /// interval otherwise follows the label fade duration — a decision
  /// change always gets to finish fading before the next one can be
  /// taken, which is the relationship MapLibre ties the two by — but a
  /// style asking for second-long fades should not also freeze
  /// collision for a second.
  static const Duration _maxPlacementInterval = Duration(milliseconds: 300);

  /// How far past vertical an along-line label's direction must swing
  /// before its reading direction flips, as a cosine of the on-screen
  /// line angle (≈4.6°). See [_readsBackwards].
  static const double _flipHysteresis = 0.08;

  /// Paragraph shapings performed (cache misses); for tests asserting
  /// that zoom motion does not re-shape text.
  @visibleForTesting
  int debugShapedTextCount = 0;

  /// UI-thread microseconds spent inside [paint], summed across all
  /// painters — static so the bench can diff it per frame without a
  /// reference to the layer's painter instance.
  @visibleForTesting
  static int debugPaintMicros = 0;

  /// [debugPaintMicros] split further, for attributing label-pass
  /// spikes: the candidate loop of frames that ran a full placement
  /// pass, the loop of frames that replayed the frozen decision, the
  /// candidate sort every frame pays, and the paragraph shaping done on
  /// text-cache misses (a subset of the loop time). Static like
  /// [debugPaintMicros]; the bench diffs them per frame.
  @visibleForTesting
  static int debugPlaceMicros = 0;
  @visibleForTesting
  static int debugReplayMicros = 0;
  @visibleForTesting
  static int debugSortMicros = 0;
  @visibleForTesting
  static int debugShapeMicros = 0;

  /// Frames that ran a full placement pass, for spike-rate arithmetic.
  @visibleForTesting
  static int debugPlacingFrames = 0;

  /// Bench-only observer: when set, every [paint] reports what it drew
  /// — ghosts included, zoom-retired invisible symbols excluded — after
  /// collision and fades. This is the observable the label-stability
  /// metrics in `bench/` (pop-ins, pop-outs, blinks) are computed from.
  /// Static like the timing counters; null in production, where the
  /// cost is one null check per frame.
  @visibleForTesting
  static void Function(double styleZoom, List<DrawnLabelRecord> drawn)?
      debugDrawnProbe;

  /// The fade sweep (ghost lookup + prepare per fading key) and the
  /// final drawing of the placed symbols — the two [paint] phases after
  /// the candidate loop, completing the [debugPaintMicros] breakdown.
  @visibleForTesting
  static int debugSweepMicros = 0;
  @visibleForTesting
  static int debugDrawMicros = 0;

  @visibleForTesting
  int get debugTextCacheLength => _textCache.length;

  late final _textCache = LruCache<String, _LaidOutText>(
      maxEntries: textCacheEntries,
      onEvict: (_, text) => _retired.add(text.dispose));
  late final _glyphCache = LruCache<String, _GlyphText>(
      maxEntries: glyphCacheEntries,
      onEvict: (_, glyph) => _retired.add(glyph.dispose));

  /// Evicted entries whose `TextPainter`s may still be referenced by
  /// symbols prepared earlier in the same frame — disposed at the start
  /// of the next [paint] instead of at eviction time.
  final _retired = <void Function()>[];

  void _disposeRetired() {
    for (final dispose in _retired) {
      dispose();
    }
    _retired.clear();
  }

  /// Per-label fade state — one opacity per continuity key, advanced
  /// every painted frame. See [LabelFadeTracker].
  final _fades = LabelFadeTracker();

  /// The fade tracker, for tests that assert fade state across frames.
  @visibleForTesting
  LabelFadeTracker get debugFades => _fades;

  /// Fallback drawables for the fade-out, keeping *every* unplaced
  /// candidate of a tracked key: fades are matched by position (see
  /// [LabelFadeTracker.showAt]), so the sweep draws each fading sitting
  /// from the candidate nearest it, instead of the priority-first one —
  /// which for a street with several repeats, or a key several POIs
  /// share, could be a different label entirely, teleporting the ghost.
  final _sittingFallbacks = <Object, List<PlacedSymbol>>{};

  /// How far from a fading sitting its ghost's stand-in candidate may
  /// be. Beyond this, drawing the "nearest" candidate would move the
  /// label — the artefact the positional fades remove — so the sitting
  /// finishes its fade undrawn instead.
  static const double _ghostRadius = LabelFadeTracker.matchRadius * 2;

  /// When the collision pass re-runs; between passes its decision is
  /// replayed. See [PlacementThrottle].
  final _placement = PlacementThrottle();

  /// The instances that won space at the last full pass — the frozen
  /// decision itself. Between passes only these compete (everything
  /// else is skipped before it is even laid out), and at the next pass
  /// they are tried ahead of the other candidates of their own label,
  /// so a label that can be drawn from two instances keeps the one it
  /// already occupies. `SymbolInstance` does not override `==`, so this
  /// is an identity set.
  final _winners = <SymbolInstance>{};

  /// The placement choices each label is sitting on — kept here rather
  /// than on the instances, which are replaced under a label that never
  /// left the screen. See [PlacementMemory].
  final _memory = PlacementMemory();

  /// The placement memory, for tests that assert a label's remembered
  /// choices across frames.
  @visibleForTesting
  PlacementMemory get debugPlacement => _memory;

  /// Whether the last paint left any label fade mid-flight. The widget
  /// keeps its fade ticker running while this is true — placement (and
  /// with it a fade's start or end) can change on any painted frame,
  /// not only on a publish.
  bool get hasActiveFades => _fades.anyActive;

  /// Whether a placement pass is still owed because the last frame
  /// replayed a frozen decision. The widget keeps scheduling frames
  /// while this is true, so the decision taken during a gesture is
  /// re-evaluated once at the camera the gesture ended at.
  bool get placementPending => _placement.deferred;

  /// Forgets all fade and placement state — for theme/provider swaps,
  /// where every symbol instance is replaced and layer indices change
  /// meaning.
  void reset() {
    _fades.clear();
    _sittingFallbacks.clear();
    _winners.clear();
    _memory.clear();
    _placement.reset();
  }

  /// How often the collision pass re-runs at this fade duration.
  @visibleForTesting
  static Duration placementInterval(Duration labelFadeDuration) =>
      labelFadeDuration < _maxPlacementInterval
          ? labelFadeDuration
          : _maxPlacementInterval;

  /// [styleZoom] is the fractional style zoom used for size expressions.
  ///
  /// Returns the symbols that survived collision and were drawn, in
  /// draw order — useful for tests and future hit-testing.
  /// [symbols] is sorted in place into placement-priority order; the
  /// caller rebuilds the list per frame, so a defensive copy here would
  /// only add allocation to the hottest per-frame path.
  /// [devicePixelRatio] only sharpens SDF icon edges; it does not scale
  /// anything, so 1 is a safe default.
  ///
  /// A [labelFadeDuration] above zero enables the per-label fades: every
  /// placed symbol draws at its continuity key's opacity (rising toward
  /// 1), and keys that stopped being placed draw one more ghost per
  /// frame — no collision claim — while they ramp to zero. It also sets
  /// how often the collision pass re-runs (see [placementInterval]);
  /// frames in between replay the last decision — a changed candidate
  /// set (tiles published or expired) is picked up by the next due
  /// pass, at most one interval away, never sooner (see
  /// [PlacementThrottle.shouldPlace] for why). [now] feeds both
  /// clocks and defaults to the wall clock.
  List<PlacedSymbol> paint({
    required Canvas canvas,
    required Size screenSize,
    required double styleZoom,
    required List<PlacedSymbol> symbols,
    SpriteAtlas? sprites,
    double devicePixelRatio = 1,
    Duration labelFadeDuration = Duration.zero,
    DateTime? now,
  }) {
    developer.Timeline.startSync('VT labels');
    final stopwatch = Stopwatch()..start();
    try {
      return _paint(canvas, screenSize, styleZoom, symbols, sprites,
          devicePixelRatio, labelFadeDuration, now ?? DateTime.now());
    } finally {
      debugPaintMicros += stopwatch.elapsedMicroseconds;
      developer.Timeline.finishSync();
    }
  }

  List<PlacedSymbol> _paint(
    Canvas canvas,
    Size screenSize,
    double styleZoom,
    List<PlacedSymbol> symbols,
    SpriteAtlas? sprites,
    double devicePixelRatio,
    Duration labelFadeDuration,
    DateTime now,
  ) {
    _disposeRetired();
    final fades = labelFadeDuration > Duration.zero;
    if (fades) _fades.beginFrame(now, labelFadeDuration);
    // Whether this frame decides placement afresh or replays the last
    // decision. Layout happens either way — only the winners move on a
    // replay frame, not the choice of who they are.
    final placing = _placement.shouldPlace(
      now: now,
      interval: placementInterval(labelFadeDuration),
      screenSize: screenSize,
    );
    _memory.beginFrame(prune: placing);
    // Quantize the eval zoom to [_zoomStep] steps: the per-instance
    // memo and the zoom-only expression memos compare against the exact
    // zoom, so evaluating at the raw fractional zoom would miss every
    // one of them on every frame of a pinch. Integer zooms are fixed
    // points of the rounding.
    final zoom = (styleZoom * _zoomStep).round() / _zoomStep;
    // Replaying frames claim no space: the decision was taken at the
    // last pass and holds until the next one. A real index here would
    // re-decide the pairs the camera has drifted together since — which
    // on a zoom-out is most of them, and re-deciding is the flicker
    // this exists to remove. Slight overlap between passes is the trade
    // MapLibre makes for the same reason.
    final collision =
        placing ? _CollisionIndex(screenSize) : _CollisionIndex.permissive();
    // Placement priority: topmost style layers first (they win space),
    // then incumbents — labels on screen right now, which a same-layer
    // newcomer must not evict (see [PlacedSymbol.incumbent]) — then by
    // symbol-sort-key, then by y, then by insertion order — the last
    // term keeps the non-stable sort deterministic and lets
    // current-level tiles beat retained ones on exact ties. The
    // incumbent term only matters on placing frames: the flags are
    // freshly set there and default-false on every rebuilt candidate
    // list in between.
    final sortStopwatch = Stopwatch()..start();
    if (placing) _flagIncumbents(symbols, fades);
    final candidates = symbols
      ..sort((a, b) {
        final byLayer = b.instance.layerIndex - a.instance.layerIndex;
        if (byLayer != 0) return byLayer;
        if (a.incumbent != b.incumbent) return a.incumbent ? -1 : 1;
        final bySortKey = a.instance.sortKey.compareTo(b.instance.sortKey);
        if (bySortKey != 0) return bySortKey;
        final byY = a.screenAnchor.dy.compareTo(b.screenAnchor.dy);
        if (byY != 0) return byY;
        return a.order - b.order;
      });
    debugSortMicros += sortStopwatch.elapsedMicroseconds;
    if (placing) debugPlacingFrames++;
    if (placing && _winners.isNotEmpty) _promoteIncumbents(candidates);

    final toDraw = <_DrawableSymbol>[];
    var anyFading = false;
    if (placing) _winners.clear();
    final loopStopwatch = Stopwatch()..start();
    for (final candidate in candidates) {
      if (candidate.ghostOnly) {
        // Never competes for placement — only remembered, in case its
        // key is fading out and nothing else can draw it.
        if (fades) _recordFallback(candidate);
        continue;
      }
      if (!placing && !_winners.contains(candidate.instance)) {
        // Replaying: the frozen decision says this candidate is not on
        // screen, so it is not even laid out. On a dense screen most
        // candidates lose, which is most of the label pass's work.
        if (fades) _recordFallback(candidate);
        continue;
      }
      final drawable =
          _prepare(candidate, zoom, styleZoom, collision, sprites, screenSize);
      if (drawable == null) {
        // A candidate that lost (collision, zoom gate) may still be the
        // only instance around of a key mid-fade-out.
        if (fades) _recordFallback(candidate);
        continue;
      }
      if (placing) _winners.add(candidate.instance);
      // The label's fade and its layer's zoom-range ramp compound: a
      // label appearing near its layer's maxzoom is subject to both.
      final ramp = zoomRangeOpacity(candidate.instance.layer, styleZoom);
      var fade = 1.0;
      if (fades) {
        // Fades are per sitting — one state per (key, position). Two
        // POIs sharing a name or an icon fade independently instead of
        // popping while the other holds their key's opacity; an
        // along-line label whose anchors are re-spaced per display
        // layout fades in at the new position while the old one fades
        // out, instead of inheriting its opacity and teleporting.
        fade = _fades.showAt(
            candidate.instance.continuityKey, candidate.screenAnchor);
        // A key on its first frame has no elapsed fade time yet; one
        // step keeps it from starting invisible. Every placed label
        // paints something, on every frame it is placed: a label held
        // at zero while still winning collision space is a hole in the
        // map that nothing else may fill, and one frame of missed
        // placement sweeps it back out of the tracker entirely.
        if (fade <= 0) fade = 1 / _opacitySteps;
      }
      drawable.opacity = ramp <= 0 ? 0 : _quantizeOpacity(fade * ramp);
      toDraw.add(drawable);
      anyFading |= drawable.opacity < 1;
    }
    if (placing) {
      debugPlaceMicros += loopStopwatch.elapsedMicroseconds;
    } else {
      debugReplayMicros += loopStopwatch.elapsedMicroseconds;
    }
    final sweepStopwatch = Stopwatch()..start();
    if (fades) {
      // Keys placed until recently but not this frame fade out, drawing
      // one ghost each: laid out (the zoom gate bypassed — a departing
      // label is often departing *because* the gate just cut its layer)
      // but claiming no collision space, so whatever takes the spot
      // fades in over the ghost instead of waiting for it to expire and
      // popping.
      _CollisionIndex? permissive;
      _fades.sweep((key, position, opacity) {
        // Each fading sitting takes the candidate nearest its position,
        // and only within [_ghostRadius] — a farther stand-in would
        // move the fading label, which is the artefact the positional
        // fades exist to remove.
        final fallback = _nearestCandidate(_sittingFallbacks[key], position);
        if (fallback == null) return null;
        final ramp = zoomRangeOpacity(fallback.instance.layer, styleZoom);
        if (ramp <= 0) return null;
        // Floored, mirroring the fade-in's implicit ceil: a departing
        // label reaches zero instead of lingering one step above it.
        final ghostOpacity =
            (opacity * ramp * _opacitySteps).floor() / _opacitySteps;
        if (ghostOpacity <= 0) return null;
        final drawable = _prepare(fallback, zoom, styleZoom,
            permissive ??= _CollisionIndex.permissive(), sprites, screenSize,
            gateZoom: false);
        if (drawable == null) return null;
        drawable.opacity = ghostOpacity;
        drawable.isGhost = true;
        toDraw.add(drawable);
        anyFading = true;
        // The tracker moves the sitting to where its ghost was drawn,
        // so the fade keeps tracking the camera.
        return fallback.screenAnchor;
      },
          // Replay frames hold: an un-shown key mid-interval usually
          // means its instance was replaced (republish, level swap), and
          // the successor is only picked up at the next due pass —
          // decaying through that window fades a label into itself.
          // Only a pass may start a fade-out.
          hold: !placing);
      _sittingFallbacks.clear();
    }
    debugSweepMicros += sweepStopwatch.elapsedMicroseconds;
    final probe = debugDrawnProbe;
    if (probe != null) {
      // Before the draw stopwatch, so the probe's own cost never lands
      // in the draw split it exists to help interpret.
      probe(styleZoom, [
        for (final drawable in toDraw)
          if (drawable.opacity > 0)
            (
              key: drawable.symbol.instance.continuityKey,
              position: drawable.symbol.screenAnchor,
              opacity: drawable.opacity,
              ghost: drawable.isGhost,
              alongLine: drawable.symbol.instance.alongLine,
            )
      ]);
    }
    final drawStopwatch = Stopwatch()..start();
    // Draw bottom style layers first so upper layers paint on top; the
    // insertion-order tiebreaker keeps draw order stable across frames.
    toDraw.sort((a, b) {
      final byLayer =
          a.symbol.instance.layerIndex.compareTo(b.symbol.instance.layerIndex);
      if (byLayer != 0) return byLayer;
      return a.symbol.order - b.symbol.order;
    });
    final drawn = <PlacedSymbol>[];
    if (!anyFading) {
      for (final drawable in toDraw) {
        drawable.draw(canvas, devicePixelRatio);
        drawn.add(drawable.symbol);
      }
      debugDrawMicros += drawStopwatch.elapsedMicroseconds;
      return drawn;
    }

    // Fading symbols draw through one translucent layer per opacity
    // bucket instead of re-shaping text at each fade step: colours are
    // baked into the paragraphs, so per-label opacity would rotate the
    // text cache, while a saveLayer per bucket costs one render pass
    // for the few frames a fade is in flight. Opacities are quantized
    // onto the [_opacitySteps] grid, so the bucket count stays small.
    // Opaque symbols first (in layer order), fading symbols on top.
    // A symbol the zoom ramp has retired keeps the collision space it
    // reserved in [_prepare] — placements stay put across the last step
    // of the ramp — but paints nothing.
    for (final drawable in toDraw) {
      if (drawable.opacity >= 1) {
        drawable.draw(canvas, devicePixelRatio);
        drawn.add(drawable.symbol);
      }
    }
    // Grouped in one pass, with each bucket's painted extent, so the
    // layer below covers only what it draws: an unbounded saveLayer
    // allocates a full-viewport offscreen target, and there is one per
    // bucket per frame for the whole fade.
    final buckets = <double, List<_DrawableSymbol>>{};
    for (final drawable in toDraw) {
      final opacity = drawable.opacity;
      if (opacity > 0 && opacity < 1) (buckets[opacity] ??= []).add(drawable);
    }
    for (final opacity in buckets.keys.toList()..sort()) {
      final bucket = buckets[opacity]!;
      var extent = bucket.first.bounds;
      for (final drawable in bucket.skip(1)) {
        extent = extent.expandToInclude(drawable.bounds);
      }
      canvas.saveLayer(
        // Padded for halo bleed: the bounds are tight, and a clipped
        // halo would be a visible artefact. The canvas intersects this
        // with the current clip, so no screen bound is needed here.
        extent.inflate(_fadeLayerPadding),
        Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
      );
      for (final drawable in bucket) {
        drawable.draw(canvas, devicePixelRatio);
        drawn.add(drawable.symbol);
      }
      canvas.restore();
    }
    debugDrawMicros += drawStopwatch.elapsedMicroseconds;
    return drawn;
  }

  /// Marks the candidates whose label is steadily visible on screen, so
  /// the priority sort tries them ahead of same-layer newcomers — see
  /// [PlacedSymbol.incumbent]. Placing frames only; the flag defaults
  /// to false on every rebuilt candidate list in between.
  ///
  /// Two recognisers, because each covers the other's blind spot. The
  /// winner set matches by instance identity — exact, but instances are
  /// replaced wholesale by every republish and level swap, precisely
  /// when incumbency matters most. The fade tracker matches by key and
  /// position at full opacity — which survives instance replacement,
  /// but exists only while fades are enabled.
  void _flagIncumbents(List<PlacedSymbol> candidates, bool fades) {
    for (final candidate in candidates) {
      candidate.incumbent = !candidate.ghostOnly &&
          (_winners.contains(candidate.instance) ||
              (fades &&
                  _fades.isVisibleAt(candidate.instance.continuityKey,
                      candidate.screenAnchor)));
    }
  }

  /// Moves each label's sitting tenant ahead of its rivals *within its
  /// own continuity key*, in place.
  ///
  /// One label often has several candidates on screen: a street name
  /// repeats along its road and again on the parallel carriageway, and
  /// a zoom crossing puts the outgoing and arriving level's copies up
  /// at once. Which of them the priority sort puts first depends on the
  /// anchors' screen y, so a slow pan reorders them and the name jumps
  /// across the street and back. Trying the one already drawn first
  /// pins it there for as long as it still fits.
  ///
  /// Only the order *inside* a key changes: the key still competes for
  /// space at the position its best candidate earned, so this can never
  /// let one label outrank another. Each key is promoted at most once —
  /// with two candidates, which is the case that matters, that is
  /// exactly right, and with more it still puts a tenant first.
  void _promoteIncumbents(List<PlacedSymbol> candidates) {
    Map<Object, int>? firstRival;
    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      if (candidate.ghostOnly) continue;
      final key = candidate.instance.continuityKey;
      if (!_winners.contains(candidate.instance)) {
        (firstRival ??= {})[key] ??= i;
        continue;
      }
      final rival = firstRival?.remove(key);
      if (rival == null) continue; // already first among its key
      candidates[i] = candidates[rival];
      candidates[rival] = candidate;
    }
  }

  /// Remembers [candidate] as a drawable to fade its key out with,
  /// should the sweep find one of that key's sittings unplaced this
  /// frame. Only tracked keys can fade. Every candidate is kept: the
  /// sweep picks the one nearest each fading sitting.
  void _recordFallback(PlacedSymbol candidate) {
    final key = candidate.instance.continuityKey;
    if (!_fades.isTracked(key)) return;
    (_sittingFallbacks[key] ??= []).add(candidate);
  }

  /// The candidate in [candidates] nearest [position], within
  /// [_ghostRadius]; null when none is (or the list is).
  static PlacedSymbol? _nearestCandidate(
      List<PlacedSymbol>? candidates, Offset position) {
    if (candidates == null) return null;
    PlacedSymbol? best;
    var bestDistance = _ghostRadius * _ghostRadius;
    for (final candidate in candidates) {
      final distance = (candidate.screenAnchor - position).distanceSquared;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    return best;
  }

  /// Opacity [layer]'s zoom range gives a symbol at [styleZoom]: 1
  /// everywhere except the last [_zoomFadeWindow] before a declared
  /// `maxzoom`, over which it ramps to 0. Zooming in past the threshold
  /// then dissolves the label instead of snapping it away, and because
  /// the ramp is a function of zoom alone it is exactly reversible —
  /// zoom back out and the label ramps in again — with no per-symbol
  /// history to keep.
  ///
  /// The ramp lives *inside* the range and reaches 0 at the threshold,
  /// so [ThemeLayer.coversZoom] stays the source of truth in [_prepare]
  /// and nothing paints outside `[minzoom, maxzoom)`.
  ///
  /// Only `maxzoom` ramps. It is exclusive, so the window covers zooms
  /// where the style is about to drop the label anyway. `minzoom` is
  /// inclusive: a symmetric ramp there would render a `minzoom: 14`
  /// layer *invisible* on a map resting at exactly zoom 14, which is
  /// both the common resting case and the first zoom the style asks for
  /// that label. The ramp may dim a symbol the style is about to
  /// remove, never one the style says is fully visible.
  ///
  /// [ThemeLayer.defaultMaxzoom] is what the reader substitutes for an
  /// absent bound — an absence, not an edge the style drew, so it never
  /// ramps.
  @visibleForTesting
  static double zoomRangeOpacity(ThemeLayer layer, double styleZoom) {
    if (layer.maxzoom >= ThemeLayer.defaultMaxzoom) return 1;
    // A band narrower than the window shrinks the ramp to fit: the ramp
    // must still start at 1 at the inclusive minzoom, or a layer with a
    // sub-window band would never reach full opacity anywhere in its
    // declared range.
    final window = math.min(_zoomFadeWindow, layer.maxzoom - layer.minzoom);
    if (window <= 0) return 1; // degenerate band: coversZoom rejects it
    final opacity = (layer.maxzoom - styleZoom) / window;
    if (opacity >= 1) return 1;
    // Floored, so the ramp reaches exactly 0 at the threshold and hands
    // over to the hard cut instead of vanishing from a visible step.
    return (opacity.clamp(0.0, 1.0) * _opacitySteps).floor() / _opacitySteps;
  }

  /// Quantizes a draw opacity onto the [_opacitySteps] grid, keeping
  /// anything still visible at least one step above zero: only a symbol
  /// [zoomRangeOpacity] has fully retired draws at 0.
  static double _quantizeOpacity(double opacity) => opacity <= 0
      ? 0
      : math.max(1, (opacity * _opacitySteps).round()) / _opacitySteps;

  /// Shapes the text (and, for curved along-line labels, the per-glyph
  /// painters) of [symbols] into the caches ahead of the first frame
  /// that draws them. Called from the render pump before a tile's
  /// symbols are published, so the shaping cost lands in the budgeted
  /// tick instead of the paint phase.
  ///
  /// Resumable: shaping a dense tile costs several times a frame's
  /// whole render budget (measured 2–9 ms per tile on a real city
  /// style), so the pump runs it in slices. Starts at [from] and stops
  /// once [outOfBudget] says the tick is spent, returning the index to
  /// resume at — `symbols.length` when the batch is done. Always shapes
  /// at least one label per call, so a caller arriving with no budget
  /// left still makes progress instead of spinning on one index.
  ///
  /// The caller must not publish [symbols] as placement candidates
  /// before this reports completion: the label pass shapes on a cache
  /// miss, so a half-shaped tile offered to it would move the rest of
  /// the cost straight back into paint, where there is no budget at all.
  int prewarm(
    List<SymbolInstance> symbols,
    double styleZoom, {
    int from = 0,
    bool Function()? outOfBudget,
  }) {
    final zoom = (styleZoom * _zoomStep).round() / _zoomStep;
    for (var i = from; i < symbols.length; i++) {
      if (i > from && (outOfBudget?.call() ?? false)) return i;
      final instance = symbols[i];
      if (instance.text.isEmpty) continue;
      final layer = instance.layer;
      final ctx = EvalContext(
        zoom: zoom,
        properties: instance.properties,
        geometryType: instance.geometryType,
        featureId: instance.featureId,
      );
      if (layer.textOpacity.eval(ctx) <= 0) continue;
      final size = layer.textSize.eval(ctx);
      // Written as a positive test, like the one in [_prepare]: a NaN
      // size — a style expression dividing by zero — fails `>=` and is
      // skipped, where `if (size < min) continue` would let it through
      // to shaping, which throws when it rounds the halo ratio.
      if (size >= _minVisibleTextSize) {
        final fontSize = size.clamp(_minVisibleTextSize, 96.0);
        final text = _layoutText(instance, layer, ctx, fontSize);
        // The per-grapheme work is the expensive half for road labels.
        if (instance.alongLine && instance.curveSafe && instance.path != null) {
          for (final cluster in text.clusters) {
            _glyphPainters(cluster.grapheme, text);
          }
        }
      }
    }
    return symbols.length;
  }

  /// [evalZoom] is quantized for the expression memos; [styleZoom] is
  /// the camera's exact fractional zoom and gates visibility, which is a
  /// discrete cut that must land where the style says it does.
  /// [gateZoom] is false only for fade-out ghosts, which draw one last
  /// ramp past the very cut that retired them (paired with a permissive
  /// [collision], since a ghost must not claim space either).
  _DrawableSymbol? _prepare(
    PlacedSymbol placed,
    double evalZoom,
    double styleZoom,
    _CollisionIndex collision,
    SpriteAtlas? sprites,
    Size screenSize, {
    bool gateZoom = true,
  }) {
    final instance = placed.instance;
    final layer = instance.layer;

    // Cull far off-screen anchors before any evaluation work.
    final anchor = placed.screenAnchor;
    if (anchor.dx < -150 ||
        anchor.dy < -150 ||
        anchor.dx > screenSize.width + 150 ||
        anchor.dy > screenSize.height + 150) {
      return null;
    }

    // The layer's zoom range is continuous (MapLibre semantics), while
    // layout gates only per integer band: a symbol stops painting the
    // moment the fractional style zoom leaves [minzoom, maxzoom) —
    // including symbols from retained previous-level tiles. Gated on the
    // exact zoom, not the quantized one: rounding would move the cut by
    // up to half a step, so labels would appear or vanish up to 1/16 of
    // a level away from the threshold the style declares.
    if (gateZoom && !layer.coversZoom(styleZoom)) return null;

    // What this label decided last time it was placed — by position, so
    // the instance that arrives with a new zoom level inherits what the
    // one it replaces was sitting on.
    final sitting = _memory.sitting(instance.continuityKey, anchor);

    final ctx = EvalContext(
      zoom: evalZoom,
      properties: instance.properties,
      geometryType: instance.geometryType,
      featureId: instance.featureId,
    );

    // A label the style has faded out is skipped rather than laid out:
    // reserving collision space for invisible text would suppress the
    // visible labels around it.
    //
    // A replaying frame decides no space, so it also re-reads the one
    // space decision that changes what is drawn rather than where:
    // `text-optional` text that lost its box at the last pass stays
    // dropped until the next one.
    _LaidOutText? text;
    var fontSize = _shapeSize;
    var textScale = 1.0;
    final replaying = collision.permissive;
    if (!replaying) sitting.textDropped = false;
    if (!(replaying && sitting.textDropped) &&
        instance.text.isNotEmpty &&
        layer.textOpacity.eval(ctx) > 0) {
      final size = layer.textSize.eval(ctx);
      if (size >= _minVisibleTextSize) {
        fontSize = size.clamp(_minVisibleTextSize, 96.0);
        textScale = fontSize / _shapeSize;
        text = _layoutText(instance, layer, ctx, fontSize);
      }
    }

    _DrawableIcon? icon;
    final iconName = instance.iconName;
    if (iconName != null && sprites != null) {
      final sprite = sprites[iconName];
      if (sprite != null) {
        final iconSize = layer.iconSize.eval(ctx);
        final opacity = layer.iconOpacity.eval(ctx).clamp(0.0, 1.0);
        if (iconSize > 0 && opacity > 0) {
          final w = sprite.width / sprite.pixelRatio * iconSize;
          final h = sprite.height / sprite.pixelRatio * iconSize;
          final offset = layer.iconOffset.eval(ctx);
          final dx = offset.isNotEmpty ? offset[0] * iconSize : 0.0;
          final dy = offset.length > 1 ? offset[1] * iconSize : 0.0;
          final rect = _anchoredRect(
              layer.iconAnchor.eval(ctx), anchor + Offset(dx, dy), w, h);
          icon = _DrawableIcon(
            atlas: sprites,
            sprite: sprite,
            rect: rect,
            opacity: opacity,
            // Only SDF sheets are recolourable; ordinary sprites already
            // carry their own colours.
            tint: sprite.sdf ? layer.iconColor.eval(ctx) : null,
            haloColor: sprite.sdf ? layer.iconHaloColor.eval(ctx) : null,
            haloWidth: sprite.sdf ? layer.iconHaloWidth.eval(ctx) : 0,
            iconSize: iconSize,
          );
        }
      }
    }

    if (text == null && icon == null) return null;

    // Variable anchors: try each candidate until one fits.
    final variableAnchors = text != null && !instance.alongLine
        ? layer.textVariableAnchor?.eval(ctx)
        : null;
    if (text != null && variableAnchors != null && variableAnchors.isNotEmpty) {
      return _prepareVariableAnchor(placed, layer, ctx, text, fontSize,
          textScale, icon, variableAnchors, collision, sitting);
    }

    // Along-line text follows the line glyph by glyph, unless the style
    // pins it to the viewport or the script needs shaping we can't
    // preserve per-glyph.
    var lineTextAngle = 0.0;
    if (text != null && instance.alongLine) {
      if (layer.textRotationAlignment.eval(ctx) != 'viewport') {
        if (instance.path != null &&
            placed.transform != null &&
            instance.curveSafe) {
          return _prepareCurved(placed, layer, ctx, text, fontSize, textScale,
              icon, collision, sitting);
        }
        lineTextAngle = _uprightAngle(sitting, placed.screenAngle);
      }
    }

    // Compute collision boxes.
    final boxes = <Rect>[];
    var textRect = Rect.zero;
    var angle = 0.0;
    if (text != null) {
      final padding = layer.textPadding.eval(ctx);
      final offset = layer.textOffset.eval(ctx);
      // Shaped at the reference size: screen dimensions carry the scale.
      final width = text.size.width * textScale;
      final height = text.size.height * textScale;
      final em = fontSize;
      final shifted = anchor +
          Offset(
            offset.isNotEmpty ? offset[0] * em : 0,
            offset.length > 1 ? offset[1] * em : 0,
          );
      textRect =
          _anchoredRect(layer.textAnchor.eval(ctx), shifted, width, height);
      if (instance.alongLine) {
        angle = lineTextAngle;
        // Along-line text is centered on the anchor.
        textRect =
            Rect.fromCenter(center: anchor, width: width, height: height);
        boxes.add(_rotatedBounds(textRect, anchor, angle).inflate(padding));
      } else {
        boxes.add(textRect.inflate(padding));
      }
    }
    if (icon != null) {
      boxes.add(icon.rect.inflate(2));
    }

    final allowOverlap = text != null
        ? layer.textAllowOverlap.eval(ctx)
        : layer.iconAllowOverlap.eval(ctx);
    if (!allowOverlap && !collision.tryPlaceAll(boxes)) {
      // Icon may still be placed when text is optional.
      if (icon != null &&
          text != null &&
          layer.textOptional.eval(ctx) &&
          collision.tryPlaceAll([icon.rect.inflate(2)])) {
        sitting.textDropped = true;
        return _DrawableSymbol(placed, icon: icon);
      }
      return null;
    }

    return _DrawableSymbol(
      placed,
      icon: icon,
      text: text,
      textRect: textRect,
      textAngle: angle,
      textScale: textScale,
    );
  }

  /// `text-variable-anchor` placement: anchors are tried in style order
  /// — except for the one this label was last placed at, which is tried
  /// ahead of them all — and the first whose boxes fit the collision
  /// index wins. `text-offset` is ignored in this mode;
  /// `text-radial-offset` applies per anchor.
  ///
  /// Preferring the sitting anchor is what keeps a label from hopping
  /// around its own point: without it, a neighbour that brushes past
  /// for a moment pushes the label to its second choice, and the label
  /// snaps back the moment the neighbour moves on. MapLibre carries the
  /// previous anchor into its next placement for the same reason.
  _DrawableSymbol? _prepareVariableAnchor(
    PlacedSymbol placed,
    SymbolThemeLayer layer,
    EvalContext ctx,
    _LaidOutText text,
    double fontSize,
    double textScale,
    _DrawableIcon? icon,
    List<String> anchors,
    _CollisionIndex collision,
    SittingPlacement sitting,
  ) {
    final padding = layer.textPadding.eval(ctx);
    final radial = layer.textRadialOffset.eval(ctx) * fontSize;
    final allowOverlap = layer.textAllowOverlap.eval(ctx);
    final width = text.size.width * textScale;
    final height = text.size.height * textScale;
    // Index -1 is the remembered anchor, which the style-order loop
    // then skips. A remembered anchor the style no longer offers (a
    // data-driven anchor list) is ignored.
    final remembered = sitting.anchor;
    final seat =
        remembered != null && anchors.contains(remembered) ? remembered : null;
    for (var i = seat == null ? 0 : -1; i < anchors.length; i++) {
      final anchorName = i < 0 ? seat! : anchors[i];
      if (i >= 0 && anchorName == seat) continue;
      final shifted = placed.screenAnchor + _radialShift(anchorName, radial);
      final textRect = _anchoredRect(anchorName, shifted, width, height);
      final boxes = [
        textRect.inflate(padding),
        if (icon != null) icon.rect.inflate(2),
      ];
      if (allowOverlap || collision.tryPlaceAll(boxes)) {
        sitting.anchor = anchorName;
        return _DrawableSymbol(placed,
            icon: icon, text: text, textRect: textRect, textScale: textScale);
      }
    }
    if (icon != null &&
        layer.textOptional.eval(ctx) &&
        collision.tryPlaceAll([icon.rect.inflate(2)])) {
      sitting.textDropped = true;
      return _DrawableSymbol(placed, icon: icon);
    }
    return null;
  }

  /// Shift that moves the text box away from the anchor point by
  /// [r] pixels, in the direction implied by the anchor name.
  static Offset _radialShift(String anchorName, double r) {
    if (r == 0) return Offset.zero;
    const d = 0.7071067811865476; // 1/sqrt(2)
    return switch (anchorName) {
      'top' => Offset(0, r),
      'bottom' => Offset(0, -r),
      'left' => Offset(r, 0),
      'right' => Offset(-r, 0),
      'top-left' => Offset(r * d, r * d),
      'top-right' => Offset(-r * d, r * d),
      'bottom-left' => Offset(r * d, -r * d),
      'bottom-right' => Offset(-r * d, -r * d),
      _ => Offset.zero, // center
    };
  }

  /// Curved line text: each glyph cluster is placed and rotated
  /// individually along the projected line. Labels that don't fit their
  /// line or bend sharper than `text-max-angle` are not placed, matching
  /// MapLibre.
  _DrawableSymbol? _prepareCurved(
    PlacedSymbol placed,
    SymbolThemeLayer layer,
    EvalContext ctx,
    _LaidOutText text,
    double fontSize,
    double textScale,
    _DrawableIcon? icon,
    _CollisionIndex collision,
    SittingPlacement sitting,
  ) {
    final instance = placed.instance;
    final path = instance.path!;
    final transform = placed.transform!;
    final clusters = text.clusters;
    if (clusters.isEmpty) return null;

    _DrawableSymbol? iconFallback() {
      if (icon != null &&
          layer.textOptional.eval(ctx) &&
          collision.tryPlaceAll([icon.rect.inflate(2)])) {
        sitting.textDropped = true;
        return _DrawableSymbol(placed, icon: icon);
      }
      return null;
    }

    // The label occupies [d0, d1] along the path, in logical units.
    // Cluster metrics are at the reference size; [textScale] converts
    // them to screen pixels before [scale] converts those to logical.
    final scale = transform.scale;
    final halfW = text.size.width * textScale / 2 / scale;
    final d0 = instance.pathDistance - halfW;
    final d1 = instance.pathDistance + halfW;
    if (d0 < 0 || d1 > path.length) return iconFallback();

    // Reading direction: walk the path backwards when the label would
    // come out upside-down on screen. Measured over the label's own
    // span rather than the whole line, and held across the vertical it
    // would otherwise flip at (see [_readsBackwards]).
    final s0 = transform.apply(path.pointAt(d0));
    final s1 = transform.apply(path.pointAt(d1));
    final chord = s1 - s0;
    final chordLength = chord.distance;
    final backwards = chordLength > 0
        ? _readsBackwards(sitting, chord.dx / chordLength)
        : sitting.flip ?? false;
    final reversed = layer.textKeepUpright.eval(ctx) && backwards;

    final offset = layer.textOffset.eval(ctx);
    final perp = offset.length > 1 ? offset[1] * fontSize : 0.0;
    final maxAngle = layer.textMaxAngle.eval(ctx) * math.pi / 180;

    final placements =
        <({String grapheme, Offset pos, double angle, double width})>[];
    var previousAngle = double.nan;
    var maxDeviation = 0.0;
    double? firstAngle;
    for (final cluster in clusters) {
      final centre = cluster.center * textScale;
      final d = reversed ? d1 - centre / scale : d0 + centre / scale;
      var angle = path.angleAt(d) + transform.rotation;
      if (reversed) angle += math.pi;
      angle = _foldAngle(angle);
      if (!previousAngle.isNaN &&
          _foldAngle(angle - previousAngle).abs() > maxAngle) {
        return iconFallback(); // line bends too sharply for this label
      }
      previousAngle = angle;
      firstAngle ??= angle;
      maxDeviation =
          math.max(maxDeviation, _foldAngle(angle - firstAngle).abs());
      var pos = transform.apply(path.pointAt(d));
      if (perp != 0) {
        pos += Offset(-math.sin(angle), math.cos(angle)) * perp;
      }
      placements.add((
        grapheme: cluster.grapheme,
        pos: pos,
        angle: angle,
        width: cluster.width * textScale,
      ));
    }
    if (placements.isEmpty) return null;

    final padding = layer.textPadding.eval(ctx);
    final allowOverlap = layer.textAllowOverlap.eval(ctx);

    // The window under the label is essentially straight: draw it as a
    // single rotated string, which is much cheaper.
    if (maxDeviation < 0.02 && perp == 0) {
      final angle = _orientAngle(placed.screenAngle, backwards);
      final textRect = Rect.fromCenter(
          center: placed.screenAnchor,
          width: text.size.width * textScale,
          height: text.size.height * textScale);
      final boxes = [
        _rotatedBounds(textRect, placed.screenAnchor, angle).inflate(padding),
        if (icon != null) icon.rect.inflate(2),
      ];
      if (!allowOverlap && !collision.tryPlaceAll(boxes)) {
        return iconFallback();
      }
      return _DrawableSymbol(placed,
          icon: icon,
          text: text,
          textRect: textRect,
          textAngle: angle,
          textScale: textScale);
    }

    // Per-glyph collision boxes.
    final glyphHeight = fontSize * 1.2;
    final boxes = <Rect>[
      for (final p in placements)
        _rotatedBounds(
                Rect.fromCenter(
                    center: p.pos, width: p.width, height: glyphHeight),
                p.pos,
                p.angle)
            .inflate(padding),
      if (icon != null) icon.rect.inflate(2),
    ];
    if (!allowOverlap && !collision.tryPlaceAll(boxes)) {
      return iconFallback();
    }

    final glyphs = [
      for (final p in placements)
        _CurvedGlyph(
          painters: _glyphPainters(p.grapheme, text),
          position: p.pos,
          angle: p.angle,
        ),
    ];
    return _DrawableSymbol(placed,
        icon: icon, curvedGlyphs: glyphs, textScale: textScale);
  }

  /// Folds an angle into (-π, π].
  static double _foldAngle(double angle) {
    var a = angle;
    while (a <= -math.pi) {
      a += 2 * math.pi;
    }
    while (a > math.pi) {
      a -= 2 * math.pi;
    }
    return a;
  }

  /// Returns the shaped text for [instance], shaped at [_shapeSize]
  /// regardless of [fontSize] — the caller scales at draw time. The
  /// cache key therefore contains no font size, and `text-opacity` /
  /// `text-halo-width` enter it quantized: a `text-size` ramp reuses
  /// one shaped paragraph across the whole pinch, and opacity/halo
  /// ramps rotate the key a bounded number of times instead of per
  /// eval-zoom step.
  _LaidOutText _layoutText(
    SymbolInstance instance,
    SymbolThemeLayer layer,
    EvalContext ctx,
    double fontSize,
  ) {
    // Fast path: at an unchanged eval zoom the memoized key is valid
    // as-is. Only the key: the laid-out text itself belongs to the LRU,
    // which may evict and dispose it.
    final memo = instance.textStyleMemo;
    if (memo != null && memo.zoom == ctx.zoom) {
      final memoized = _textCache.get(memo.cacheKey);
      if (memoized != null) return memoized;
      return _shape(instance, memo);
    }

    // `text-opacity` is folded into the colours quantized to 1/32
    // steps (~3%, invisible on labels), so an opacity ramp rebuilds a
    // label's paragraphs at most 32 times ever instead of per step.
    final opacity =
        (layer.textOpacity.eval(ctx).clamp(0.0, 1.0) * 32).round() / 32;
    final color = _withOpacity(layer.textColor.eval(ctx), opacity);
    final haloColor = _withOpacity(layer.textHaloColor.eval(ctx), opacity);
    final haloWidth = layer.textHaloWidth.eval(ctx).clamp(0.0, 8.0);
    // The halo stroke is baked into the paragraph, so it must scale
    // with the drawn text: store it as a font-size ratio, quantized to
    // 1/128 em (≤0.06px error at 16px — imperceptible).
    final haloRatioQ =
        haloColor.a <= 0 ? 0 : (haloWidth / fontSize * 128).round();
    final fillArgb = color.toARGB32();
    final haloArgb = haloRatioQ == 0 ? 0 : haloColor.toARGB32();
    final fonts = layer.textFont.eval(ctx);
    final letterSpacingEm = layer.textLetterSpacing.eval(ctx);
    final maxWidthEm = layer.textMaxWidth.eval(ctx);

    // A zoom step rarely moves any quantized primitive: revalidate the
    // memo by value and reuse its key strings without rebuilding them.
    if (memo != null &&
        memo.matches(fillArgb, haloArgb, haloRatioQ, fonts, letterSpacingEm,
            maxWidthEm)) {
      memo.zoom = ctx.zoom;
      final memoized = _textCache.get(memo.cacheKey);
      if (memoized != null) return memoized;
      return _shape(instance, memo);
    }

    final styleKey =
        '$fillArgb|$haloArgb|$haloRatioQ|${fonts.join(',')}|$letterSpacingEm';
    // Along-line labels never wrap.
    final cacheKey =
        '${instance.text}|$styleKey|$maxWidthEm|${instance.alongLine}';
    final built = TextStyleMemo(
      fillArgb: fillArgb,
      haloArgb: haloArgb,
      haloRatioQ: haloRatioQ,
      fonts: fonts,
      letterSpacingEm: letterSpacingEm,
      maxWidthEm: maxWidthEm,
      styleKey: styleKey,
      cacheKey: cacheKey,
      zoom: ctx.zoom,
    );
    instance.textStyleMemo = built;
    final cached = _textCache.get(cacheKey);
    if (cached != null) return cached;
    return _shape(instance, built);
  }

  /// Shapes [instance]'s text at the reference size per [memo] and puts
  /// it in the text cache.
  _LaidOutText _shape(SymbolInstance instance, TextStyleMemo memo) {
    debugShapedTextCount++;
    final shapeStopwatch = Stopwatch()..start();
    try {
      return _shapeTimed(instance, memo);
    } finally {
      debugShapeMicros += shapeStopwatch.elapsedMicroseconds;
    }
  }

  _LaidOutText _shapeTimed(SymbolInstance instance, TextStyleMemo memo) {
    final singleLine = instance.alongLine;
    final maxLines = singleLine ? 1 : 4;
    final maxWidth = singleLine
        ? double.infinity
        : math.max(_shapeSize * memo.maxWidthEm, _shapeSize * 2);
    final style = _textStyle(
        memo.fonts, _shapeSize, memo.letterSpacingEm, Color(memo.fillArgb));
    final fill = TextPainter(
      text: TextSpan(text: instance.text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);

    TextPainter? halo;
    TextStyle? haloStyle;
    if (memo.haloRatioQ > 0) {
      haloStyle = style.copyWith(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          // 2 · (haloRatioQ/128) · _shapeSize
          ..strokeWidth = memo.haloRatioQ / 4
          ..strokeJoin = StrokeJoin.round
          ..color = Color(memo.haloArgb),
      );
      halo = TextPainter(
        text: TextSpan(text: instance.text, style: haloStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: maxLines,
      )..layout(maxWidth: maxWidth);
    }

    final laidOut = _LaidOutText(
      text: instance.text,
      fill: fill,
      halo: halo,
      size: fill.size,
      styleKey: memo.styleKey,
      fillStyle: style,
      haloStyle: haloStyle,
    );
    _textCache.put(memo.cacheKey, laidOut);
    return laidOut;
  }

  /// Painters for a single glyph cluster, cached across labels — the
  /// same characters repeat constantly in map text.
  _GlyphText _glyphPainters(String grapheme, _LaidOutText text) {
    final key = '${text.styleKey}#$grapheme';
    final cached = _glyphCache.get(key);
    if (cached != null) return cached;

    final fill = TextPainter(
      text: TextSpan(text: grapheme, style: text.fillStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    TextPainter? halo;
    if (text.haloStyle != null) {
      halo = TextPainter(
        text: TextSpan(text: grapheme, style: text.haloStyle),
        textDirection: TextDirection.ltr,
      )..layout();
    }
    final glyph = _GlyphText(fill: fill, halo: halo);
    _glyphCache.put(key, glyph);
    return glyph;
  }

  static TextStyle _textStyle(
    List<String> fonts,
    double fontSize,
    double letterSpacingEm,
    ui.Color color,
  ) {
    final joined = fonts.join(' ').toLowerCase();
    var weight = FontWeight.w400;
    if (joined.contains('extrabold') || joined.contains('extra bold')) {
      weight = FontWeight.w800;
    } else if (joined.contains('semibold') || joined.contains('semi bold')) {
      weight = FontWeight.w600;
    } else if (joined.contains('bold')) {
      weight = FontWeight.w700;
    } else if (joined.contains('medium')) {
      weight = FontWeight.w500;
    } else if (joined.contains('light')) {
      weight = FontWeight.w300;
    } else if (joined.contains('thin')) {
      weight = FontWeight.w200;
    }
    return TextStyle(
      fontSize: fontSize,
      fontWeight: weight,
      fontStyle:
          joined.contains('italic') ? FontStyle.italic : FontStyle.normal,
      letterSpacing: letterSpacingEm == 0 ? null : letterSpacingEm * fontSize,
      color: color,
      height: 1.15,
    );
  }

  /// Positions a box of [width]x[height] relative to [anchor] per the
  /// MapLibre anchor semantics ("top" = box hangs below the anchor).
  static Rect _anchoredRect(
      String anchorName, Offset anchor, double width, double height) {
    final dx = switch (anchorName) {
      'left' || 'top-left' || 'bottom-left' => 0.0,
      'right' || 'top-right' || 'bottom-right' => -width,
      _ => -width / 2,
    };
    final dy = switch (anchorName) {
      'top' || 'top-left' || 'top-right' => 0.0,
      'bottom' || 'bottom-left' || 'bottom-right' => -height,
      _ => -height / 2,
    };
    return Rect.fromLTWH(anchor.dx + dx, anchor.dy + dy, width, height);
  }

  /// Whether an along-line label reads right-to-left on screen, and so
  /// has to be turned around to stay upright. [cosine] is the cosine of
  /// its on-screen direction: positive reads left-to-right.
  ///
  /// The answer is sticky within [_flipHysteresis] of vertical, and is
  /// remembered on the instance. The bare test — is the end left of the
  /// start — puts its threshold exactly where a road runs vertical on
  /// screen, and there the sign is camera noise: a road within a degree
  /// of vertical turns its label around on alternate frames. That is
  /// visible as more than a mirrored string, because a perpendicular
  /// `text-offset` is measured in the label's own frame and flips with
  /// it — the name jumps to the other side of the street and back. A
  /// dead band turns the label around once, a few degrees past
  /// vertical, and not again until the line clearly points the other
  /// way.
  static bool _readsBackwards(SittingPlacement sitting, double cosine) {
    final previous = sitting.flip;
    final backwards = previous == null
        ? cosine < 0
        : (previous ? cosine < _flipHysteresis : cosine < -_flipHysteresis);
    sitting.flip = backwards;
    return backwards;
  }

  /// Drawing angle for along-line text: [screenAngle] folded into
  /// (-π, π], turned around when the label would otherwise read
  /// backwards.
  static double _orientAngle(double screenAngle, bool backwards) {
    final a = _foldAngle(screenAngle);
    return backwards ? _foldAngle(a + math.pi) : a;
  }

  /// Keeps along-line text upright, deciding the turn-around through
  /// [_readsBackwards] rather than by folding the angle into
  /// (-π/2, π/2] — the fold's boundary is the vertical the label
  /// oscillates around.
  static double _uprightAngle(SittingPlacement sitting, double screenAngle) =>
      _orientAngle(
          screenAngle, _readsBackwards(sitting, math.cos(screenAngle)));

  static Color _withOpacity(Color color, double opacity) =>
      opacity >= 1 ? color : color.withValues(alpha: color.a * opacity);

  static Rect _rotatedBounds(Rect rect, Offset pivot, double angle) {
    final cosA = math.cos(angle).abs();
    final sinA = math.sin(angle).abs();
    final w = rect.width * cosA + rect.height * sinA;
    final h = rect.width * sinA + rect.height * cosA;
    return Rect.fromCenter(center: rect.center, width: w, height: h);
  }

  void dispose() {
    _textCache.clear();
    _glyphCache.clear();
    _disposeRetired();
  }
}

/// Text shaped at [LabelPainter._shapeSize]; every metric ([size],
/// cluster positions/widths) is in reference-size units and is scaled
/// by the evaluated `text-size / _shapeSize` at use sites.
class _LaidOutText {
  final String text;
  final TextPainter fill;
  final TextPainter? halo;
  final Size size;
  final String styleKey;
  final TextStyle fillStyle;
  final TextStyle? haloStyle;

  List<_Cluster>? _clusters;

  _LaidOutText({
    required this.text,
    required this.fill,
    required this.halo,
    required this.size,
    required this.styleKey,
    required this.fillStyle,
    required this.haloStyle,
  });

  /// Grapheme clusters with their advance-centre x positions in the
  /// laid-out string — spacing and kerning come from the full layout,
  /// so curved glyphs keep the string's metrics. Whitespace clusters
  /// are omitted (their advance still separates the neighbours).
  List<_Cluster> get clusters => _clusters ??= _computeClusters();

  void dispose() {
    fill.dispose();
    halo?.dispose();
  }

  List<_Cluster> _computeClusters() {
    final result = <_Cluster>[];
    var start = 0;
    for (final grapheme in text.characters) {
      final end = start + grapheme.length;
      if (grapheme.trim().isNotEmpty) {
        final boxes = fill.getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: end));
        if (boxes.isNotEmpty) {
          var left = double.infinity;
          var right = -double.infinity;
          for (final box in boxes) {
            left = math.min(left, box.left);
            right = math.max(right, box.right);
          }
          result.add(_Cluster(grapheme, (left + right) / 2, right - left));
        }
      }
      start = end;
    }
    return result;
  }
}

class _Cluster {
  final String grapheme;

  /// Centre of the cluster's advance, from the string's left edge.
  final double center;
  final double width;

  const _Cluster(this.grapheme, this.center, this.width);
}

class _GlyphText {
  final TextPainter fill;
  final TextPainter? halo;

  const _GlyphText({required this.fill, required this.halo});

  void dispose() {
    fill.dispose();
    halo?.dispose();
  }
}

class _CurvedGlyph {
  final _GlyphText painters;
  final Offset position;
  final double angle;

  const _CurvedGlyph({
    required this.painters,
    required this.position,
    required this.angle,
  });
}

class _DrawableIcon {
  /// MapLibre's `symbol_sdf` encoding: the alpha channel ramps across 8
  /// atlas texels and the shape's edge sits at 6/8 of the range. A halo
  /// of width `w` (in `icon-size` units) simply moves the cutoff `w`
  /// texels further out.
  static const double _sdfTexels = 8;
  static const double _sdfEdge = 6 / _sdfTexels;

  final SpriteAtlas atlas;
  final Sprite sprite;
  final Rect rect;
  final double opacity;

  /// `icon-color`, for SDF sprites only; null draws the sprite as-is.
  final Color? tint;
  final Color? haloColor;
  final double haloWidth;

  /// `icon-size`, which `icon-halo-width` is measured relative to.
  final double iconSize;

  const _DrawableIcon({
    required this.atlas,
    required this.sprite,
    required this.rect,
    required this.opacity,
    this.tint,
    this.haloColor,
    this.haloWidth = 0,
    this.iconSize = 1,
  });

  void draw(Canvas canvas, double devicePixelRatio) {
    final color = tint;
    if (color == null) {
      canvas.drawImageRect(
        atlas.image,
        sprite.sourceRect,
        rect,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..color = Color.fromRGBO(255, 255, 255, opacity),
      );
      return;
    }
    final halo = haloColor;
    if (halo != null && halo.a > 0 && haloWidth > 0) {
      canvas.drawImageRect(
        atlas.image,
        sprite.sourceRect,
        rect,
        _sdfPaint(
          halo,
          ((6 - haloWidth / iconSize) / _sdfTexels).clamp(0.0, _sdfEdge),
          devicePixelRatio,
        ),
      );
    }
    canvas.drawImageRect(atlas.image, sprite.sourceRect, rect,
        _sdfPaint(color, _sdfEdge, devicePixelRatio));
  }

  /// Thresholds the distance field at [edge] and tints what survives
  /// with [color]. A colour matrix is applied *after* texture sampling,
  /// so the threshold lands on interpolated distances and the edge stays
  /// crisp at any scale — the same reason MapLibre does this in a
  /// fragment shader. The ramp is steepened to span roughly one device
  /// pixel at the size this icon is drawn, which is what antialiases it.
  Paint _sdfPaint(Color color, double edge, double devicePixelRatio) {
    final drawnPerTexel = rect.width * devicePixelRatio / sprite.width;
    final slope = (_sdfTexels * drawnPerTexel).clamp(4.0, 128.0);
    final shift = 0.5 - edge * slope;
    return Paint()
      // Bilinear only: mipmaps blur the field, which erodes the shape.
      ..filterQuality = FilterQuality.low
      ..color =
          Color.fromRGBO(255, 255, 255, (opacity * color.a).clamp(0.0, 1.0))
      ..colorFilter = ColorFilter.matrix(<double>[
        0, 0, 0, 0, color.r * 255, //
        0, 0, 0, 0, color.g * 255, //
        0, 0, 0, 0, color.b * 255, //
        0, 0, 0, slope, shift * 255, //
      ]);
  }
}

class _DrawableSymbol {
  final PlacedSymbol symbol;
  final _DrawableIcon? icon;
  final _LaidOutText? text;
  final Rect textRect;
  final double textAngle;

  /// evaluated `text-size` / [LabelPainter._shapeSize]: paragraphs are
  /// shaped at the reference size and drawn through this scale, which
  /// keeps them vector-crisp (glyphs rasterize at device scale under
  /// the canvas transform).
  final double textScale;
  final List<_CurvedGlyph>? curvedGlyphs;

  /// Opacity this symbol actually draws at: its continuity key's fade
  /// times its layer's zoom-range ramp, quantized. Assigned by [_paint]
  /// once the symbol has survived collision — every construction site
  /// would otherwise have to thread a value none of them computes.
  double opacity = 1;

  /// Whether this drawable is a fade-out ghost drawn by the sweep — it
  /// claimed no collision space, and [LabelPainter.debugDrawnProbe]
  /// reports it as a continuation of a departing label, not a new one.
  bool isGhost = false;

  _DrawableSymbol(
    this.symbol, {
    this.icon,
    this.text,
    this.textRect = Rect.zero,
    this.textAngle = 0,
    this.textScale = 1,
    this.curvedGlyphs,
  });

  /// Screen extent of everything [draw] paints, for bounding the fade
  /// layer a cohort draws through. Rotated pieces contribute the circle
  /// they sweep, so the answer is conservative and never too small.
  Rect get bounds {
    Rect? result;
    void add(Rect rect) =>
        result = result == null ? rect : result!.expandToInclude(rect);

    Rect sweptCircle(Offset center, double width, double height) {
      final diagonal = math.sqrt(width * width + height * height);
      return Rect.fromCircle(center: center, radius: diagonal / 2 * textScale);
    }

    final icon = this.icon;
    if (icon != null) add(icon.rect);
    final glyphs = curvedGlyphs;
    final text = this.text;
    if (glyphs != null) {
      for (final glyph in glyphs) {
        final painter = glyph.painters.halo ?? glyph.painters.fill;
        add(sweptCircle(glyph.position, painter.width, painter.height));
      }
    } else if (text != null) {
      add(textAngle == 0
          ? textRect
          : sweptCircle(
              symbol.screenAnchor, text.size.width, text.size.height));
    }
    return result ?? Rect.zero;
  }

  void draw(Canvas canvas, double devicePixelRatio) {
    icon?.draw(canvas, devicePixelRatio);
    final glyphs = curvedGlyphs;
    if (glyphs != null) {
      // All halos first: a glyph's halo must never cut into its
      // neighbour's fill.
      for (var pass = 0; pass < 2; pass++) {
        for (final glyph in glyphs) {
          final painter = pass == 0 ? glyph.painters.halo : glyph.painters.fill;
          if (painter == null) continue;
          canvas.save();
          canvas.translate(glyph.position.dx, glyph.position.dy);
          canvas.rotate(glyph.angle);
          if (textScale != 1) canvas.scale(textScale);
          painter.paint(
              canvas, Offset(-painter.width / 2, -painter.height / 2));
          canvas.restore();
        }
      }
      return;
    }
    final t = text;
    if (t == null) return;
    if (textAngle != 0) {
      canvas.save();
      canvas.translate(symbol.screenAnchor.dx, symbol.screenAnchor.dy);
      canvas.rotate(textAngle);
      if (textScale != 1) canvas.scale(textScale);
      final topLeft = Offset(-t.size.width / 2, -t.size.height / 2);
      t.halo?.paint(canvas, topLeft);
      t.fill.paint(canvas, topLeft);
      canvas.restore();
    } else if (textScale != 1) {
      canvas.save();
      canvas.translate(textRect.left, textRect.top);
      canvas.scale(textScale);
      t.halo?.paint(canvas, Offset.zero);
      t.fill.paint(canvas, Offset.zero);
      canvas.restore();
    } else {
      t.halo?.paint(canvas, textRect.topLeft);
      t.fill.paint(canvas, textRect.topLeft);
    }
  }
}

/// Grid-bucketed screen-space collision index.
class _CollisionIndex {
  static const double _cellSize = 128;
  final Map<int, List<Rect>> _cells = {};
  final int _columns;
  final bool _permissive;

  _CollisionIndex(Size screenSize)
      : _columns = math.max(1, (screenSize.width / _cellSize).ceil() + 4),
        _permissive = false;

  /// An index that accepts everything and reserves nothing — for
  /// fade-out ghosts, which draw wherever they were without claiming
  /// space or blocking each other, and for the frames that replay a
  /// frozen placement, where the decision has already been taken.
  _CollisionIndex.permissive()
      : _columns = 1,
        _permissive = true;

  /// Whether this index decides nothing. Symbol preparation reads it to
  /// replay the parts of a placement that space, not geometry, decided
  /// — which anchor a label took, whether its text was dropped.
  bool get permissive => _permissive;

  /// Whether [rects] fit, reserving them when they do.
  bool tryPlaceAll(List<Rect> rects) {
    if (_permissive) return true;
    for (final rect in rects) {
      if (_collides(rect)) return false;
    }
    for (final rect in rects) {
      _insert(rect);
    }
    return true;
  }

  // The cell walks are inlined in both callers: a sync* generator here
  // allocated an iterator per collision box per frame in the hottest
  // label loop.

  bool _collides(Rect rect) {
    final minX = ((rect.left + 512) / _cellSize).floor();
    final maxX = ((rect.right + 512) / _cellSize).floor();
    final minY = ((rect.top + 512) / _cellSize).floor();
    final maxY = ((rect.bottom + 512) / _cellSize).floor();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final rects = _cells[y * _columns + x];
        if (rects == null) continue;
        for (final other in rects) {
          if (rect.overlaps(other)) return true;
        }
      }
    }
    return false;
  }

  void _insert(Rect rect) {
    final minX = ((rect.left + 512) / _cellSize).floor();
    final maxX = ((rect.right + 512) / _cellSize).floor();
    final minY = ((rect.top + 512) / _cellSize).floor();
    final maxY = ((rect.bottom + 512) / _cellSize).floor();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        (_cells[y * _columns + x] ??= []).add(rect);
      }
    }
  }
}
