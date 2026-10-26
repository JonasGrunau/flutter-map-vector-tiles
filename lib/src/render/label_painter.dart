import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:characters/characters.dart';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

import '../cache/lru_cache.dart';
import '../core/tile_zoom.dart';
import '../style/expression.dart';
import '../style/sprite_atlas.dart';
import '../style/theme.dart';
import 'fade.dart';
import 'glyph_atlas.dart';
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

  /// Screen bounds of the display tile this transform places — the
  /// axis-aligned box around its four corners, as MapLibre bounds a
  /// rotated tile for `symbol-avoid-edges`.
  late final Rect tileBounds = () {
    const size = displayTileSize;
    final corners = [
      apply(Offset.zero),
      apply(const Offset(size, 0)),
      apply(const Offset(0, size)),
      apply(const Offset(size, size)),
    ];
    var bounds = Rect.fromPoints(corners[0], corners[1]);
    for (final corner in corners.skip(2)) {
      bounds = bounds.expandToInclude(Rect.fromPoints(corner, corner));
    }
    return bounds;
  }();
}

/// A symbol candidate projected to screen coordinates.
class PlacedSymbol {
  final SymbolInstance instance;
  final Offset screenAnchor;

  /// Screen-space map angle for point symbols, or map plus local line
  /// bearing for along-line symbols (radians).
  final double screenAngle;

  /// Tile→screen transform of the display tile the symbol was laid out
  /// in: along-line symbols project their line through it (curved text,
  /// the fit on the line), and `symbol-avoid-edges` reads the tile's
  /// screen bounds off it. Null only for hand-built point candidates.
  final TileTransform? transform;

  /// A ghost-only candidate never competes for placement: it exists
  /// solely as the drawable behind a label that is fading out, in case
  /// no live instance of its continuity key is placed this frame. The
  /// caller marks candidates from tiles that have stopped contributing
  /// labels (a retained level the new one already covers, or a disposed
  /// tile's parked cohort) this way.
  final bool ghostOnly;

  /// Whether this candidate comes from a previous-level tile kept
  /// across a zoom crossing. It still competes for space, but takes no
  /// part in repeat suppression (see [LabelPainter._repeatSuppressed]):
  /// its anchors are spaced for the level it was laid out at, so they
  /// would suppress the arriving level's copies at the wrong interval
  /// and hand them back — as pop-ins — the moment the level is released.
  final bool retained;

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
    this.retained = false,
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
///
/// `LabelMode.tile` runs the same placement and drawing once per tile
/// instead, into the tile's raster — see [paintTile].
class LabelPainter {
  /// Cache capacities. One dense-city screen of distinct labels is the
  /// floor (below it every frame evicts entries the same frame still
  /// needs), but the text cache must hold a zoom *round trip*: the
  /// finished-tile cache serves a revisited level back without its
  /// shaped text, so whatever was evicted meanwhile is re-shaped by the
  /// pump for seconds after the camera stopped. A phone-portrait fling
  /// z15→z17→z15 over central London with `TileOffset.none` shapes
  /// ~7,400 distinct texts. The cost is memory once that many distinct
  /// labels were drawn: on the same phone, a run through four dense
  /// cities held 37–49 MB more RSS at its end than at 2500 entries, and
  /// 117–119 MB more with `TileOffset.none`, whose peak rose from 384 to
  /// 491–495 MB. [trimCaches] gives part of it back under memory
  /// pressure. If a byte budget is ever needed, `LruCache.maxCost` is
  /// the ready hook.
  static const int textCacheEntries = 8000;
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

  /// The Gaussian sigma, per px of `text-halo-blur`, that blurs a halo
  /// the way MapLibre's shader does: it fades the halo's edge over
  /// ±1.19 × blur px with a smoothstep, whose 10–90 % rise this sigma
  /// matches.
  static const double _haloBlurSigma = 0.565;

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

  /// How far past vertical a glyph of a kept-upright curved label may
  /// turn on screen. Leaves room for a winding road near vertical, but
  /// not for a glyph that reads upside down. See [_prepareCurved].
  static const double _uprightSlack = math.pi / 6;

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

  /// Debug hook: called with a candidate's continuity key and why it was
  /// not drawn on a frame (`fit`, `angle`, `collision`, `repeat`), and
  /// whether that frame was a replay. For the bench; null otherwise.
  static void Function(Object key, String reason, bool replay)?
      debugRejectProbe;

  static void Function(double styleZoom, List<DrawnLabelRecord> drawn)?
      debugDrawnProbe;

  /// The fade sweep (ghost lookup + prepare per fading key) and the
  /// final drawing of the placed symbols — the two [paint] phases after
  /// the candidate loop, completing the [debugPaintMicros] breakdown.
  @visibleForTesting
  static int debugSweepMicros = 0;
  @visibleForTesting
  static int debugDrawMicros = 0;

  /// UI-thread microseconds spent inside [paintTile] — `LabelMode.tile`'s
  /// whole label cost, paid once per rasterized tile inside the render
  /// pump. Never part of [debugPaintMicros], which only the per-frame
  /// pass adds to.
  @visibleForTesting
  static int debugTilePaintMicros = 0;

  /// [paintTile] calls, for tests that assert which frame runs them.
  @visibleForTesting
  static int debugTilePaintCount = 0;

  @visibleForTesting
  int get debugTextCacheLength => _textCache.length;

  /// The scale text drawn at [scale] actually uses on a
  /// [devicePixelRatio] screen.
  @visibleForTesting
  static double debugSnapTextScale(double scale, double devicePixelRatio) =>
      _DrawableSymbol._snapTextScale(scale, devicePixelRatio);

  late final _textCache = LruCache<String, _LaidOutText>(
      maxEntries: textCacheEntries,
      onEvict: (_, text) => _retired.add(text.dispose));
  late final _glyphCache = LruCache<String, _GlyphText>(
      maxEntries: glyphCacheEntries,
      onEvict: (_, glyph) => _retired.add(glyph.dispose));

  /// Counts placement passes: [paint] frames that decide placement
  /// afresh, and [paintTile] calls. Every text and glyph a lookup
  /// returns is stamped with it, which is how [trimCaches] tells the
  /// labels on screen from the rest. Frames replaying a decision do not
  /// count: they lay out only its winners, and a trim after one would
  /// drop the on-screen labels that lost — which the next pass lays out
  /// again, shaping them inside a frame.
  var _pass = 0;

  @visibleForTesting
  int get debugGlyphCacheLength => _glyphCache.length;

  /// Releases the shaped text and glyphs not used since the last
  /// placement pass began, keeping what is on screen and what was
  /// shaped or [prewarm]ed since — for memory pressure, see
  /// `VectorTileLayer.clearMemoryCache`, which prewarms the labels of
  /// every tile it holds first, so that only text for places the map has
  /// left goes.
  ///
  /// The caches are sized to hold a zoom round trip (see
  /// [textCacheEntries]), which after a run through a few dense cities
  /// is tens of MB of paragraphs for places long left behind, over a
  /// hundred with `TileOffset.none`.
  /// Trimming that text costs nothing on screen: a label shaped again
  /// later goes through the pump, as it did before it was ever cached.
  ///
  /// The evicted painters are disposed now rather than at the next
  /// pass: memory pressure often arrives in the background, where no
  /// next pass comes. That is safe because this runs between frames, so
  /// no prepared symbol still holds them.
  void trimCaches() {
    _textCache.removeWhere((_, text) => text.pass != _pass);
    _glyphCache.removeWhere((_, glyph) => glyph.pass != _pass);
    _disposeRetired();
  }

  /// Curved-text glyphs rasterized once per style, grapheme and device
  /// size, so a curved label draws in one call per pass.
  final _glyphAtlas = GlyphAtlas();

  /// Whether [paint] may rasterize new glyphs into the atlas. The layer
  /// clears it while the app is away: atlas pages are `toImageSync`
  /// rasters and share the tile rasters' revoked-context hazard. Labels
  /// whose glyphs are missing then draw glyph by glyph.
  bool rasterizeGlyphs = true;

  /// Drops every atlas page, for the layer's resume recovery.
  void discardGlyphAtlas() => _glyphAtlas.clear();

