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
import 'label_worker.dart';
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

  /// The label this candidate is a copy of, as `LabelIdentityIndex`
  /// assigned it. Every copy of one label — seam twins, the outgoing and
  /// arriving level's at a crossing, a republished tile's successor —
  /// carries the same id, so the painter's winners, fades and placement
  /// memory follow the label rather than the instance, and at most one
  /// copy per id draws in a frame. Distinct labels never share one.
  final int id;
  final Offset screenAnchor;

  /// Screen-space map angle for point symbols, or map plus local line
  /// bearing for along-line symbols (radians).
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
    required this.id,
    required this.screenAnchor,
    required this.screenAngle,
    this.transform,
    this.ghostOnly = false,
    this.retained = false,
    this.order = 0,
  });
}

/// One label a paint actually drew, as reported to
/// [LabelPainter.debugDrawnProbe]: its continuity key, its label id,
/// its screen anchor, the opacity it drew at, whether it was a fade-out
/// ghost, and whether it is an along-line label.
typedef DrawnLabelRecord = ({
  Object key,
  int id,
  Offset position,
  double opacity,
  bool ghost,
  bool alongLine,
});

/// One display tile's candidates as the layer offers them to
/// [LabelPainter.paint], next to the flattened candidate list: what a
/// placement worker needs to project them itself. [ids] are the label
/// ids of [symbols], and [order] is the [PlacedSymbol.order] of the
/// list's first candidate.
typedef LabelCohortInput = ({
  List<SymbolInstance> symbols,
  Int32List ids,
  TileTransform transform,
  bool ghostOnly,
  bool retained,
  int order,
});

/// Draws all visible labels/icons in one screen-space pass per frame,
/// with global collision detection across tile borders. Text stays
/// crisp at fractional zoom and upright under rotation.
///
/// `LabelMode.tile` runs the same placement and drawing once per tile
/// instead, into the tile's raster — see [paintTile].
class LabelPainter {
  LabelPainter() : _measured = null;

  /// The painter a placement worker runs passes with: it never shapes
  /// or draws, and places text by the metrics the UI's shaping measured,
  /// mirrored with each symbol list ([adoptMirror]).
  @internal
  LabelPainter.worker() : _measured = Expando<_MeasuredText>();

  /// Mirrored text metrics, per instance — set only in a worker.
  final Expando<_MeasuredText>? _measured;

  /// The sprite index a worker places icons by; the screen pass reads
  /// it from the atlas it is handed instead.
  Map<String, Sprite>? _workerSprites;

  /// Where this painter's placement passes run, when not in-frame. Set
  /// by the layer on platforms with isolates; see [LabelPlacementWorker].
  LabelPlacementWorker? worker;

  /// The pass request awaiting the worker's answer, and the answer once
  /// it has arrived — adopted by the next [paint].
  _PassInFlight? _inFlight;
  LabelPassResult? _arrived;
  var _requests = 0;
  var _frames = 0;

  /// The worker's per-winner choices, by label id, written into
  /// [_memory] on the frame that adopts its pass so that the replay
  /// reproduces them.
  final _adopted = <int, (String?, bool)>{};

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

  /// How long a pass sent to the [worker] may go unanswered before the
  /// painter places in-frame instead. A pass takes the worker a few
  /// milliseconds; this only catches one that is not coming.
  static const Duration _maxPassWait = Duration(seconds: 1);

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
  /// not drawn on a frame (`fit`, `angle`, `collision`, `repeat`, and the
  /// `ghost:*` reasons of a fade-out), and whether that frame was a
  /// replay. `ghost:none` has no candidate left to name, so it reports
  /// the label id instead. For the bench; null otherwise.
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

  /// Per-label fade state — one opacity per label id, advanced every
  /// painted frame. See [LabelFadeTracker].
  final _fades = LabelFadeTracker();

  /// The fade tracker, for tests that assert fade state across frames.
  @visibleForTesting
  LabelFadeTracker get debugFades => _fades;

  /// Fallback drawables for the fade-out: per tracked label id, one
  /// unplaced copy on offer this frame — the copy the label was last
  /// drawn from when it is still offered ([_drawnCopy]), else the first.
  /// Copies of one id can sit up to the identity match radius apart, so
  /// a ghost that switched copies would move.
  final _fallbacks = <int, PlacedSymbol>{};

  /// When the collision pass re-runs; between passes its decision is
  /// replayed. See [PlacementThrottle].
  final _placement = PlacementThrottle();

  /// The label ids that won space at the last full pass — the frozen
  /// decision itself. Between passes only their copies compete
  /// (everything else is skipped before it is even laid out), and at the
  /// next pass they are the incumbents. Ids outlive instances, so a
  /// winner whose tile republished is still a winner in its successor.
  final _winners = <int>{};

  /// Which copy of each label the last frame drew, placed or as a ghost.
  /// One label can be on offer as several copies (seam twins, the two
  /// levels' at a crossing), up to the identity match radius apart and
  /// with geometry of their own, so the copy is part of the decision: a
  /// replay draws this one, a pass tries it ahead of the label's other
  /// copies, and a ghost is drawn from it — as long as it is still on
  /// offer. Without it a replay redrew whichever copy sorted first,
  /// which could be the one the pass had rejected.
  var _drawnCopy = <int, SymbolInstance>{};