  @visibleForTesting
  GlyphAtlas get debugGlyphAtlas => _glyphAtlas;

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
  /// left the screen. See [PlacementMemory]. [paintTile] swaps in a
  /// fresh one for the length of its pass.
  var _memory = PlacementMemory();

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
  /// [PlacementThrottle.shouldPlace] for why). [placementGeneration]
  /// must change whenever the camera or candidate set changes; an
  /// unchanged generation replays without creating another pending
  /// pass. [now] feeds both clocks and defaults to the wall clock.
  /// Disabling fades with [Duration.zero] clears any tracked fade state
  /// immediately, so an in-flight fade cannot keep its caller scheduling
  /// animation frames.
  List<PlacedSymbol> paint({
    required Canvas canvas,
    required Size screenSize,
    required double styleZoom,
    required List<PlacedSymbol> symbols,
    SpriteAtlas? sprites,
    double devicePixelRatio = 1,
    Duration labelFadeDuration = Duration.zero,
    required int placementGeneration,
    DateTime? now,
  }) {
    developer.Timeline.startSync('VT labels');
    final stopwatch = Stopwatch()..start();
    try {
      return _paint(
          canvas,
          screenSize,
          styleZoom,
          symbols,
          sprites,
          devicePixelRatio,
          labelFadeDuration,
          placementGeneration,
          now ?? DateTime.now());
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
    int placementGeneration,
    DateTime now,
  ) {
    _disposeRetired();
    final fades = labelFadeDuration > Duration.zero;
    if (fades) {
      _fades.beginFrame(now, labelFadeDuration);
    } else {
      // A fade may have been disabled at runtime while its tracker was
      // active. Leaving that state untouched keeps [hasActiveFades]
      // true forever: no-fade frames never advance it, and the widget's
      // fade ticker therefore never settles.
      _fades.clear();
    }
    // Whether this frame decides placement afresh or replays the last
    // decision. Layout happens either way — only the winners move on a
    // replay frame, not the choice of who they are.
    final placing = _placement.shouldPlace(
      now: now,
      interval: placementInterval(labelFadeDuration),
      generation: placementGeneration,
      screenSize: screenSize,
    );
    if (placing) _pass++;
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
    // Placement priority, see [_byPlacementPriority]. Its incumbent
    // term only matters on placing frames: the flags are freshly set
    // there and default-false on every rebuilt candidate list in
    // between.
    final sortStopwatch = Stopwatch()..start();
    final List<PlacedSymbol> candidates;
    if (placing) {
      _flagIncumbents(symbols, fades);
      candidates = symbols..sort(_byPlacementPriority);
    } else {
      // Replaying: the frozen decision says only the last pass's
      // winners are on screen, so only they are laid out — and only
      // they need sorting, ~100 of a few thousand candidates on a dense
      // screen. [_byPlacementPriority] is a total order (`order` is
      // unique), so
      // their relative order is exactly what a full sort gives.
      // Everyone else is at most a fade-out fallback, recorded in input
      // order instead of priority order. That order only settles exact
      // distance ties in [_nearestCandidate], between candidates of one
      // key and so of one layer — which at a shared anchor already fell
      // through to `order`, the input order, unless their sort keys
      // differ.
      candidates = <PlacedSymbol>[];
      for (final candidate in symbols) {
        if (!candidate.ghostOnly && _winners.contains(candidate.instance)) {
          candidates.add(candidate);
        } else if (fades) {
          _recordFallback(candidate);
        }
      }
      candidates.sort(_byPlacementPriority);
    }
    debugSortMicros += sortStopwatch.elapsedMicroseconds;
    if (placing) debugPlacingFrames++;
    if (placing && _winners.isNotEmpty) _promoteIncumbents(candidates);

    final toDraw = <_DrawableSymbol>[];
    var anyFading = false;
    if (placing) {
      _winners.clear();
      _repeatAnchors.clear();
    }
    final loopStopwatch = Stopwatch()..start();
    for (final candidate in candidates) {
      if (candidate.ghostOnly) {
        // Never competes for placement — only remembered, in case its
        // key is fading out and nothing else can draw it. (A replay
        // frame recorded these while picking its winners.)
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
      // The label's fade and its layer's zoom-range ramp compound: a
      // label appearing near its layer's maxzoom is subject to both.
      final ramp = zoomRangeOpacity(candidate.instance.layer, styleZoom);
      if (placing) {
        _winners.add(candidate.instance);
        final repeatKey = drawable.repeatKey;
        // Only text that actually shows may suppress a repeat: a
        // rejected or ramped-out candidate never hides a fallback.
        if (repeatKey != null && drawable.drawsText && ramp > 0) {
          (_repeatAnchors[repeatKey] ??= []).add(_RepeatAnchor(candidate));
        }
      }
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
        if (fallback == null) {
          debugRejectProbe?.call(key, 'ghost:none', true);
          return null;
        }
        final ramp = zoomRangeOpacity(fallback.instance.layer, styleZoom);
        if (ramp <= 0) {
          debugRejectProbe?.call(key, 'ghost:ramp', true);
          return null;
        }
        // Floored, mirroring the fade-in's implicit ceil: a departing
        // label reaches zero instead of lingering one step above it.
        final ghostOpacity =
            (opacity * ramp * _opacitySteps).floor() / _opacitySteps;
        if (ghostOpacity <= 0) return null;
        final drawable = _prepare(fallback, zoom, styleZoom,
            permissive ??= _CollisionIndex.permissive(), sprites, screenSize,
            gateZoom: false);
        if (drawable == null) {
          debugRejectProbe?.call(key, 'ghost:prepare', true);
          return null;
        }
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
    final drawn = _draw(canvas, toDraw, devicePixelRatio, anyFading);
    debugDrawMicros += drawStopwatch.elapsedMicroseconds;
    return drawn;
  }

  /// Placement priority: topmost style layers first (they win space),
  /// then incumbents — labels on screen right now, which a same-layer
  /// newcomer must not evict (see [PlacedSymbol.incumbent]) — then by
  /// symbol-sort-key, then by y, then by insertion order — the last
  /// term keeps the non-stable sort deterministic and lets current-level
  /// tiles beat retained ones on exact ties. A total order: `order` is
  /// unique per frame.
  static int _byPlacementPriority(PlacedSymbol a, PlacedSymbol b) {
    final byLayer = b.instance.layerIndex - a.instance.layerIndex;
    if (byLayer != 0) return byLayer;
    if (a.incumbent != b.incumbent) return a.incumbent ? -1 : 1;
    final bySortKey = a.instance.sortKey.compareTo(b.instance.sortKey);
    if (bySortKey != 0) return bySortKey;
    final byY = a.screenAnchor.dy.compareTo(b.screenAnchor.dy);
    if (byY != 0) return byY;
    return a.order - b.order;
  }

  /// Draws the placed symbols [toDraw] onto [canvas] and returns them in
  /// draw order. [anyFading] says whether any of them draws below full
  /// opacity, which costs the bucketed path below.
  List<PlacedSymbol> _draw(
    Canvas canvas,
    List<_DrawableSymbol> toDraw,
    double devicePixelRatio,
    bool anyFading,
  ) {
    // Draw bottom style layers first so upper layers paint on top; the
    // insertion-order tiebreaker keeps draw order stable across frames.
    toDraw.sort((a, b) {
      final byLayer =
          a.symbol.instance.layerIndex.compareTo(b.symbol.instance.layerIndex);
      if (byLayer != 0) return byLayer;
      // `symbol-z-order` within the layer; see [_zOrderKey].
      final byZOrder = a.drawKey.compareTo(b.drawKey);
      if (byZOrder != 0) return byZOrder;
      return a.symbol.order - b.symbol.order;
    });
    _prepareAtlasGlyphs(toDraw, devicePixelRatio);
    final drawn = <PlacedSymbol>[];
    if (!anyFading) {
      for (final drawable in toDraw) {
        drawable.draw(canvas, devicePixelRatio);
        drawn.add(drawable.symbol);
      }
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
    return drawn;
  }

  /// The tile→canvas transform of [paintTile]'s candidates: the canvas
  /// is already in logical tile coordinates, so it is the identity.
  static final _tileSpace =
      TileTransform(origin: Offset.zero, scale: 1, rotation: 0);

  /// `LabelMode.tile`'s whole label pass: places [symbols] — one display
  /// tile's candidates, as the layouter produced them — and draws the
  /// winners onto [canvas], which must already be in logical tile
  /// coordinates (0..256). Run once when the tile is rasterized, never
  /// per frame. Returns the drawn symbols, in draw order.
  ///
  /// The same preparation and drawing as [paint] — shaping, variable
  /// anchors, curved text and the glyph atlas, halos, SDF icons, repeat
  /// suppression — as one placing pass with nothing carried in or out:
  /// no fades, no throttle, no incumbents, and a placement memory and
  /// repeat anchors private to the call. The image is then a pure
  /// function of the tile's candidates, which is what lets the
  /// finished-tile cache serve it, and none of the screen pass's state
  /// is touched.
  ///
  /// Collision is resolved within the tile, and every collision box —
  /// of `*-allow-overlap` symbols too — must lie inside it: a label
  /// that would cross the tile edge is dropped, because the neighbour
  /// tile that would have to draw its other half never sees it.
  ///
  /// [styleZoom] is the tile's integer style zoom; it both evaluates
  /// the style and gates layers by their zoom range. [devicePixelRatio]
  /// is the canvas's scale to backing pixels, used exactly as [paint]
  /// uses the screen's: to size glyph-atlas cells and snap text.
  List<PlacedSymbol> paintTile({
    required Canvas canvas,
    required List<SymbolInstance> symbols,
    required double styleZoom,
    SpriteAtlas? sprites,
    double devicePixelRatio = 1,
  }) {
    developer.Timeline.startSync('VT tile labels');
    debugTilePaintCount++;
    final stopwatch = Stopwatch()..start();
    final screenMemory = _memory;
    final screenRepeats = _repeatAnchors;
    _memory = PlacementMemory();
    _repeatAnchors = {};
    try {
      _disposeRetired();
      _pass++;
      const tile = Size.square(displayTileSize);
      final candidates = [
        for (var i = 0; i < symbols.length; i++)
          PlacedSymbol(
            instance: symbols[i],
            screenAnchor: symbols[i].anchor,
            screenAngle: symbols[i].angle,
            transform: symbols[i].alongLine ? _tileSpace : null,
            order: i,
          ),
      ]..sort(_byPlacementPriority);
      final zoom = (styleZoom * _zoomStep).round() / _zoomStep;
      final collision = _CollisionIndex(tile, bounds: Offset.zero & tile);
      final toDraw = <_DrawableSymbol>[];
      var anyTranslucent = false;
      for (final candidate in candidates) {
        final drawable =
            _prepare(candidate, zoom, styleZoom, collision, sprites, tile);
        if (drawable == null) continue;
        final ramp = zoomRangeOpacity(candidate.instance.layer, styleZoom);
        final repeatKey = drawable.repeatKey;
        if (repeatKey != null && drawable.drawsText && ramp > 0) {
          (_repeatAnchors[repeatKey] ??= []).add(_RepeatAnchor(candidate));
        }
        drawable.opacity = ramp <= 0 ? 0 : _quantizeOpacity(ramp);
        toDraw.add(drawable);
        anyTranslucent |= drawable.opacity < 1;
      }
      return _draw(canvas, toDraw, devicePixelRatio, anyTranslucent);
    } finally {
      _memory = screenMemory;
      _repeatAnchors = screenRepeats;
      debugTilePaintMicros += stopwatch.elapsedMicroseconds;
      developer.Timeline.finishSync();
    }
  }

  /// Repeat suppression for `symbol-placement: line` text, rebuilt on
  /// every placing pass: per `(source, source-layer, text)`, the anchors
  /// whose text is on screen so far this pass.
  ///
  /// A street arrives as many features — one per OSM way, sometimes one
  /// per road-class style layer — and the layouter spaces anchors per
  /// feature, so the same name lands every few dozen pixels where the
  /// collision pass, which only rejects *overlapping* boxes, lets every
  /// copy through. MapLibre avoids this by joining same-text lines end
  /// to end inside a tile before spacing them; that would re-parametrize
  /// every street per data level and move its anchors at each crossing
  /// (see `SymbolLayouter._placeAlongLine` on why anchors keep their
  /// per-feature parametrization), so the duplicates are removed here
  /// instead, in the final screen-space pass — only a candidate that
  /// survived the exact zoom gate, opacity and collision may suppress a
  /// lower-priority fallback, and screen positions make the zone
  /// continuous across tile seams. [paintTile] swaps in a fresh map for
  /// the length of its pass, so there repeats are suppressed within the
  /// tile only.
  var _repeatAnchors = <Object, List<_RepeatAnchor>>{};

  /// Whether [placed] repeats text already on screen within [radius]
  /// (half of `symbol-spacing`) *on the same road*. Two anchors count as
  /// the same road when the displacement between them runs along
  /// either one's line direction — its across-line component is within
  /// [tolerance], one text height — so the split ways of one street
  /// suppress each other, while the two carriageways of a motorway, a
  /// street's neighbouring switchbacks, or parallel same-named roads,
  /// which sit *beside* each other, keep their labels as MapLibre
  /// keeps them. Anchors of one feature never suppress each other: the
  /// layouter already spaced them along the path.
  bool _repeatSuppressed(
    Object key,
    PlacedSymbol placed,
    double radius,
    double tolerance,
  ) {
    final anchors = _repeatAnchors[key];
    if (anchors == null || !(radius > 0) || !radius.isFinite) return false;
    final anchor = placed.screenAnchor;
    final path = placed.instance.path;
    final cosA = math.cos(placed.screenAngle);
    final sinA = math.sin(placed.screenAngle);
    for (final other in anchors) {
      if (path != null && identical(other.path, path)) continue;
      final d = anchor - other.anchor;
      if (d.distance >= radius) continue;
      final acrossOther = (d.dx * other.sin - d.dy * other.cos).abs();
      final acrossOwn = (d.dx * sinA - d.dy * cosA).abs();
      if (math.min(acrossOther, acrossOwn) <= tolerance) return true;
    }
    return false;
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
        // The anchor a variable-anchor label starts at; `text-justify:
        // auto` can follow it.
        final anchors =
            instance.alongLine ? null : _variableAnchors(layer, ctx);
        final text = _layoutText(instance, layer, ctx, fontSize,
            anchors?.first.anchor ?? layer.textAnchor.eval(ctx));
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
    // A replaying frame decides no space, so it also re-reads the space
    // decisions that change what is drawn rather than where: text or an
    // icon that lost its box at the last pass (`text-optional`,
    // `icon-optional`) stays dropped until the next one.
    final replaying = collision.permissive;
    if (!replaying) {
      sitting.textDropped = false;
      sitting.iconDropped = false;
    }
    final variableAnchors = instance.text.isNotEmpty && !instance.alongLine
        ? _variableAnchors(layer, ctx)
        : null;
    _LaidOutText? text;
    var fontSize = _shapeSize;
    var textScale = 1.0;
    if (!(replaying && sitting.textDropped) &&
        instance.text.isNotEmpty &&
        layer.textOpacity.eval(ctx) > 0) {
      final size = layer.textSize.eval(ctx);
      if (size >= _minVisibleTextSize) {
        fontSize = size.clamp(_minVisibleTextSize, 96.0);
        textScale = fontSize / _shapeSize;
        // `text-justify: auto` follows the anchor — with variable
        // anchors, the one the label sits at; a pass that moves it
        // re-justifies (see [_prepareVariableAnchor]).
        final anchorName = variableAnchors == null
            ? layer.textAnchor.eval(ctx)
            : sitting.anchor ?? variableAnchors.first.anchor;
        text = _layoutText(instance, layer, ctx, fontSize, anchorName);
      }
    }

    _DrawableIcon? icon;
    final iconName = instance.iconName;
    if (!(replaying && sitting.iconDropped) &&
        iconName != null &&
        sprites != null) {
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
          final pivot = anchor +
              _translation(
                  layer.iconTranslate, layer.iconTranslateAnchor, ctx, placed);
          final rect = _anchoredRect(
              layer.iconAnchor.eval(ctx), pivot + Offset(dx, dy), w, h);
          // `auto` follows the line when the symbol sits on one, else the
          // viewport — matching `text-rotation-alignment`'s default.
          // Explicit `map` alignment always includes the map bearing;
          // for an along-line symbol [screenAngle] also includes the
          // line's local bearing.
          final alignment = layer.iconRotationAlignment.eval(ctx);
          final followsMap =
              alignment == 'map' || (alignment == 'auto' && instance.alongLine);
          final rotateRad = layer.iconRotate.eval(ctx) * math.pi / 180;
          var rotation =
              followsMap ? placed.screenAngle + rotateRad : rotateRad;
          // `icon-keep-upright` turns an icon that follows its line
          // around where the line runs right to left on screen, deciding
          // that the way kept-upright text does.
          if (followsMap &&
              instance.alongLine &&
              layer.iconKeepUpright.eval(ctx) &&
              _readsBackwards(sitting, math.cos(placed.screenAngle))) {
            rotation += math.pi;
          }
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
            haloBlur: sprite.sdf ? layer.iconHaloBlur.eval(ctx) : 0,
            iconSize: iconSize,
            pivot: pivot,
            rotation: rotation,
            padding: _padding(layer.iconPadding.eval(ctx)),
          );
        }
      }
    }

    if (text == null && icon == null) return null;

    // Repeat suppression, decided here rather than before layout so the
    // exact opacity, size and placement evaluations above are not paid
    // twice. Placing frames only — a replay reproduces the last
    // decision — and never for retained-level or ghost candidates.
    Object? repeatKey;
    if (text != null &&
        instance.alongLine &&
        !replaying &&
        !placed.retained &&
        layer.placement.eval(ctx) == 'line') {
      final source = layer.source;
      final sourceLayer = layer.sourceLayer;
      if (source != null && sourceLayer != null) {
        repeatKey = (source, sourceLayer, instance.text);
        if (_repeatSuppressed(repeatKey, placed, layer.spacing.eval(ctx) / 2,
            text.size.height * textScale)) {
          debugRejectProbe?.call(instance.continuityKey, 'repeat', false);
          return null;
        }
      }
    }

    // `icon-text-fit` sizes the icon to the text's box, so the icon is
    // fitted wherever that box ends up.
    final fit = text != null && icon != null ? layer.iconTextFit.eval(ctx) : '';
    final fitting = fit == 'width' || fit == 'height' || fit == 'both';
    // `symbol-avoid-edges`: every box inside the tile the symbol was
    // laid out in. A replay reproduces the pass's decision.
    final edges = !replaying && layer.symbolAvoidEdges.eval(ctx)
        ? placed.transform?.tileBounds
        : null;
    // `symbol-z-order`, for what does get placed.
    _DrawableSymbol? ordered(_DrawableSymbol? drawable) =>
        drawable?..drawKey = _zOrderKey(layer, ctx, placed);
    final textAnchor = text == null
        ? anchor
        : anchor +
            _translation(
                layer.textTranslate, layer.textTranslateAnchor, ctx, placed);

    // Variable anchors: try each candidate until one fits.
    if (text != null && variableAnchors != null) {
      return ordered(_prepareVariableAnchor(
          placed,
          layer,
          ctx,
          text,
          fontSize,
          textScale,
          icon,
          fitting ? fit : null,
          variableAnchors,
          textAnchor,
          _pointTextAngle(layer, ctx, placed),
          collision,
          sitting,
          edges));
    }

    // Along-line text follows the line glyph by glyph, unless the style
    // pins it to the viewport, the script needs shaping we can't
    // preserve per-glyph, or an icon is fitted around it — a shield
    // stays a straight box, and so does the text in it.
    var textAngle = 0.0;
    if (text != null && instance.alongLine) {
      if (layer.textRotationAlignment.eval(ctx) != 'viewport') {
        if (!fitting &&
            instance.path != null &&
            placed.transform != null &&
            instance.curveSafe) {
          return ordered(_prepareCurved(placed, layer, ctx, text, fontSize,
              textScale, icon, textAnchor - anchor, collision, sitting, edges)
            ?..repeatKey = repeatKey);
        }
        textAngle = _uprightAngle(sitting, placed.screenAngle);
      }
    } else if (text != null) {
      textAngle = _pointTextAngle(layer, ctx, placed);
    }

    var textRect = Rect.zero;
    if (text != null) {
      // Shaped at the reference size: screen dimensions carry the scale.
      final width = text.size.width * textScale;
      final height = text.size.height * textScale;
      if (instance.alongLine) {
        // Along-line text is centered on the anchor.
        textRect =
            Rect.fromCenter(center: textAnchor, width: width, height: height);
      } else {
        final offset = layer.textOffset.eval(ctx);
        final em = fontSize;
        final shifted = textAnchor +
            Offset(
              offset.isNotEmpty ? offset[0] * em : 0,
              offset.length > 1 ? offset[1] * em : 0,
            );
        textRect =
            _anchoredRect(layer.textAnchor.eval(ctx), shifted, width, height);
      }
      if (fitting) {
        icon = _fitIcon(icon!, fit, layer, ctx, textRect, textAnchor,
            instance.alongLine ? textAngle : icon.rotation);
      }
    }

    // Everything else along a line, a road shield or an arrow, a
    // viewport-aligned name, a script drawn straight, has to fit on its
    // line too, as [_prepareCurved] makes curved text: MapLibre places a
    // line label only where all of it lies on the line, the longer of
    // its text and icon centred on the anchor. Without this a road
    // piece shorter than its shield carried one. An icon alone at
    // `line-center` is exempt, as in MapLibre. Like the curved fit,
    // this is a placement decision: a replay keeps what the last pass
    // accepted while zooming out grows the label against its line.
    if (instance.alongLine &&
        !replaying &&
        (text != null || layer.placement.eval(ctx) != 'line-center') &&
        !_fitsLine(placed, text, textScale, icon)) {
      debugRejectProbe?.call(instance.continuityKey, 'fit', false);
      return null;
    }

    final placement = _place(
      layer,
      ctx,
      collision,
      text == null
          ? null
          : [
              _rotatedBounds(textRect, textAnchor, textAngle)
                  .inflate(layer.textPadding.eval(ctx)),
            ],
      icon == null ? null : [icon.collisionBox],
      edges,
    );
    if (placement == null) {
      debugRejectProbe?.call(placed.instance.continuityKey, 'collision', false);
      return null;
    }
    _rememberDrops(sitting, placement, text != null, icon != null);
    return ordered(_DrawableSymbol(
      placed,
      icon: placement.icon ? icon : null,
      text: placement.text ? text : null,
      textRect: textRect,
      textAnchor: textAnchor,
      textAngle: textAngle,
      textScale: textScale,
    )..repeatKey = repeatKey);
  }

  /// MapLibre's rule for a symbol's text and icon: each is tested
  /// against the placed symbols with its own overlap mode (`*-overlap`,
  /// else `*-allow-overlap`), then `text-optional` / `icon-optional` say
  /// whether one may show without the other, and whatever shows reserves
  /// its space unless its `*-ignore-placement` says otherwise. Null
  /// [textBoxes] / [iconBoxes] mean the symbol has no text / icon;
  /// [textFits] false means it has text that cannot be placed at all
  /// (no anchor fits it, or its line bends too sharply), so only the
  /// icon may still show. [edges] confines every box, for
  /// `symbol-avoid-edges`. Returns what was placed, or null for
  /// nothing.
  ({bool text, bool icon})? _place(
    SymbolThemeLayer layer,
    EvalContext ctx,
    _CollisionIndex collision,
    List<Rect>? textBoxes,
    List<Rect>? iconBoxes,
    Rect? edges, {
    bool textFits = true,
  }) {
    final hasText = textBoxes != null;
    final hasIcon = iconBoxes != null;
    final textOverlap = hasText
        ? _overlapOf(layer.textOverlap, layer.textAllowOverlap, ctx)
        : _Overlap.never;
    final iconOverlap = hasIcon
        ? _overlapOf(layer.iconOverlap, layer.iconAllowOverlap, ctx)
        : _Overlap.never;
    var placeText =
        hasText && textFits && collision.free(textBoxes, textOverlap, edges);
    var placeIcon = hasIcon && collision.free(iconBoxes, iconOverlap, edges);
    final iconWithoutText = !hasText || layer.textOptional.eval(ctx);
    final textWithoutIcon = !hasIcon || layer.iconOptional.eval(ctx);
    if (!iconWithoutText && !textWithoutIcon) {
      placeText = placeIcon = placeText && placeIcon;
    } else if (!textWithoutIcon) {
      placeText = placeText && placeIcon;
    } else if (!iconWithoutText) {
      placeIcon = placeIcon && placeText;
    }
    if (!placeText && !placeIcon) return null;
    if (placeText && !layer.textIgnorePlacement.eval(ctx)) {
      collision.insert(textBoxes!, textOverlap);
    }
    if (placeIcon && !layer.iconIgnorePlacement.eval(ctx)) {
      collision.insert(iconBoxes!, iconOverlap);
    }
    return (text: placeText, icon: placeIcon);
  }

  /// Records which half of a placed symbol the pass dropped, so replay
  /// frames — which decide no space — keep it dropped.
  static void _rememberDrops(SittingPlacement sitting,
      ({bool text, bool icon}) placement, bool hasText, bool hasIcon) {
    if (hasText && !placement.text) sitting.textDropped = true;
    if (hasIcon && !placement.icon) sitting.iconDropped = true;
  }

  static _Overlap _overlapOf(
      StringProp? overlap, BoolProp allowOverlap, EvalContext ctx) {
    if (overlap == null) {
      return allowOverlap.eval(ctx) ? _Overlap.always : _Overlap.never;
    }
    return switch (overlap.eval(ctx)) {
      'always' => _Overlap.always,
      'cooperative' => _Overlap.cooperative,
      _ => _Overlap.never,
    };
  }

  /// `text-translate` / `icon-translate` as a screen offset: px right and
  /// down, turned with the map when its anchor is `map`.
  static Offset _translation(NumListProp translate, StringProp anchor,
      EvalContext ctx, PlacedSymbol placed) {
    final t = translate.eval(ctx);
    final dx = t.isNotEmpty ? t[0] : 0.0;
    final dy = t.length > 1 ? t[1] : 0.0;
    if (dx == 0 && dy == 0) return Offset.zero;
    if (anchor.eval(ctx) == 'viewport') return Offset(dx, dy);
    final bearing = placed.transform?.rotation ??
        (placed.instance.alongLine ? 0.0 : placed.screenAngle);
    if (bearing == 0) return Offset(dx, dy);
    final cosB = math.cos(bearing);
    final sinB = math.sin(bearing);
    return Offset(dx * cosB - dy * sinB, dx * sinB + dy * cosB);
  }

  /// The angle point-placed text is drawn at: `text-rotate`, plus the
  /// map's bearing when `text-rotation-alignment` is `map`.
  static double _pointTextAngle(
      SymbolThemeLayer layer, EvalContext ctx, PlacedSymbol placed) {
    var angle = layer.textRotate.eval(ctx) * math.pi / 180;
    if (layer.textRotationAlignment.eval(ctx) == 'map') {
      angle += placed.screenAngle;
    }
    return angle;
  }

  /// `icon-padding`'s one to four values as a CSS-order inset (top,
  /// right, bottom, left). A constant padding evaluates to the same list
  /// every time, so its inset is built once rather than per icon per
  /// frame.
  static EdgeInsets _padding(List<double> values) =>
      _paddings[values] ??= _insetsOf(values);

  static final _paddings = Expando<EdgeInsets>();

  static EdgeInsets _insetsOf(List<double> values) => switch (values.length) {
        0 => EdgeInsets.zero,
        1 => EdgeInsets.all(values[0]),
        2 => EdgeInsets.symmetric(vertical: values[0], horizontal: values[1]),
        3 => EdgeInsets.fromLTRB(values[1], values[0], values[1], values[2]),
        _ => EdgeInsets.fromLTRB(values[3], values[0], values[1], values[2]),
      };

  /// Where [placed] sorts among its layer's symbols when drawn —
  /// `symbol-z-order`, as MapLibre resolves it: by `symbol-sort-key`
  /// when the key varies by feature (and the order is not
  /// `viewport-y`), else by screen y when the order allows it and the
  /// layer lets symbols overlap, else in source order (0 — the
  /// insertion-order tiebreak then decides).
  static double _zOrderKey(
      SymbolThemeLayer layer, EvalContext ctx, PlacedSymbol placed) {
    final zOrder = layer.symbolZOrder.eval(ctx);
    final byKey = zOrder != 'viewport-y' && !layer.sortKey.isConstant;
    if (byKey) return placed.instance.sortKey;
    if (zOrder == 'source') return 0;
    final overlaps =
        _overlapOf(layer.textOverlap, layer.textAllowOverlap, ctx) !=
                _Overlap.never ||
            _overlapOf(layer.iconOverlap, layer.iconAllowOverlap, ctx) !=
                _Overlap.never ||
            layer.textIgnorePlacement.eval(ctx) ||
            layer.iconIgnorePlacement.eval(ctx);
    return overlaps ? placed.screenAnchor.dy : 0;
  }

  /// [icon] stretched around [textRect] per `icon-text-fit` [fit] — the
  /// fitted axes span the text plus `icon-text-fit-padding`, the others
  /// keep the icon's size, centred on the text — and turned with the
  /// text by [rotation] about [textAnchor]. A sprite declaring
  /// `stretchX` / `stretchY` stretches only there, keeping its other
  /// pixels at their size, and fits its `content` box to the text
  /// rather than its whole image, as in MapLibre.
  _DrawableIcon _fitIcon(
    _DrawableIcon icon,
    String fit,
    SymbolThemeLayer layer,
    EvalContext ctx,
    Rect textRect,
    Offset textAnchor,
    double rotation,
  ) {
    final sprite = icon.sprite;
    final unit = icon.iconSize / sprite.pixelRatio;
    final pad = layer.iconTextFitPadding.eval(ctx);
    double padAt(int i) => i < pad.length ? pad[i] : (pad.isEmpty ? 0 : pad[0]);
    final offset = layer.iconOffset.eval(ctx);
    final dx = offset.isNotEmpty ? offset[0] * icon.iconSize : 0.0;
    final dy = offset.length > 1 ? offset[1] * icon.iconSize : 0.0;
    final content = sprite.content;
    final xs = _fitAxis(
      fit != 'height',
      textRect.left + dx - padAt(3),
      textRect.right + dx + padAt(1),
      sprite.width,
      content?.left ?? 0,
      content?.right ?? sprite.width,
      sprite.stretchX,
      unit,
    );
    final ys = _fitAxis(
      fit != 'width',
      textRect.top + dy - padAt(0),
      textRect.bottom + dy + padAt(2),
      sprite.height,
      content?.top ?? 0,
      content?.bottom ?? sprite.height,
      sprite.stretchY,
      unit,
    );
    final rect =
        Rect.fromLTRB(xs.first.$3, ys.first.$3, xs.last.$4, ys.last.$4);
    return icon.fitted(
      rect: rect,
      pivot: textAnchor,
      rotation: rotation,
      cells: xs.length == 1 && ys.length == 1
          ? null
          : [
              for (final y in ys)
                for (final x in xs)
                  (
                    Rect.fromLTRB(sprite.x + x.$1, sprite.y + y.$1,
                        sprite.x + x.$2, sprite.y + y.$2),
                    Rect.fromLTRB(x.$3, y.$3, x.$4, y.$4),
                  ),
            ],
    );
  }

  /// One axis of [_fitIcon]: the sprite's slices along it, as (source
  /// from, source to, screen from, screen to). Without [fitted] the
  /// icon keeps its size, centred on [lo]..[hi]. Fitted, [contentLo] ..
  /// [contentHi] (sprite pixels) is mapped onto [lo]..[hi] (screen):
  /// the [stretch] ranges — the whole image when there are none — share
  /// whatever the fixed pixels, drawn at [unit] screen px per sprite
  /// px, leave of the span.
  static List<(double, double, double, double)> _fitAxis(
    bool fitted,
    double lo,
    double hi,
    double size,
    double contentLo,
    double contentHi,
    List<(double, double)>? stretch,
    double unit,
  ) {
    if (!fitted) {
      final start = (lo + hi) / 2 - size * unit / 2;
      return [(0, size, start, start + size * unit)];
    }
    final ranges = stretch == null || stretch.isEmpty ? [(0.0, size)] : stretch;
    final cuts = <double>{0, size, contentLo, contentHi};
    for (final (from, to) in ranges) {
      cuts
        ..add(from.clamp(0, size))
        ..add(to.clamp(0, size));
    }
    final sorted = cuts.toList()..sort();
    bool stretches(double from, double to) =>
        ranges.any((r) => from >= r.$1 && to <= r.$2);
    var stretchInContent = 0.0;
    var fixedInContent = 0.0;
    for (var i = 0; i + 1 < sorted.length; i++) {
      final from = sorted[i], to = sorted[i + 1];
      if (from < contentLo || to > contentHi) continue;
      if (stretches(from, to)) {
        stretchInContent += to - from;
      } else {
        fixedInContent += to - from;
      }
    }
    // Screen px per stretched sprite px: what the fixed pixels leave of
    // the span. Nothing stretchable inside the content box: the icon
    // cannot fit, and keeps its size.
    final k = stretchInContent > 0
        ? math.max(0.0, (hi - lo - fixedInContent * unit) / stretchInContent)
        : unit;
    final slices = <(double, double, double, double)>[];
    var at = 0.0;
    double? contentAt;
    for (var i = 0; i + 1 < sorted.length; i++) {
      final from = sorted[i], to = sorted[i + 1];
      if (from == contentLo) contentAt = at;
      final length = (to - from) * (stretches(from, to) ? k : unit);
      slices.add((from, to, at, at + length));
      at += length;
    }
    if (contentLo >= size) contentAt = at;
    // Shift so the content box starts at [lo] — or, when it could not
    // stretch, so it is centred on the span.
    final contentStart = contentAt ?? 0;
    final shift = stretchInContent > 0
        ? lo - contentStart
        : (lo + hi) / 2 - (contentStart + (contentHi - contentLo) * unit / 2);
    return [
      for (final (from, to, start, end) in slices)
        if (to > from) (from, to, start + shift, end + shift),
    ];
  }

  /// Whether [placed]'s label fits on its line: the longer of its text
  /// and its icon, centred on the anchor, within the line's ends.
  /// MapLibre's anchor test, with the label measured on screen and the
  /// line in tile-logical units, which [PlacedSymbol.transform] relates.
  static bool _fitsLine(PlacedSymbol placed, _LaidOutText? text,
      double textScale, _DrawableIcon? icon) {
    final instance = placed.instance;
    final path = instance.path;
    final transform = placed.transform;
    if (path == null || transform == null) return true;
    final length = math.max(text == null ? 0.0 : text.size.width * textScale,
        icon?.rect.width ?? 0.0);
    final half = length / 2 / transform.scale;
    return instance.pathDistance - half >= 0 &&
        instance.pathDistance + half <= path.length;
  }

  /// The anchors a variable-anchor label tries, each with its em offset:
  /// `text-variable-anchor-offset` as given; otherwise
  /// `text-variable-anchor` with `text-radial-offset` pointing away from
  /// each anchor, or — without a radial offset — `text-offset`'s
  /// magnitudes pointing away from it, as MapLibre turns them into
  /// per-anchor offsets. Null when the layer has no variable anchors.
  static List<AnchorOffset>? _variableAnchors(
      SymbolThemeLayer layer, EvalContext ctx) {
    final explicit = layer.textVariableAnchorOffset?.eval(ctx);
    if (explicit != null) return explicit.isEmpty ? null : explicit;
    final names = layer.textVariableAnchor?.eval(ctx);
    if (names == null || names.isEmpty) return null;
    final radial = layer.textRadialOffset.eval(ctx);
    final offset = layer.textOffset.eval(ctx);
    final ox = radial != 0 || offset.isEmpty ? 0.0 : offset[0].abs();
    final oy = radial != 0 || offset.length < 2 ? 0.0 : offset[1].abs();
    // A constant anchor list is the same object every time: its offsets
    // are worked out once per distinct offset, not per label per frame.
    final memo = _anchorOffsets[names];
    if (memo != null && memo.$1 == radial && memo.$2 == ox && memo.$3 == oy) {
      return memo.$4;
    }
    final anchors = _offsetsFor(names, radial, ox, oy);
    _anchorOffsets[names] = (radial, ox, oy, anchors);
    return anchors;
  }

  static final _anchorOffsets =
      Expando<(double, double, double, List<AnchorOffset>)>();

  static List<AnchorOffset> _offsetsFor(
      List<String> names, double radial, double ox, double oy) {
    if (radial != 0) {
      return [
        for (final name in names)
          () {
            final shift = _radialShift(name, math.max(0, radial));
            return (anchor: name, x: shift.dx, y: shift.dy);
          }(),
      ];
    }
    return [
      for (final name in names)
        (
          anchor: name,
          x: switch (name) {
            'left' || 'top-left' || 'bottom-left' => ox,
            'right' || 'top-right' || 'bottom-right' => -ox,
            _ => 0.0,
          },
          y: switch (name) {
            'top' || 'top-left' || 'top-right' => oy,
            'bottom' || 'bottom-left' || 'bottom-right' => -oy,
            _ => 0.0,
          },
        ),
    ];
  }

  /// Variable-anchor placement: anchors are tried in style order —
  /// except for the one this label was last placed at, which is tried
  /// ahead of them all — and the first whose text box fits the
  /// collision index wins, with the icon then placed as for any symbol
  /// (see [_place]). An icon fitted to the text moves with it, so it
  /// must fit at the anchor too.
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
    String? fit,
    List<AnchorOffset> anchors,
    Offset textAnchor,
    double textAngle,
    _CollisionIndex collision,
    SittingPlacement sitting,
    Rect? edges,
  ) {
    final padding = layer.textPadding.eval(ctx);
    final textOverlap =
        _overlapOf(layer.textOverlap, layer.textAllowOverlap, ctx);
    final iconOverlap =
        _overlapOf(layer.iconOverlap, layer.iconAllowOverlap, ctx);
    final width = text.size.width * textScale;
    final height = text.size.height * textScale;
    // Index -1 is the remembered anchor, which the style-order loop
    // then skips. A remembered anchor the style no longer offers (a
    // data-driven anchor list) is ignored.
    final remembered = sitting.anchor;
    AnchorOffset? seat;
    for (final entry in anchors) {
      if (entry.anchor == remembered) seat = entry;
    }
    for (var i = seat == null ? 0 : -1; i < anchors.length; i++) {
      final entry = i < 0 ? seat! : anchors[i];
      if (i >= 0 && identical(entry, seat)) continue;
      final textRect = _anchoredRect(
          entry.anchor,
          textAnchor + Offset(entry.x * fontSize, entry.y * fontSize),
          width,
          height);
      final textBoxes = [
        _rotatedBounds(textRect, textAnchor, textAngle).inflate(padding),
      ];
      if (!collision.free(textBoxes, textOverlap, edges)) continue;
      final fitted = fit == null || icon == null
          ? icon
          : _fitIcon(
              icon, fit, layer, ctx, textRect, textAnchor, icon.rotation);
      final iconBoxes = fitted == null ? null : [fitted.collisionBox];
      if (fit != null &&
          iconBoxes != null &&
          !collision.free(iconBoxes, iconOverlap, edges)) {
        continue;
      }
      // The text is free here, so only an icon it cannot do without can
      // still stop it — at every anchor alike, since an icon that is not
      // fitted to the text stays put.
      final placement =
          _place(layer, ctx, collision, textBoxes, iconBoxes, edges);
      if (placement == null) break;
      _rememberDrops(sitting, placement, true, icon != null);
      sitting.anchor = entry.anchor;
      // Text shaped for another anchor's `text-justify: auto` side is
      // laid out again for this one; the box is the same either way.
      final justified = _justify(layer.textJustify.eval(ctx), entry.anchor);
      final shaped = justified == text.justify
          ? text
          : _layoutText(placed.instance, layer, ctx, fontSize, entry.anchor);
      return _DrawableSymbol(placed,
          icon: placement.icon ? fitted : null,
          text: shaped,
          textRect: textRect,
          textAnchor: textAnchor,
          textAngle: textAngle,
          textScale: textScale);
    }
    // No anchor fits the text: the icon alone may still show.
    final placement = icon == null || fit != null
        ? null
        : _place(layer, ctx, collision, const [], [icon.collisionBox], edges,
            textFits: false);
    if (placement == null) {
      debugRejectProbe?.call(placed.instance.continuityKey, 'collision', false);
      return null;
    }
    _rememberDrops(sitting, placement, true, true);
    return _DrawableSymbol(placed, icon: icon);
  }

  /// Shift that moves the text box away from the anchor point by
  /// [r] (pixels or ems), in the direction implied by the anchor name.
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
  /// MapLibre. [shift] is `text-translate`, moving every glyph.
  _DrawableSymbol? _prepareCurved(
    PlacedSymbol placed,
    SymbolThemeLayer layer,
    EvalContext ctx,
    _LaidOutText text,
    double fontSize,
    double textScale,
    _DrawableIcon? icon,
    Offset shift,
    _CollisionIndex collision,
    SittingPlacement sitting,
    Rect? edges,
  ) {
    final instance = placed.instance;
    final path = instance.path!;
    final transform = placed.transform!;
    final clusters = text.clusters;
    if (clusters.isEmpty) return null;
    final textAnchor = placed.screenAnchor + shift;

    // Text that cannot go on its line at all: the icon alone may still
    // show, per `text-optional`.
    _DrawableSymbol? textRejected() {
      if (icon == null) return null;
      final placement = _place(
          layer, ctx, collision, const [], [icon.collisionBox], edges,
          textFits: false);
      if (placement == null) return null;
      _rememberDrops(sitting, placement, true, true);
      return _DrawableSymbol(placed, icon: icon);
    }

    // Places the text's [boxes] with the icon, then builds what shows;
    // null when neither does.
    _DrawableSymbol? placeWith(List<Rect> boxes,
        _DrawableSymbol Function(_DrawableIcon? icon) drawable) {
      final placement = _place(layer, ctx, collision, boxes,
          icon == null ? null : [icon.collisionBox], edges);
      if (placement == null) {
        debugRejectProbe?.call(
            placed.instance.continuityKey, 'collision', false);
        return null;
      }
      _rememberDrops(sitting, placement, true, icon != null);
      if (!placement.text) return _DrawableSymbol(placed, icon: icon);
      return drawable(placement.icon ? icon : null);
    }

    // What a replay or a ghost draws for a label it cannot curve: the
    // text straight along its anchor's bearing, until the next pass
    // decides. Both reproduce a label a pass accepted, and dropping it
    // instead left the sitting with nothing drawable — a street name
    // vanishing at full opacity, ghost and all.
    _DrawableSymbol straightAtAnchor() {
      final textRect = Rect.fromCenter(
          center: textAnchor,
          width: text.size.width * textScale,
          height: text.size.height * textScale);
      return _DrawableSymbol(placed,
          icon: icon,
          text: text,
          textRect: textRect,
          textAnchor: textAnchor,
          textAngle: layer.textKeepUpright.eval(ctx)
              ? _uprightAngle(sitting, placed.screenAngle)
              : placed.screenAngle,
          textScale: textScale);
    }

    // The label occupies [d0, d1] along the path, in logical units.
    // Cluster metrics are at the reference size; [textScale] converts
    // them to screen pixels before [scale] converts those to logical.
    final scale = transform.scale;
    final halfW = text.size.width * textScale / 2 / scale;
    final d0 = instance.pathDistance - halfW;
    final d1 = instance.pathDistance + halfW;
    if (d0 < 0 || d1 > path.length) {
      // Whether a label fits its line is a placement decision, like its
      // bend, and zooming out grows the text against its line every
      // frame.
      if (collision.permissive) return straightAtAnchor();
      debugRejectProbe?.call(instance.continuityKey, 'fit', false);
      return textRejected();
    }

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
    final keepUpright = layer.textKeepUpright.eval(ctx);
    final reversed = keepUpright && backwards;

    final offset = layer.textOffset.eval(ctx);
    final perp = offset.length > 1 ? offset[1] * fontSize : 0.0;
    // `text-max-angle` is a placement decision, so only a placement pass
    // takes it. A replay (or a ghost) reproduces a label the last pass
    // accepted: re-judging the bend there at every frame's zoom dropped
    // a winner — undrawn, and with no ghost either, since the ghost
    // re-runs this same check — each time the scaled glyph spacing
    // tipped the angle over the limit, then drew it again a frame
    // later. On a pass, a label already on screen keeps its seat up to
    // a quarter more bend than a newcomer may take, so one sitting near
    // the limit does not toggle as the zoom drifts across it.
    final maxAngle = collision.permissive
        ? double.infinity
        : layer.textMaxAngle.eval(ctx) *
            math.pi /
            180 *
            (placed.incumbent ? 1.25 : 1.0);

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
        // line bends too sharply for this label
        debugRejectProbe?.call(
            instance.continuityKey, 'angle', collision.permissive);
        return textRejected();
      }
      if (keepUpright && angle.abs() > math.pi / 2 + _uprightSlack) {
        // The reading direction is chosen once per label, from its
        // chord, so on a road that turns back on itself the glyphs past
        // the turn come out upside down (Petersplatz in Munich, which
        // loops around its church). `text-max-angle` cannot catch it:
        // it limits the turn between neighbouring glyphs, and a smooth
        // hairpin stays under the limit at every step. A pass rejects
        // the label; a replay or a ghost draws it straight.
        if (collision.permissive) return straightAtAnchor();
        debugRejectProbe?.call(instance.continuityKey, 'upright', false);
        return textRejected();
      }
      previousAngle = angle;
      firstAngle ??= angle;
      maxDeviation =
          math.max(maxDeviation, _foldAngle(angle - firstAngle).abs());
      var pos = transform.apply(path.pointAt(d)) + shift;
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