  /// [_drawnCopy] for the frame being painted; also how a frame knows a
  /// label already drew. Swapped in at the end of the frame.
  var _drawing = <int, SymbolInstance>{};

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
  bool get placementPending =>
      _placement.deferred || _inFlight != null || _arrived != null;

  /// Forgets all fade and placement state — for theme/provider swaps,
  /// where every symbol instance is replaced and layer indices change
  /// meaning.
  void reset() {
    _fades.clear();
    _fallbacks.clear();
    _winners.clear();
    _drawnCopy.clear();
    _drawing.clear();
    _memory.clear();
    _placement.reset();
    dropPendingPass();
  }

  /// Forgets a pass sent to the [worker] and not adopted yet — for a
  /// worker that was handed a new theme or sprite sheet, which answers
  /// nothing asked before. The next due pass asks again.
  void dropPendingPass() {
    if (_inFlight != null || _arrived != null) _placement.reset();
    _inFlight = null;
    _arrived = null;
    _adopted.clear();
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
    List<LabelCohortInput>? cohorts,
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
          cohorts,
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
    List<LabelCohortInput>? cohorts,
    DateTime now,
  ) {
    _disposeRetired();
    _frames++;
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
    //
    // With a placement worker, no frame decides: a due pass is sent to
    // the worker, and the frame its answer arrives by adopts it — a
    // replay of the new decision, with the authority of a pass (it may
    // start fade-outs). Fades off place every frame, which the worker
    // could only answer frames late; those stay in-frame.
    final worker = this.worker;
    // A pass the worker has not answered in [_maxPassWait] is given up
    // (a stepped clock, too, makes the wait unmeasurable), and this frame
    // places in-frame rather than leave the decision frozen.
    final inFlight = _inFlight;
    final stalled = inFlight != null &&
        _arrived == null &&
        (now.difference(inFlight.sentAt) > _maxPassWait ||
            now.isBefore(inFlight.sentAt));
    if (stalled) dropPendingPass();
    final offload =
        worker != null && worker.ready && fades && cohorts != null && !stalled;
    var placing = false;
    var adopting = false;
    if (offload) {
      final arrived = _arrived;
      if (arrived != null) adopting = _adopt(arrived);
      if (_inFlight == null &&
          _placement.shouldPlace(
            now: now,
            interval: placementInterval(labelFadeDuration),
            generation: placementGeneration,
            screenSize: screenSize,
          )) {
        _request(worker, cohorts, screenSize, styleZoom, now);
      }
    } else {
      // A worker that stopped answering (or fades just turned off)
      // leaves nothing pending behind it.
      _inFlight = null;
      _arrived = null;
      placing = _placement.shouldPlace(
        now: now,
        interval: placementInterval(labelFadeDuration),
        generation: placementGeneration,
        screenSize: screenSize,
      );
    }
    final pass = placing || adopting;
    if (pass) _pass++;
    _memory.beginFrame(prune: pass);
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
      _flagIncumbents(symbols);
      candidates = symbols..sort(_byPlacementPriority);
      _promoteDrawnCopies(candidates);
    } else {
      // Replaying: the frozen decision says only the last pass's
      // winners are on screen, so only they are laid out — each from the
      // copy it was drawn from, or, where that copy is gone (its tile
      // republished), from its other copies — and only they need
      // sorting, ~100 of a few thousand candidates on a dense screen.
      // [_byPlacementPriority] is a total order (`order` is unique), so
      // their relative order is exactly what a full sort gives. Everyone
      // else is at most a fade-out fallback, recorded in input order
      // instead of priority order.
      candidates = <PlacedSymbol>[];
      List<PlacedSymbol>? otherCopies;
      Set<int>? drawnCopyOffered;
      for (final candidate in symbols) {
        if (!candidate.ghostOnly && _winners.contains(candidate.id)) {
          if (identical(_drawnCopy[candidate.id], candidate.instance)) {
            candidates.add(candidate);
            (drawnCopyOffered ??= {}).add(candidate.id);
          } else {
            (otherCopies ??= []).add(candidate);
          }
        } else if (fades) {
          _recordFallback(candidate);
        }
      }
      if (otherCopies != null) {
        for (final candidate in otherCopies) {
          if (drawnCopyOffered?.contains(candidate.id) ?? false) {
            if (fades) _recordFallback(candidate);
          } else {
            candidates.add(candidate);
          }
        }
      }
      candidates.sort(_byPlacementPriority);
    }
    debugSortMicros += sortStopwatch.elapsedMicroseconds;
    if (placing) debugPlacingFrames++;

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
        // label is fading out and nothing else can draw it. (A replay
        // frame recorded these while picking its winners.)
        if (fades) _recordFallback(candidate);
        continue;
      }
      // Another copy of this label — a seam twin, the other level's at
      // a crossing — already drew: one label draws once. Skipped before
      // any layout work.
      if (_drawing.containsKey(candidate.id)) continue;
      if (adopting) {
        final choice = _adopted[candidate.id];
        if (choice != null) {
          final sitting = _memory.sitting(candidate.id);
          if (choice.$1 != null) sitting.anchor = choice.$1;
          sitting.textDropped = choice.$2;
        }
      }
      final drawable =
          _prepare(candidate, zoom, styleZoom, collision, sprites, screenSize);
      if (drawable == null) {
        // A candidate that lost (collision, zoom gate) may still be the
        // only copy around of a label mid-fade-out.
        if (fades) _recordFallback(candidate);
        continue;
      }
      _drawing[candidate.id] = candidate.instance;
      if (placing) _winners.add(candidate.id);
      // The label's fade and its layer's zoom-range ramp compound: a
      // label appearing near its layer's maxzoom is subject to both.
      final ramp = zoomRangeOpacity(candidate.instance.layer, styleZoom);
      if (placing) {
        final repeatKey = drawable.repeatKey;
        // Only text that actually shows may suppress a repeat: a
        // rejected or ramped-out candidate never hides a fallback.
        if (repeatKey != null && drawable.drawsText && ramp > 0) {
          (_repeatAnchors[repeatKey] ??= []).add(_RepeatAnchor(candidate));
        }
      }
      var fade = 1.0;
      if (fades) {
        // One fade per label id: every copy of a label resumes its
        // state, while two POIs sharing a name, or a street name whose
        // anchor the next level re-spaced, are different labels and
        // fade on their own.
        fade = _fades.show(candidate.id);
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
      // Labels placed until recently but not this frame fade out,
      // drawing one ghost each: laid out (the zoom gate bypassed — a
      // departing label is often departing *because* the gate just cut
      // its layer) but claiming no collision space, so whatever takes
      // the spot fades in over the ghost instead of waiting for it to
      // expire and popping.
      _CollisionIndex? permissive;
      _fades.sweep((id, opacity) {
        final fallback = _fallbacks[id];
        if (fallback == null) {
          debugRejectProbe?.call(id, 'ghost:none', true);
          return;
        }
        final key = fallback.instance.continuityKey;
        final ramp = zoomRangeOpacity(fallback.instance.layer, styleZoom);
        if (ramp <= 0) {
          debugRejectProbe?.call(key, 'ghost:ramp', true);
          return;
        }
        // Floored, mirroring the fade-in's implicit ceil: a departing
        // label reaches zero instead of lingering one step above it.
        final ghostOpacity =
            (opacity * ramp * _opacitySteps).floor() / _opacitySteps;
        if (ghostOpacity <= 0) return;
        final drawable = _prepare(fallback, zoom, styleZoom,
            permissive ??= _CollisionIndex.permissive(), sprites, screenSize,
            gateZoom: false);
        if (drawable == null) {
          debugRejectProbe?.call(key, 'ghost:prepare', true);
          return;
        }
        drawable.opacity = ghostOpacity;
        drawable.isGhost = true;
        toDraw.add(drawable);
        anyFading = true;
        _drawing[id] = fallback.instance;
      },
          // Replay frames hold: a winner missing mid-interval may only
          // be between copies (its tile gone, the successor not yet
          // published), and only a pass may start a fade-out.
          hold: !pass);
      _fallbacks.clear();
    }
    final drawnCopy = _drawnCopy;
    _drawnCopy = _drawing;
    _drawing = drawnCopy..clear();
    _adopted.clear();
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
              id: drawable.symbol.id,
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
            // One tile, one layout: every candidate is its own label,
            // and nothing carries over to another call to need more.
            id: i + 1,
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

  /// Mirrors [symbols] into the placement worker ahead of the first pass
  /// that offers them. The layer calls this as a tile publishes, inside
  /// the render pump's budget, so that a pass request finds every list
  /// already there instead of packing it inside a frame.
  void mirror(List<SymbolInstance> symbols) {
    final worker = this.worker;
    if (worker == null || !worker.ready || symbols.isEmpty) return;
    worker.mirror(symbols, () => mirrorOf(symbols));
  }

  /// Sends the pass due this frame to [worker]: the cohorts on offer
  /// (mirroring any list it does not hold yet) and the fade sittings it
  /// recognises incumbents by. The frame itself replays the decision in
  /// force; [_adopt] takes the answer on a later one.
  void _request(LabelPlacementWorker worker, List<LabelCohortInput> cohorts,
      Size screenSize, double styleZoom, DateTime now) {
    final stopwatch = Stopwatch()..start();
    final mirroring = LabelPlacementWorker.debugMirrorMicros;
    final sent = <LabelCohort>[];
    final offered = <LabelCohortInput>[];
    final drawnCopies = <int>[];
    for (final cohort in cohorts) {
      if (cohort.ghostOnly || cohort.symbols.isEmpty) continue;
      final symbols = cohort.symbols;
      final transform = cohort.transform;
      offered.add(cohort);
      if (_drawnCopy.isNotEmpty) {
        for (var i = 0; i < symbols.length; i++) {
          if (identical(_drawnCopy[cohort.ids[i]], symbols[i])) {
            drawnCopies.add(cohort.order + i);
          }
        }
      }
      sent.add((
        mirror: worker.mirror(symbols, () => mirrorOf(symbols)),
        ids: cohort.ids,
        originX: transform.origin.dx,
        originY: transform.origin.dy,
        scale: transform.scale,
        rotation: transform.rotation,
        retained: cohort.retained,
        order: cohort.order,
      ));
    }
    final id = ++_requests;
    _inFlight = _PassInFlight(id, offered, _frames, now);
    worker.place((
      id: id,
      width: screenSize.width,
      height: screenSize.height,
      styleZoom: styleZoom,
      cohorts: sent,
      incumbents: Int32List.fromList(_winners.toList()),
      drawnCopies: Int32List.fromList(drawnCopies),
    ), (result) {
      if (_inFlight?.id == result.id) _arrived = result;
    });
    LabelPlacementWorker.debugRequests++;
    LabelPlacementWorker.debugRequestMicros += stopwatch.elapsedMicroseconds -
        (LabelPlacementWorker.debugMirrorMicros - mirroring);
  }

  /// Takes the worker's answer as the decision in force: its winners —
  /// label ids, so a winner whose tile republished since the request is
  /// still a winner in its successor — and their choices, for this
  /// frame's replay to reproduce. False when the answer is not to the
  /// request in flight.
  bool _adopt(LabelPassResult result) {
    _arrived = null;
    final request = _inFlight;
    _inFlight = null;
    if (request == null || request.id != result.id) return false;
    _winners.clear();
    _adopted.clear();
    final winners = result.winners;
    for (var w = 0; w < winners.length; w++) {
      final id = winners[w];
      _winners.add(id);
      _adopted[id] = (result.anchors[w], result.textDropped[w] == 1);
      // The copy the worker placed is the one to replay: another copy of
      // the label may be the one the pass rejected.
      final copy = request.copyAt(result.copies[w]);
      if (copy != null) _drawnCopy[id] = copy;
    }
    LabelPlacementWorker.debugCommits++;
    LabelPlacementWorker.debugCommitLatencyFrames += _frames - request.frame;
    LabelPlacementWorker.debugWorkerMicros += result.micros;
    return true;
  }

  /// [symbols] packed for a placement worker ([LabelMirror]), with the
  /// metrics of the text this painter shaped for them — [prewarm] has
  /// by the time a tile publishes: each label's extent, and the
  /// clusters of the ones that may curve. A label whose text was never
  /// shaped (its layer's opacity or size gated it out at the tile's
  /// zoom) goes without, and the worker places only its icon.
  @internal
  LabelMirror mirrorOf(List<SymbolInstance> symbols) {
    final count = symbols.length;
    final ints = Int32List(count * LabelMirror.intsPerSymbol);
    final reals = Float64List(count * LabelMirror.realsPerSymbol);
    final texts = <String>[];
    final icons = <String?>[];
    final clusters = <Float32List?>[];
    final paths = Map<SymbolPath, int>.identity();
    final pathPoints = <Float32List>[];
    final pathCumulative = <Float32List>[];
    // Features by properties map (identity — `Map` keeps `Object.==`),
    // geometry type and id: a feature's symbols share all three.
    final features = <(Map<String, Object?>, String, Object?), int>{};
    final properties = <Map<String, Object?>>[];
    final geometryTypes = <String>[];
    final featureIds = <Object?>[];
    for (var i = 0; i < count; i++) {
      final symbol = symbols[i];
      final path = symbol.path;
      final pathIndex = path == null
          ? -1
          : paths.putIfAbsent(path, () {
              pathPoints.add(path.points);
              pathCumulative.add(path.cumulative);
              return pathPoints.length - 1;
            });
      final feature = features.putIfAbsent(
          (symbol.properties, symbol.geometryType, symbol.featureId), () {
        properties.add(symbol.properties);
        geometryTypes.add(symbol.geometryType);
        featureIds.add(symbol.featureId);
        return properties.length - 1;
      });
      final o = i * LabelMirror.intsPerSymbol;
      ints[o] = symbol.layerIndex;
      ints[o + 1] = symbol.alongLine ? LabelMirror.flagAlongLine : 0;
      ints[o + 2] = pathIndex;
      ints[o + 3] = feature;
      var width = -1.0;
      var height = -1.0;
      Float32List? glyphs;
      final memo = symbol.textStyleMemo;
      final text = memo == null || symbol.text.isEmpty
          ? null
          : _textCache.peek(memo.cacheKey);
      if (text != null) {
        width = text.size.width;
        height = text.size.height;
        if (symbol.alongLine && symbol.curveSafe && path != null) {
          final shaped = text.clusters;
          glyphs = Float32List(shaped.length * 2);
          for (var c = 0; c < shaped.length; c++) {
            glyphs[c * 2] = shaped[c].center;
            glyphs[c * 2 + 1] = shaped[c].width;
          }
        }
      }
      final r = i * LabelMirror.realsPerSymbol;
      reals[r] = symbol.anchor.dx;
      reals[r + 1] = symbol.anchor.dy;
      reals[r + 2] = symbol.angle;
      reals[r + 3] = symbol.pathDistance;
      reals[r + 4] = symbol.sortKey;
      reals[r + 5] = width;
      reals[r + 6] = height;
      texts.add(symbol.text);
      icons.add(symbol.iconName);
      clusters.add(glyphs);
    }
    return LabelMirror(
      ints: ints,
      reals: reals,
      texts: texts,
      icons: icons,
      clusters: clusters,
      pathPoints: pathPoints,
      pathCumulative: pathCumulative,
      properties: properties,
      geometryTypes: geometryTypes,
      featureIds: featureIds,
    );
  }

  /// A worker's side of [mirrorOf]: the instances again, on [theme] —
  /// the worker's copy of the UI's — with their mirrored metrics standing
  /// in for shaped text. An entry whose layer [theme] does not have as a
  /// symbol layer (a mirror racing a theme swap) is null, so indices
  /// still match the UI's list.
  @internal
  List<SymbolInstance?> adoptMirror(LabelMirror mirror, Theme theme) {
    final measured = _measured!;
    final paths = [
      for (var p = 0; p < mirror.pathPoints.length; p++)
        SymbolPath(mirror.pathPoints[p], mirror.pathCumulative[p]),
    ];
    final ints = mirror.ints;
    final reals = mirror.reals;
    return [
      for (var i = 0; i < mirror.length; i++)
        () {
          final o = i * LabelMirror.intsPerSymbol;
          final r = i * LabelMirror.realsPerSymbol;
          final layerIndex = ints[o];
          final layer = layerIndex < theme.layers.length
              ? theme.layers[layerIndex]
              : null;
          if (layer is! SymbolThemeLayer) return null;
          final feature = ints[o + 3];
          final pathIndex = ints[o + 2];
          final instance = SymbolInstance(
            layer: layer,
            layerIndex: layerIndex,
            anchor: Offset(reals[r], reals[r + 1]),
            angle: reals[r + 2],
            alongLine: ints[o + 1] & LabelMirror.flagAlongLine != 0,
            path: pathIndex < 0 ? null : paths[pathIndex],
            pathDistance: reals[r + 3],
            text: mirror.texts[i],
            iconName: mirror.icons[i],
            sortKey: reals[r + 4],
            properties: mirror.properties[feature],
            geometryType: mirror.geometryTypes[feature],
            featureId: mirror.featureIds[feature],
          );
          final width = reals[r + 5];
          if (width >= 0) {
            final glyphs = mirror.clusters[i];
            measured[instance] = _MeasuredText(Size(width, reals[r + 6]), [
              if (glyphs != null)
                for (var c = 0; c < glyphs.length ~/ 2; c++)
                  _Cluster('', glyphs[c * 2], glyphs[c * 2 + 1]),
            ]);
          }
          return instance;
        }(),
    ];
  }

  /// A worker's theme install: the sprites it places icons by, and none
  /// of the previous theme's placement state.
  @internal
  void installWorker(Map<String, Sprite>? sprites) {
    _workerSprites = sprites;
    reset();
  }

  /// A placement worker's pass: decides which of [symbols] win space on
  /// a [screenSize] screen at [styleZoom] exactly as a placing frame of
  /// [paint] does — same priority, incumbents, one copy per label (the
  /// one last drawn tried first), repeat suppression and placement
  /// memory — and returns the winners in placement order. Nothing is
  /// drawn and no fade runs. [incumbents] is the decision in force on
  /// the UI, whose labels a same-layer newcomer must not evict, and
  /// [drawnCopies] the [PlacedSymbol.order]s of the copies it drew.
  @internal
  List<PlacedSymbol> placeForWorker({
    required Size screenSize,
    required double styleZoom,
    required List<PlacedSymbol> symbols,
    required Iterable<int> incumbents,
    Iterable<int> drawnCopies = const [],
  }) {
    _pass++;
    _memory.beginFrame(prune: true);
    final zoom = (styleZoom * _zoomStep).round() / _zoomStep;
    final collision = _CollisionIndex(screenSize);
    _winners
      ..clear()
      ..addAll(incumbents);
    _drawnCopy.clear();
    final drawn = drawnCopies.toSet();
    if (drawn.isNotEmpty) {
      for (final candidate in symbols) {
        if (drawn.contains(candidate.order)) {
          _drawnCopy[candidate.id] = candidate.instance;
        }
      }
    }
    _flagIncumbents(symbols);
    symbols.sort(_byPlacementPriority);
    _promoteDrawnCopies(symbols);
    _winners.clear();
    _repeatAnchors.clear();
    final placed = <PlacedSymbol>[];
    for (final candidate in symbols) {
      if (candidate.ghostOnly || _winners.contains(candidate.id)) continue;
      final drawable =
          _prepare(candidate, zoom, styleZoom, collision, null, screenSize);
      if (drawable == null) continue;
      _winners.add(candidate.id);
      final repeatKey = drawable.repeatKey;
      if (repeatKey != null &&
          drawable.drawsText &&
          zoomRangeOpacity(candidate.instance.layer, styleZoom) > 0) {
        (_repeatAnchors[repeatKey] ??= []).add(_RepeatAnchor(candidate));
      }
      placed.add(candidate);
    }
    return placed;
  }

  /// The choices [winner] was placed with at the last [placeForWorker].
  @internal
  ({String? anchor, bool textDropped}) decisionOf(PlacedSymbol winner) {
    final sitting = _memory.lookup(winner.id);
    return (
      anchor: sitting?.anchor,
      textDropped: sitting?.textDropped ?? false
    );
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

  /// Marks the candidates whose label is steadily visible on screen —
  /// the last pass's winners — so the priority sort tries them ahead of
  /// same-layer newcomers; see [PlacedSymbol.incumbent]. Placing frames
  /// only; the flag defaults to false on every rebuilt candidate list in
  /// between.
  ///
  /// By label id, so incumbency survives the instance replacement every
  /// republish and level swap performs, precisely when it matters most.
  /// It also settles which of a label's *own* rivals draws: a street
  /// name repeated on the parallel carriageway is another label of the
  /// same name, and since only the one on screen is an incumbent, a slow
  /// pan that reorders their screen y no longer walks the name across
  /// the street.
  void _flagIncumbents(List<PlacedSymbol> candidates) {
    for (final candidate in candidates) {
      candidate.incumbent =
          !candidate.ghostOnly && _winners.contains(candidate.id);
    }
  }

  /// Moves the copy each label was last drawn from ahead of the label's
  /// other copies, in place, so a pass keeps a label on the copy it is
  /// on for as long as that copy still fits: which copy sorts first
  /// depends on their screen y, and rotating the map reorders two copies
  /// a few pixels apart.
  ///
  /// Only the order *inside* one label id changes: the label still
  /// competes for space at the position its best copy earned, so this
  /// can never let one label outrank another.
  void _promoteDrawnCopies(List<PlacedSymbol> candidates) {
    if (_drawnCopy.isEmpty) return;
    Map<int, int>? firstCopy;
    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      if (candidate.ghostOnly) continue;
      final drawn = _drawnCopy[candidate.id];
      if (drawn == null) continue;
      if (!identical(drawn, candidate.instance)) {
        (firstCopy ??= {})[candidate.id] ??= i;
        continue;
      }
      final first = firstCopy?.remove(candidate.id);
      if (first == null) continue; // already first among its copies
      candidates[i] = candidates[first];
      candidates[first] = candidate;
    }
  }

  /// Remembers [candidate] as the drawable to fade its label out with,
  /// should the sweep find that label unplaced this frame — the copy it
  /// was last drawn from if that is on offer, else the first one seen.
  /// Only tracked labels can fade.
  void _recordFallback(PlacedSymbol candidate) {
    final id = candidate.id;
    if (!_fades.isTracked(id)) return;
    if (identical(_drawnCopy[id], candidate.instance)) {
      _fallbacks[id] = candidate;
    } else {
      _fallbacks.putIfAbsent(id, () => candidate);
    }
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

    // What this label decided last time it was placed — by label id, so
    // the instance that arrives with a new zoom level inherits what the
    // one it replaces was sitting on.
    final sitting = _memory.sitting(placed.id);

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
    _TextShape? text;
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
        text = _measured == null
            ? _layoutText(instance, layer, ctx, fontSize)
            : _measured[instance];
      }
    }

    _DrawableIcon? icon;
    final iconName = instance.iconName;
    final spriteIndex = sprites?.sprites ?? _workerSprites;
    if (iconName != null && spriteIndex != null) {
      final sprite = spriteIndex[iconName];
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
          // `auto` follows the line when the symbol sits on one, else the
          // viewport — matching `text-rotation-alignment`'s default.
          // Explicit `map` alignment always includes the map bearing;
          // for an along-line symbol [screenAngle] also includes the
          // line's local bearing.
          final alignment = layer.iconRotationAlignment.eval(ctx);
          final followsMap =
              alignment == 'map' || (alignment == 'auto' && instance.alongLine);
          final rotateRad = layer.iconRotate.eval(ctx) * math.pi / 180;
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
            pivot: anchor,
            rotation: followsMap ? placed.screenAngle + rotateRad : rotateRad,
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
              icon, collision, sitting)
            ?..repeatKey = repeatKey;
        }
        lineTextAngle = _uprightAngle(sitting, placed.screenAngle);
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
      boxes.add(icon.bounds.inflate(2));
    }

    final allowOverlap = text != null
        ? layer.textAllowOverlap.eval(ctx)
        : layer.iconAllowOverlap.eval(ctx);
    if (allowOverlap ? !collision.fits(boxes) : !collision.tryPlaceAll(boxes)) {
      debugRejectProbe?.call(placed.instance.continuityKey, 'collision', false);
      // Icon may still be placed when text is optional.
      if (icon != null &&
          text != null &&
          layer.textOptional.eval(ctx) &&
          collision.tryPlaceAll([icon.bounds.inflate(2)])) {
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
    )..repeatKey = repeatKey;
  }

  /// Whether [placed]'s label fits on its line: the longer of its text
  /// and its icon, centred on the anchor, within the line's ends.
  /// MapLibre's anchor test, with the label measured on screen and the
  /// line in tile-logical units, which [PlacedSymbol.transform] relates.
  static bool _fitsLine(PlacedSymbol placed, _TextShape? text, double textScale,
      _DrawableIcon? icon) {
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
    _TextShape text,
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
        if (icon != null) icon.bounds.inflate(2),
      ];
      if (allowOverlap ? collision.fits(boxes) : collision.tryPlaceAll(boxes)) {
        sitting.anchor = anchorName;
        return _DrawableSymbol(placed,
            icon: icon, text: text, textRect: textRect, textScale: textScale);
      }
    }
    if (icon != null &&
        layer.textOptional.eval(ctx) &&
        collision.tryPlaceAll([icon.bounds.inflate(2)])) {
      sitting.textDropped = true;
      return _DrawableSymbol(placed, icon: icon);
    }
    debugRejectProbe?.call(placed.instance.continuityKey, 'collision', false);
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
    _TextShape text,
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
          collision.tryPlaceAll([icon.bounds.inflate(2)])) {
        sitting.textDropped = true;
        return _DrawableSymbol(placed, icon: icon);
      }
      return null;
    }

    // What a replay or a ghost draws for a label it cannot curve: the
    // text straight along its anchor's bearing, until the next pass
    // decides. Both reproduce a label a pass accepted, and dropping it
    // instead left the sitting with nothing drawable — a street name
    // vanishing at full opacity, ghost and all.
    _DrawableSymbol straightAtAnchor() {
      final textRect = Rect.fromCenter(
          center: placed.screenAnchor,
          width: text.size.width * textScale,
          height: text.size.height * textScale);
      return _DrawableSymbol(placed,
          icon: icon,
          text: text,
          textRect: textRect,
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
      return iconFallback();
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
        return iconFallback();
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
        return iconFallback();
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
        if (icon != null) icon.bounds.inflate(2),
      ];
      if (allowOverlap
          ? !collision.fits(boxes)
          : !collision.tryPlaceAll(boxes)) {
        debugRejectProbe?.call(
            placed.instance.continuityKey, 'collision', false);
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
      if (icon != null) icon.bounds.inflate(2),
    ];
    if (allowOverlap ? !collision.fits(boxes) : !collision.tryPlaceAll(boxes)) {
      debugRejectProbe?.call(placed.instance.continuityKey, 'collision', false);
      return iconFallback();
    }

    final glyphs = [
      for (final p in placements)
        _CurvedGlyph(
          // A worker only measures: there are no painters to draw with.
          painters:
              text is _LaidOutText ? _glyphPainters(p.grapheme, text) : null,
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
  ) =>
      _lookupText(instance, layer, ctx, fontSize)..pass = _pass;

  _LaidOutText _lookupText(
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
    var maxWidth = singleLine
        ? double.infinity
        : math.max(_shapeSize * memo.maxWidthEm, _shapeSize * 2);
    final style = _textStyle(
        memo.fonts, _shapeSize, memo.letterSpacingEm, Color(memo.fillArgb));
    var text = instance.text;
    // Laid out unconstrained first: that is the one layout after which
    // the min intrinsic width is the paragraph's widest unbreakable run.
    // After a constrained layout that broke a word, Skia reports a
    // width that depends on where it broke, often less than the word.
    final fill = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
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
        text: TextSpan(text: text, style: haloStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
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
    );
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
        final painters = glyph.painters!;
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
    // Room for the halo stroke, which straddles the outline, and for
    // glyph overhang past the advance box.
    final stroke = text.haloStyle?.foreground?.strokeWidth ?? 0;
    final glyph =
        _GlyphText(key: key, fill: fill, halo: halo, pad: 2 + stroke / 2)
          ..pass = _pass;
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

/// A pass request the worker has not answered yet, with what it offered
/// and the frame and time it was sent in.
class _PassInFlight {
  final int id;

  /// The cohorts the request offered, in order: the answer names each
  /// winner's copy by its [PlacedSymbol.order] among them.
  final List<LabelCohortInput> cohorts;
  final int frame;
  final DateTime sentAt;

  _PassInFlight(this.id, this.cohorts, this.frame, this.sentAt);

  /// The instance at [order] among [cohorts], or null.
  SymbolInstance? copyAt(int order) {
    for (final cohort in cohorts) {
      final index = order - cohort.order;
      if (index >= 0 && index < cohort.symbols.length) {
        return cohort.symbols[index];
      }
    }
    return null;
  }
}

/// What placement reads of a label's text: its extent and its grapheme
/// clusters, at [LabelPainter._shapeSize]. Every metric is in
/// reference-size units and is scaled by the evaluated
/// `text-size / _shapeSize` at use sites.
///
/// [_LaidOutText] is the shaped text the screen pass draws; a placement
/// worker, which cannot shape (text layout is root-isolate only), places
/// [_MeasuredText] — the same metrics, copied from the UI's shaping.
abstract class _TextShape {
  Size get size;
  List<_Cluster> get clusters;
}

/// Metrics-only text, mirrored into a placement worker. Its clusters
/// carry no grapheme: the worker only measures with them.
class _MeasuredText implements _TextShape {
  @override
  final Size size;
  @override
  final List<_Cluster> clusters;

  _MeasuredText(this.size, this.clusters);
}

/// Text shaped at [LabelPainter._shapeSize]; see [_TextShape].
class _LaidOutText implements _TextShape {
  final String text;
  final TextPainter fill;
  final TextPainter? halo;
  @override
  final Size size;
  final String styleKey;
  final TextStyle fillStyle;
  final TextStyle? haloStyle;

  /// The label pass that last used this text — see
  /// [LabelPainter.trimCaches].
  int pass = 0;

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
  @override
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
  /// Null in a placement worker, which never draws.
  final _GlyphText? painters;
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

  /// Null in a placement worker, which never draws.
  final SpriteAtlas? atlas;
  final Sprite sprite;
  final Rect rect;
  final double opacity;

  /// `icon-color`, for SDF sprites only; null draws the sprite as-is.
  final Color? tint;
  final Color? haloColor;
  final double haloWidth;

  /// `icon-size`, which `icon-halo-width` is measured relative to.
  final double iconSize;

  /// Screen-space symbol anchor. Rotation includes [rect]'s anchor and
  /// offset, so both move around this point with the icon.
  final Offset pivot;

  /// Radians, clockwise: `icon-rotate` plus the line/map angle
  /// `icon-rotation-alignment` resolved to. Rotates about [pivot], so
  /// `icon-anchor` and `icon-offset` turn with the sprite.
  final double rotation;

  _DrawableIcon({
    required this.atlas,
    required this.sprite,
    required this.rect,
    required this.opacity,
    this.tint,
    this.haloColor,
    this.haloWidth = 0,
    this.iconSize = 1,
    required this.pivot,
    this.rotation = 0,
  });

  /// Screen extent of the (rotated) sprite. Read once per collision
  /// box, fallback attempt, variable anchor tried and fade layer, so
  /// the rotation maths runs once rather than per read.
  late final Rect bounds =
      rotation == 0 ? rect : LabelPainter._rotatedBounds(rect, pivot, rotation);

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
    final atlas = this.atlas!;
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
  final _TextShape? text;
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

  /// The [LabelPainter._repeatAnchors] key this symbol's text registers
  /// under once it is drawn, or null when repeat suppression does not
  /// apply to it. Assigned by [LabelPainter._prepare] like [opacity].
  Object? repeatKey;

  /// Atlas sprite batches for [curvedGlyphs], halos first; null when the
  /// glyphs draw as paragraphs. Assigned by
  /// [LabelPainter._prepareAtlasGlyphs] before drawing.
  List<_SpriteBatch>? atlasSprites;

  static final _atlasPaint = Paint()..filterQuality = FilterQuality.low;

  bool get drawsText => text != null || curvedGlyphs != null;

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
    if (icon != null) add(icon.bounds);
    final glyphs = curvedGlyphs;
    final text = this.text;
    if (glyphs != null) {
      for (final glyph in glyphs) {
        final painters = glyph.painters!;
        final painter = painters.halo ?? painters.fill;
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
          final painters = glyph.painters!;
          final painter = pass == 0 ? painters.halo : painters.fill;
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
    final t = text as _LaidOutText?;
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
      // Scaled about the centre: the snapped scale may differ from the
      // one [textRect] was sized with by a fraction of a pixel, and
      // that difference must not shift the label off its box.
      canvas.save();
      canvas.translate(textRect.center.dx, textRect.center.dy);
      canvas.scale(textScale);
      final topLeft = Offset(-t.size.width / 2, -t.size.height / 2);
      t.halo?.paint(canvas, topLeft);
      t.fill.paint(canvas, topLeft);
      canvas.restore();
    } else {
      t.halo?.paint(canvas, textRect.topLeft);
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

/// Grid-bucketed screen-space collision index.
class _CollisionIndex {
  static const double _cellSize = 128;
  final Map<int, List<Rect>> _cells = {};
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
  /// `*-allow-overlap` symbols, which skip [tryPlaceAll], still face.
  bool fits(List<Rect> rects) {
    final bounds = this.bounds;
    if (bounds == null) return true;
    for (final rect in rects) {
      if (rect.left < bounds.left ||
          rect.top < bounds.top ||
          rect.right > bounds.right ||
          rect.bottom > bounds.bottom) {
        return false;
      }
    }
    return true;
  }

  /// Whether [rects] fit, reserving them when they do.
  bool tryPlaceAll(List<Rect> rects) {
    if (_permissive) return true;
    if (!fits(rects)) return false;
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