    // The window under the label is essentially straight: draw it as a
    // single rotated string, which is much cheaper.
    if (maxDeviation < 0.02 && perp == 0) {
      final angle = _orientAngle(placed.screenAngle, backwards);
      final textRect = Rect.fromCenter(
          center: textAnchor,
          width: text.size.width * textScale,
          height: text.size.height * textScale);
      return placeWith(
          [
            _rotatedBounds(textRect, textAnchor, angle).inflate(padding),
          ],
          (icon) => _DrawableSymbol(placed,
              icon: icon,
              text: text,
              textRect: textRect,
              textAnchor: textAnchor,
              textAngle: angle,
              textScale: textScale));
    }

    // Per-glyph collision boxes.
    final glyphHeight = fontSize * 1.2;
    return placeWith(
        [
          for (final p in placements)
            _rotatedBounds(
                    Rect.fromCenter(
                        center: p.pos, width: p.width, height: glyphHeight),
                    p.pos,
                    p.angle)
                .inflate(padding),
        ],
        (icon) => _DrawableSymbol(placed,
            icon: icon,
            curvedGlyphs: [
              for (final p in placements)
                _CurvedGlyph(
                  painters: _glyphPainters(p.grapheme, text),
                  position: p.pos,
                  angle: p.angle,
                ),
            ],
            textScale: textScale));
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
  /// `text-halo-width` / `text-halo-blur` enter it quantized: a
  /// `text-size` ramp reuses one shaped paragraph across the whole
  /// pinch, and opacity/halo ramps rotate the key a bounded number of
  /// times instead of per eval-zoom step. [anchor] is the text anchor
  /// the label is placed at, which `text-justify: auto` follows.
  _LaidOutText _layoutText(
    SymbolInstance instance,
    SymbolThemeLayer layer,
    EvalContext ctx,
    double fontSize,
    String anchor,
  ) =>
      _lookupText(instance, layer, ctx, fontSize,
          _justify(layer.textJustify.eval(ctx), anchor))
        ..pass = _pass;

  /// `text-justify` [value] resolved for text at [anchor]: `auto`
  /// justifies towards the side of the box the anchor is on.
  static String _justify(String value, String anchor) => switch (value) {
        'left' || 'right' => value,
        'auto' => switch (anchor) {
            'left' || 'top-left' || 'bottom-left' => 'left',
            'right' || 'top-right' || 'bottom-right' => 'right',
            _ => 'center',
          },
        _ => 'center',
      };

  _LaidOutText _lookupText(
    SymbolInstance instance,
    SymbolThemeLayer layer,
    EvalContext ctx,
    double fontSize,
    String justify,
  ) {
    // Fast path: at an unchanged eval zoom the memoized key is valid
    // as-is. Only the key: the laid-out text itself belongs to the LRU,
    // which may evict and dispose it.
    final memo = instance.textStyleMemo;
    if (memo != null && memo.zoom == ctx.zoom && memo.justify == justify) {
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
    // The blur is a font-size ratio like the width, for the same reason.
    final haloBlurQ = haloRatioQ == 0
        ? 0
        : (layer.textHaloBlur.eval(ctx).clamp(0.0, 8.0) / fontSize * 128)
            .round();
    final fillArgb = color.toARGB32();
    final haloArgb = haloRatioQ == 0 ? 0 : haloColor.toARGB32();
    final fonts = layer.textFont.eval(ctx);
    final letterSpacingEm = layer.textLetterSpacing.eval(ctx);
    final maxWidthEm = layer.textMaxWidth.eval(ctx);
    final lineHeightEm = layer.textLineHeight.eval(ctx);

    // A zoom step rarely moves any quantized primitive: revalidate the
    // memo by value and reuse its key strings without rebuilding them.
    if (memo != null &&
        memo.matches(fillArgb, haloArgb, haloRatioQ, haloBlurQ, fonts,
            letterSpacingEm, maxWidthEm, justify, lineHeightEm)) {
      memo.zoom = ctx.zoom;
      final memoized = _textCache.get(memo.cacheKey);
      if (memoized != null) return memoized;
      return _shape(instance, memo);
    }

    final styleKey = '$fillArgb|$haloArgb|$haloRatioQ|$haloBlurQ|'
        '${fonts.join(',')}|$letterSpacingEm|$lineHeightEm';
    // Along-line labels never wrap.
    final cacheKey = '${instance.text}|$styleKey|$maxWidthEm|$justify|'
        '${instance.alongLine}';
    final built = TextStyleMemo(
      fillArgb: fillArgb,
      haloArgb: haloArgb,
      haloRatioQ: haloRatioQ,
      haloBlurQ: haloBlurQ,
      fonts: fonts,
      letterSpacingEm: letterSpacingEm,
      maxWidthEm: maxWidthEm,
      justify: justify,
      lineHeightEm: lineHeightEm,
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
    var maxWidth = singleLine
        ? double.infinity
        : math.max(_shapeSize * memo.maxWidthEm, _shapeSize * 2);
    final style = _textStyle(memo.fonts, _shapeSize, memo.letterSpacingEm,
        Color(memo.fillArgb), memo.lineHeightEm);
    final align = switch (memo.justify) {
      'left' => TextAlign.left,
      'right' => TextAlign.right,
      _ => TextAlign.center,
    };
    var text = instance.text;
    // Laid out unconstrained first: that is the one layout after which
    // the min intrinsic width is the paragraph's widest unbreakable run.
    // After a constrained layout that broke a word, Skia reports a
    // width that depends on where it broke, often less than the word.
    // The box is as wide as the longest line, as MapLibre's is — not
    // `text-max-width` — and `text-justify` aligns the lines within it.
    final fill = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: align,
      textWidthBasis: TextWidthBasis.longestLine,
      maxLines: maxLines,
    )..layout();
    // Text on one line needs no second layout. Text that wraps keeps
    // every word whole, as in MapLibre, which breaks lines only where
    // the text allows a break: Flutter's line breaker splits a word
    // wider than `text-max-width` wherever the width runs out
    // (LUDWIGSVORST / ADT), so such text gets its breaks spelled out.
    if (fill.maxIntrinsicWidth > maxWidth) {
      if (fill.minIntrinsicWidth > maxWidth) {
        text = breakAroundWideRuns(text, style, maxWidth);
        // Every break is explicit now; a width could only add more.
        maxWidth = double.infinity;
        fill.text = TextSpan(text: text, style: style);
        fill.layout();
      } else {
        fill.layout(maxWidth: maxWidth);
      }
    }

    TextPainter? halo;
    TextStyle? haloStyle;
    // (haloBlurQ/128) · _shapeSize, as a Gaussian sigma.
    final blurSigma = memo.haloBlurQ / 8 * _haloBlurSigma;
    if (memo.haloRatioQ > 0) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        // 2 · (haloRatioQ/128) · _shapeSize
        ..strokeWidth = memo.haloRatioQ / 4
        ..strokeJoin = StrokeJoin.round
        ..color = Color(memo.haloArgb);
      if (blurSigma > 0) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, blurSigma);
      }
      haloStyle = style.copyWith(foreground: paint);
      halo = TextPainter(
        text: TextSpan(text: text, style: haloStyle),
        textDirection: TextDirection.ltr,
        textAlign: align,
        textWidthBasis: TextWidthBasis.longestLine,
        maxLines: maxLines,
      )..layout(maxWidth: maxWidth);
    }

    final laidOut = _LaidOutText(
      text: text,
      fill: fill,
      halo: halo,
      size: fill.size,
      styleKey: memo.styleKey,
      fillStyle: style,
      haloStyle: haloStyle,
      haloBlurSigma: blurSigma,
      justify: memo.justify,
    ).._haloPicture;
    _textCache.put(memo.cacheKey, laidOut);
    return laidOut;
  }

  /// [text] with explicit line breaks for a `text-max-width` of
  /// [maxWidth] that one of its unbreakable runs — a word, to the line
  /// breaker — is wider than. Each such word gets a line of its own
  /// instead of being split where the width runs out, and the words
  /// between them wrap at [maxWidth] as before.
  ///
  /// Laying the whole text out at the widest word's width instead would
  /// also keep it whole, but let the greedy line breaker pull the short
  /// words around it onto lines wider than `text-max-width`. Only text
  /// with such a word gets here; it pays a layout per word.
  @visibleForTesting
  static String breakAroundWideRuns(
      String text, TextStyle style, double maxWidth) {
    final lines = <String>[];
    final words = <String>[];
    void addLines(String run, double width) {
      final painter = TextPainter(
        text: TextSpan(text: run, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      // Each character goes to the line its box sits on. Engines differ
      // on which line `getLineBoundary` gives the offset of a soft
      // break; a box's top does not, measured to the line's full height.
      final line = StringBuffer();
      double? top;
      for (var i = 0; i < run.length; i++) {
        final boxes = painter.getBoxesForSelection(
            TextSelection(baseOffset: i, extentOffset: i + 1),
            boxHeightStyle: ui.BoxHeightStyle.max);
        if (boxes.isNotEmpty) {
          if (top != null && boxes.first.top > top + 0.5) {
            lines.add(line.toString().trim());
            line.clear();
          }
          top = boxes.first.top;
        }
        line.write(run[i]);
      }
      lines.add(line.toString().trim());
      painter.dispose();
    }

    void flushWords() {
      if (words.isEmpty) return;
      addLines(words.join(' '), maxWidth);
      words.clear();
    }

    for (final paragraph in text.split('\n')) {
      for (final word in paragraph.split(' ')) {
        if (word.isEmpty) continue;
        final probe = TextPainter(
          text: TextSpan(text: word, style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final widest = probe.minIntrinsicWidth;
        probe.dispose();
        if (widest <= maxWidth) {
          words.add(word);
          continue;
        }
        flushWords();
        addLines(word, widest.ceilToDouble());
      }
      flushWords();
    }
    return lines.where((line) => line.isNotEmpty).join('\n');
  }

  /// Resolves the atlas cells of every curved label in [toDraw],
  /// rasterizing glyphs met for the first time, and hands each label its
  /// sprite batches. A label with any glyph missing from the atlas keeps
  /// none and draws glyph by glyph.
  void _prepareAtlasGlyphs(
      List<_DrawableSymbol> toDraw, double devicePixelRatio) {
    _glyphAtlas.beginFrame();
    final pending = <_DrawableSymbol>[];
    for (final drawable in toDraw) {
      final glyphs = drawable.curvedGlyphs;
      if (glyphs == null) continue;
      final deviceScale = devicePixelRatio *
          _DrawableSymbol._snapTextScale(drawable.textScale, devicePixelRatio);
      final sizeKey = (deviceScale * 64).round();
      final halos = <(GlyphAtlasCell, _CurvedGlyph, Offset)>[];
      final fills = <(GlyphAtlasCell, _CurvedGlyph, Offset)>[];
      var complete = true;
      for (final glyph in glyphs) {
        final painters = glyph.painters;
        for (final halo in const [true, false]) {
          final painter = halo ? painters.halo : painters.fill;
          if (painter == null) continue;
          final pad = painters.pad;
          final key = (painters.key, halo, sizeKey);
          final cell = _glyphAtlas.lookup(key) ??
              (rasterizeGlyphs
                  ? _glyphAtlas.reserve(
                      key,
                      ((painter.width + 2 * pad) * deviceScale).ceil(),
                      ((painter.height + 2 * pad) * deviceScale).ceil(),
                      (canvas) {
                        canvas.scale(deviceScale);
                        painter.paint(canvas, Offset(pad, pad));
                      },
                    )
                  : null);
          if (cell == null) {
            complete = false;
            break;
          }
          final anchor = Offset((pad + painter.width / 2) * deviceScale,
              (pad + painter.height / 2) * deviceScale);
          (halo ? halos : fills).add((cell, glyph, anchor));
        }
        if (!complete) break;
      }
      drawable.atlasSprites = null;
      if (!complete) continue;
      drawable.atlasSprites = [
        ..._spriteBatches(halos, devicePixelRatio),
        ..._spriteBatches(fills, devicePixelRatio),
      ];
      pending.add(drawable);
    }
    _glyphAtlas.flush();
    for (final drawable in pending) {
      for (final batch in drawable.atlasSprites!) {
        final image = _glyphAtlas.imageOf(batch.cell);
        if (image == null) {
          drawable.atlasSprites = null;
          break;
        }
        batch.image = image;
      }
    }
  }

  /// One sprite batch per atlas page, in glyph order.
  static List<_SpriteBatch> _spriteBatches(
      List<(GlyphAtlasCell, _CurvedGlyph, Offset)> sprites,
      double devicePixelRatio) {
    final byPage = <int, List<(GlyphAtlasCell, _CurvedGlyph, Offset)>>{};
    for (final sprite in sprites) {
      (byPage[sprite.$1.page] ??= []).add(sprite);
    }
    return [
      for (final page in byPage.values)
        _SpriteBatch(page.first.$1, () {
          final transforms = Float32List(page.length * 4);
          final rects = Float32List(page.length * 4);
          final scale = 1 / devicePixelRatio;
          for (var i = 0; i < page.length; i++) {
            final (cell, glyph, anchor) = page[i];
            // The atlas holds device pixels; drawn at 1/dpr they come
            // out at the snapped logical size, rotated about the
            // glyph's centre like the paragraph path.
            final scos = math.cos(glyph.angle) * scale;
            final ssin = math.sin(glyph.angle) * scale;
            transforms[i * 4] = scos;
            transforms[i * 4 + 1] = ssin;
            transforms[i * 4 + 2] =
                glyph.position.dx - scos * anchor.dx + ssin * anchor.dy;
            transforms[i * 4 + 3] =
                glyph.position.dy - ssin * anchor.dx - scos * anchor.dy;
            final rect = cell.rect;
            rects[i * 4] = rect.left;
            rects[i * 4 + 1] = rect.top;
            rects[i * 4 + 2] = rect.right;
            rects[i * 4 + 3] = rect.bottom;
          }
          return (transforms, rects);
        }()),
    ];
  }

  /// Painters for a single glyph cluster, cached across labels — the
  /// same characters repeat constantly in map text.
  _GlyphText _glyphPainters(String grapheme, _LaidOutText text) {
    final key = '${text.styleKey}#$grapheme';
    final cached = _glyphCache.get(key);
    if (cached != null) return cached..pass = _pass;

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
    // Room for the halo stroke, which straddles the outline, its blur,
    // and glyph overhang past the advance box.
    final stroke = text.haloStyle?.foreground?.strokeWidth ?? 0;
    final glyph = _GlyphText(
        key: key,
        fill: fill,
        halo: halo,
        pad: 2 + stroke / 2 + 3 * text.haloBlurSigma)
      ..pass = _pass;
    _glyphCache.put(key, glyph);
    return glyph;
  }

  static TextStyle _textStyle(
    List<String> fonts,
    double fontSize,
    double letterSpacingEm,
    ui.Color color,
    double lineHeightEm,
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
      // `text-line-height`: baselines this many ems apart, and one line's
      // box this tall, as MapLibre sizes it.
      height: lineHeightEm > 0 ? lineHeightEm : 1.2,
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
    if (angle == 0) return rect;
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    final delta = rect.center - pivot;
    final center = pivot +
        Offset(
          delta.dx * cosA - delta.dy * sinA,
          delta.dx * sinA + delta.dy * cosA,
        );
    final absCos = cosA.abs();
    final absSin = sinA.abs();
    final w = rect.width * absCos + rect.height * absSin;
    final h = rect.width * absSin + rect.height * absCos;
    return Rect.fromCenter(center: center, width: w, height: h);
  }

  void dispose() {
    _textCache.clear();
    _glyphCache.clear();
    _glyphAtlas.clear();
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

  /// The halo's blur sigma at the reference size; 0 for a crisp halo.
  final double haloBlurSigma;

  /// The `text-justify` side the lines are aligned to — never `auto`.
  final String justify;

  /// The label pass that last used this text — see
  /// [LabelPainter.trimCaches].
  int pass = 0;

  List<_Cluster>? _clusters;

  /// A blurred halo, recorded once, when the text is shaped. Impeller
  /// blurs text drawn with a mask filter in an offscreen pass, and
  /// reuses the result on later frames only for the very same text
  /// object at the same scale — a paragraph paint makes a new one every
  /// time, a recorded picture replays the one it holds. Painted
  /// directly, every blurred label would cost its own offscreen pass on
  /// every frame. Recorded with the shaping, so the render pump pays
  /// for it, not the frame that first draws the label.
  late final ui.Picture? _haloPicture = () {
    final halo = this.halo;
    if (halo == null || haloBlurSigma <= 0) return null;
    final recorder = ui.PictureRecorder();
    halo.paint(Canvas(recorder), Offset.zero);
    return recorder.endRecording();
  }();

  _LaidOutText({
    required this.text,
    required this.fill,
    required this.halo,
    required this.size,
    required this.styleKey,
    required this.fillStyle,
    required this.haloStyle,
    this.haloBlurSigma = 0,
    this.justify = 'center',
  });

  /// Paints the halo, if there is one, with its top-left at [topLeft].
  void paintHalo(Canvas canvas, Offset topLeft) {
    final halo = this.halo;
    if (halo == null) return;
    final picture = _haloPicture;
    if (picture == null) {
      halo.paint(canvas, topLeft);
      return;
    }
    canvas.save();
    canvas.translate(topLeft.dx, topLeft.dy);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  /// Grapheme clusters with their advance-centre x positions in the
  /// laid-out string — spacing and kerning come from the full layout,
  /// so curved glyphs keep the string's metrics. Whitespace clusters
  /// are omitted (their advance still separates the neighbours).
  List<_Cluster> get clusters => _clusters ??= _computeClusters();

  void dispose() {
    fill.dispose();
    halo?.dispose();
    if (haloBlurSigma > 0) _haloPicture?.dispose();
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
  /// The glyph cache key: style and grapheme.
  final String key;
  final TextPainter fill;
  final TextPainter? halo;

  /// Reference-size margin around the painters' boxes that the atlas
  /// cell keeps, so halo strokes and overhangs are not clipped.
  final double pad;

  /// The label pass that last used this glyph — see
  /// [LabelPainter.trimCaches].
  int pass = 0;

  _GlyphText({
    required this.key,
    required this.fill,
    required this.halo,
    required this.pad,
  });

  void dispose() {
    fill.dispose();
    halo?.dispose();
  }
}

/// Curved-label glyphs that share one atlas page, as `drawRawAtlas`
/// arguments. [image] is filled in once the atlas has been flushed.
class _SpriteBatch {
  final GlyphAtlasCell cell;
  final Float32List transforms;
  final Float32List rects;
  ui.Image? image;

  _SpriteBatch(this.cell, (Float32List, Float32List) data)
      : transforms = data.$1,
        rects = data.$2;
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

  /// `icon-halo-blur`, in px: the halo's edge fades over ±1.19 × this,
  /// as in MapLibre's shader.
  final double haloBlur;

  /// `icon-size`, which `icon-halo-width` is measured relative to.
  final double iconSize;

  /// Screen-space symbol anchor. Rotation includes [rect]'s anchor and
  /// offset, so both move around this point with the icon.
  final Offset pivot;

  /// Radians, clockwise: `icon-rotate` plus the line/map angle
  /// `icon-rotation-alignment` resolved to. Rotates about [pivot], so
  /// `icon-anchor` and `icon-offset` turn with the sprite.
  final double rotation;

  /// `icon-padding`, around [bounds] in [collisionBox].
  final EdgeInsets padding;

  /// For an icon stretched by `icon-text-fit` around a sprite's
  /// `stretchX` / `stretchY` zones: each slice of the sprite (in the
  /// sheet) and where it is drawn, together covering [rect]. Null draws
  /// the whole sprite into [rect].
  final List<(Rect, Rect)>? cells;

  _DrawableIcon({
    required this.atlas,
    required this.sprite,
    required this.rect,
    required this.opacity,
    this.tint,
    this.haloColor,
    this.haloWidth = 0,
    this.haloBlur = 0,
    this.iconSize = 1,
    required this.pivot,
    this.rotation = 0,
    this.padding = const EdgeInsets.all(2),
    this.cells,
  });

  /// This icon drawn into [rect] instead, sliced by [cells], about
  /// [pivot] at [rotation] — `icon-text-fit`'s result.
  _DrawableIcon fitted({
    required Rect rect,
    required Offset pivot,
    required double rotation,
    List<(Rect, Rect)>? cells,
  }) =>
      _DrawableIcon(
        atlas: atlas,
        sprite: sprite,
        rect: rect,
        opacity: opacity,
        tint: tint,
        haloColor: haloColor,
        haloWidth: haloWidth,
        haloBlur: haloBlur,
        iconSize: iconSize,
        pivot: pivot,
        rotation: rotation,
        padding: padding,
        cells: cells,
      );

  /// Screen extent of the (rotated) sprite. Read once per collision
  /// box, fallback attempt, variable anchor tried and fade layer, so
  /// the rotation maths runs once rather than per read.
  late final Rect bounds =
      rotation == 0 ? rect : LabelPainter._rotatedBounds(rect, pivot, rotation);

  /// [bounds] plus `icon-padding`: the space the icon claims.
  late final Rect collisionBox = Rect.fromLTRB(
      bounds.left - padding.left,
      bounds.top - padding.top,
      bounds.right + padding.right,
      bounds.bottom + padding.bottom);

  void draw(Canvas canvas, double devicePixelRatio) {
    if (rotation == 0) {
      _paint(canvas, devicePixelRatio);
      return;
    }
    canvas.save();
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(rotation);
    canvas.translate(-pivot.dx, -pivot.dy);
    _paint(canvas, devicePixelRatio);
    canvas.restore();
  }

  void _paint(Canvas canvas, double devicePixelRatio) {
    final color = tint;
    if (color == null) {
      _drawSprite(
        canvas,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..color = Color.fromRGBO(255, 255, 255, opacity),
      );
      return;
    }
    final halo = haloColor;
    if (halo != null && halo.a > 0 && haloWidth > 0) {
      _drawSprite(
        canvas,
        _sdfPaint(
          halo,
          ((6 - haloWidth / iconSize) / _sdfTexels).clamp(0.0, _sdfEdge),
          devicePixelRatio,
          blur: haloBlur,
        ),
      );
    }
    _drawSprite(canvas, _sdfPaint(color, _sdfEdge, devicePixelRatio));
  }

  void _drawSprite(Canvas canvas, Paint paint) {
    final cells = this.cells;
    if (cells == null) {
      canvas.drawImageRect(atlas.image, sprite.sourceRect, rect, paint);
      return;
    }
    for (final (source, target) in cells) {
      canvas.drawImageRect(atlas.image, source, target, paint);
    }
  }

  /// Thresholds the distance field at [edge] and tints what survives
  /// with [color]. A colour matrix is applied *after* texture sampling,
  /// so the threshold lands on interpolated distances and the edge stays
  /// crisp at any scale — the same reason MapLibre does this in a
  /// fragment shader. The ramp is steepened to span roughly one device
  /// pixel at the size this icon is drawn, which is what antialiases it,
  /// widened by 2 × 1.19 × [blur] px for a blurred halo.
  Paint _sdfPaint(Color color, double edge, double devicePixelRatio,
      {double blur = 0}) {
    // Device px per sprite texel, at the icon's own scale (a stretched
    // icon keeps it in its fixed slices).
    final drawnPerTexel = iconSize / sprite.pixelRatio * devicePixelRatio;
    final rampPixels = 1 + 2 * 1.19 * blur * devicePixelRatio;
    final slope = (_sdfTexels * drawnPerTexel / rampPixels)
        .clamp(blur > 0 ? 0.5 : 4.0, 128.0);
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

/// One along-line label on screen this pass, as [LabelPainter._repeatSuppressed]
/// compares later candidates against it: where it sits, the unit
/// tangent of its line there, and the path it was laid out on.
class _RepeatAnchor {
  final Offset anchor;
  final double cos;
  final double sin;
  final SymbolPath? path;

  _RepeatAnchor(PlacedSymbol placed)
      : anchor = placed.screenAnchor,
        cos = math.cos(placed.screenAngle),
        sin = math.sin(placed.screenAngle),
        path = placed.instance.path;
}

class _DrawableSymbol {
  final PlacedSymbol symbol;
  final _DrawableIcon? icon;
  final _LaidOutText? text;

  /// The text's box before [textAngle] turns it about [textAnchor].
  final Rect textRect;

  /// The point text turns about: the symbol's anchor, moved by
  /// `text-translate`.
  final Offset textAnchor;
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

  /// The [LabelPainter._repeatAnchors] key this symbol's text registers
  /// under once it is drawn, or null when repeat suppression does not
  /// apply to it. Assigned by [LabelPainter._prepare] like [opacity].
  Object? repeatKey;

  /// Atlas sprite batches for [curvedGlyphs], halos first; null when the
  /// glyphs draw as paragraphs. Assigned by
  /// [LabelPainter._prepareAtlasGlyphs] before drawing.
  List<_SpriteBatch>? atlasSprites;

  /// Where this symbol sorts within its layer when drawn, per
  /// `symbol-z-order` (see [LabelPainter._zOrderKey]). Assigned by
  /// [LabelPainter._prepare] like [opacity].
  double drawKey = 0;

  static final _atlasPaint = Paint()..filterQuality = FilterQuality.low;

  bool get drawsText => text != null || curvedGlyphs != null;

  _DrawableSymbol(
    this.symbol, {
    this.icon,
    this.text,
    this.textRect = Rect.zero,
    Offset? textAnchor,
    this.textAngle = 0,
    this.textScale = 1,
    this.curvedGlyphs,
  }) : textAnchor = textAnchor ?? symbol.screenAnchor;

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
    if (icon != null) add(icon.bounds);
    final glyphs = curvedGlyphs;
    final text = this.text;
    if (glyphs != null) {
      for (final glyph in glyphs) {
        final painter = glyph.painters.halo ?? glyph.painters.fill;
        add(sweptCircle(glyph.position, painter.width, painter.height));
      }
    } else if (text != null) {
      add(LabelPainter._rotatedBounds(textRect, textAnchor, textAngle));
    }
    return result ?? Rect.zero;
  }

  void draw(Canvas canvas, double devicePixelRatio) {
    icon?.draw(canvas, devicePixelRatio);
    final textScale = _snapTextScale(this.textScale, devicePixelRatio);
    final sprites = atlasSprites;
    if (sprites != null) {
      for (final batch in sprites) {
        canvas.drawRawAtlas(batch.image!, batch.transforms, batch.rects, null,
            null, null, _atlasPaint);
      }
      return;
    }
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
      // Turned about the anchor; a box offset from it (point text with
      // an anchor or offset) keeps that offset in the turned frame.
      canvas.save();
      canvas.translate(textAnchor.dx, textAnchor.dy);
      canvas.rotate(textAngle);
      final centre = textRect.center - textAnchor;
      if (centre != Offset.zero) canvas.translate(centre.dx, centre.dy);
      if (textScale != 1) canvas.scale(textScale);
      final topLeft = Offset(-t.size.width / 2, -t.size.height / 2);
      t.paintHalo(canvas, topLeft);
      t.fill.paint(canvas, topLeft);
      canvas.restore();
    } else if (textScale != 1) {
      // Scaled about the centre: the snapped scale may differ from the
      // one [textRect] was sized with by a fraction of a pixel, and
      // that difference must not shift the label off its box.
      canvas.save();
      canvas.translate(textRect.center.dx, textRect.center.dy);
      canvas.scale(textScale);
      final topLeft = Offset(-t.size.width / 2, -t.size.height / 2);
      t.paintHalo(canvas, topLeft);
      t.fill.paint(canvas, topLeft);
      canvas.restore();
    } else {
      t.paintHalo(canvas, textRect.topLeft);
      t.fill.paint(canvas, textRect.topLeft);
    }
  }

  /// [scale] snapped so the drawn font size lands on whole device
  /// pixels. Impeller keys its glyph atlas by the device text scale
  /// rounded to 1/200, so an unsnapped `text-size` ramp hands it a new
  /// size at every eval-zoom step and every visible glyph, halo stroke
  /// included, is rasterized again on the raster thread. Snapped, a
  /// ramp only produces a new size once per device pixel of font
  /// size, and sizes seen before stay cached.
  ///
  /// Snapped down, never up: collision placed the text at the exact
  /// scale, and a label drawn larger than its box could overlap a
  /// neighbour that the box kept clear. The epsilon keeps a scale that
  /// is already on the grid from losing a pixel to float error.
  static double _snapTextScale(double scale, double devicePixelRatio) {
    if (scale == 1) return 1;
    final unit = LabelPainter._shapeSize * devicePixelRatio;
    return math.max(1, (scale * unit + 1e-6).floor()) / unit;
  }
}

/// How a symbol's box may overlap the boxes already placed —
/// `text-overlap` / `icon-overlap`, or `*-allow-overlap` (always/never)
/// when those are unset.
enum _Overlap {
  /// Collides with every placed box.
  never,

  /// Collides with nothing.
  always,

  /// Collides only with boxes placed in [never] mode.
  cooperative,
}

/// Grid-bucketed screen-space collision index. Boxes placed in
/// [_Overlap.never] mode and the rest are bucketed apart, since a
/// `cooperative` symbol tests only the former.
class _CollisionIndex {
  static const double _cellSize = 128;
  final Map<int, List<Rect>> _cells = {};
  final Map<int, List<Rect>> _overlapCells = {};
  final int _columns;
  final bool _permissive;

  _CollisionIndex(Size screenSize, {this.bounds})
      : _columns = math.max(1, (screenSize.width / _cellSize).ceil() + 4),
        _permissive = false;

  /// An index that accepts everything and reserves nothing — for
  /// fade-out ghosts, which draw wherever they were without claiming
  /// space or blocking each other, and for the frames that replay a
  /// frozen placement, where the decision has already been taken.
  _CollisionIndex.permissive()
      : _columns = 1,
        _permissive = true,
        bounds = null;

  /// The area every box must lie within, or null for none — the tile's
  /// own square in [LabelPainter.paintTile], where a label crossing the
  /// tile edge would be cut off by it.
  final Rect? bounds;

  /// Whether this index decides nothing. Symbol preparation reads it to
  /// replay the parts of a placement that space, not geometry, decided
  /// — which anchor a label took, whether its text was dropped.
  bool get permissive => _permissive;

  /// Whether [rects] lie within [bounds]. The one test that
  /// `*-allow-overlap` symbols, which skip collisions, still face.
  bool fits(List<Rect> rects) {
    final bounds = this.bounds;
    if (bounds == null) return true;
    return _within(rects, bounds);
  }

  static bool _within(List<Rect> rects, Rect area) {
    for (final rect in rects) {
      if (rect.left < area.left ||
          rect.top < area.top ||
          rect.right > area.right ||
          rect.bottom > area.bottom) {
        return false;
      }
    }
    return true;
  }

  /// Whether [rects] could be placed in [overlap] mode: within [bounds]
  /// and [edges] (`symbol-avoid-edges`), and clear of the boxes that
  /// mode collides with. Reserves nothing; see [insert].
  bool free(List<Rect> rects, _Overlap overlap, [Rect? edges]) {
    if (_permissive) return true;
    if (!fits(rects)) return false;
    if (edges != null && !_within(rects, edges)) return false;
    if (overlap == _Overlap.always) return true;
    for (final rect in rects) {
      if (_collides(_cells, rect)) return false;
      if (overlap == _Overlap.never && _collides(_overlapCells, rect)) {
        return false;
      }
    }
    return true;
  }

  /// Reserves [rects], placed in [overlap] mode. A symbol that allows
  /// overlap still reserves its space, as in MapLibre: it may be drawn
  /// over others, but later symbols that may not overlap avoid it.
  void insert(List<Rect> rects, _Overlap overlap) {
    if (_permissive) return;
    final cells = overlap == _Overlap.never ? _cells : _overlapCells;
    for (final rect in rects) {
      _insert(cells, rect);
    }
  }

  // The cell walks are inlined in both callers: a sync* generator here
  // allocated an iterator per collision box per frame in the hottest
  // label loop.

  bool _collides(Map<int, List<Rect>> cells, Rect rect) {
    if (cells.isEmpty) return false;
    final minX = ((rect.left + 512) / _cellSize).floor();
    final maxX = ((rect.right + 512) / _cellSize).floor();
    final minY = ((rect.top + 512) / _cellSize).floor();
    final maxY = ((rect.bottom + 512) / _cellSize).floor();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final rects = cells[y * _columns + x];
        if (rects == null) continue;
        for (final other in rects) {
          if (rect.overlaps(other)) return true;
        }
      }
    }
    return false;
  }

  void _insert(Map<int, List<Rect>> cells, Rect rect) {
    final minX = ((rect.left + 512) / _cellSize).floor();
    final maxX = ((rect.right + 512) / _cellSize).floor();
    final minY = ((rect.top + 512) / _cellSize).floor();
    final maxY = ((rect.bottom + 512) / _cellSize).floor();
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        (cells[y * _columns + x] ??= []).add(rect);
      }
    }
  }
}
