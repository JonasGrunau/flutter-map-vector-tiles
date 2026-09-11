import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'symbol_layouter.dart';

/// Identity of a label for cross-zoom continuity: the same text (or the
/// same icon) on the same style layer.
///
/// Deliberately position-free. Geometry simplification differs per zoom
/// level, so the same feature's anchor lands a fraction of a pixel apart
/// at two levels and a position-sensitive *key* would miss the match —
/// and a missed match re-fades a label that is already on screen, the
/// blink this whole mechanism exists to prevent. Position still takes
/// part, but *inside* the key: [LabelFadeTracker] keeps one fade per
/// sitting — states matched by screen position within a radius (see
/// [LabelFadeTracker.showAt]) — which tolerates that noise where an
/// exact key cannot. The split is what lets two same-named POIs, every
/// housenumber "12" and every parking icon on a layer fade
/// independently instead of sharing one opacity, and what keeps an
/// along-line label from teleporting when the next zoom level re-spaces
/// its street's anchors.
///
/// A record, not an `Object.hash` value: set membership must compare the
/// actual triple, or a hash collision between unrelated labels would
/// silently conflate them. Memoized on the instance — the label pass
/// looks it up per candidate per frame.
Object labelContinuityKey(SymbolInstance symbol) => symbol.continuityKey;

/// The subset of [symbols] that was actually on screen, per [drawn] —
/// the identity set of the symbols the last label pass drew.
///
/// A cohort is pinned to this subset the moment its level is replaced:
/// an outgoing level exists to *keep* what was visible until the new
/// level covers it, never to introduce labels. Its losing candidates
/// would otherwise pop in mid-transition the instant a zoom-range cut
/// removes whatever was suppressing them — street names flashing up
/// just before a level with sparser labelling arrives, only to be faded
/// straight back out by the new level. Returns [symbols] itself when
/// nothing is filtered out.
List<SymbolInstance> drawnLabels(
  List<SymbolInstance> symbols,
  Set<SymbolInstance> drawn,
) {
  if (symbols.isEmpty) return symbols;
  if (drawn.isEmpty) return const [];
  final result = [
    for (final symbol in symbols)
      if (drawn.contains(symbol)) symbol,
  ];
  return result.length == symbols.length ? symbols : result;
}

/// Per-label fade state, keyed by [labelContinuityKey] *and* screen
/// position: one opacity per *sitting* — a label identity at the place
/// it is on screen, whatever instance happens to draw it there.
///
/// Every frame the label pass marks the sittings it placed ([showAt]);
/// the [sweep] then walks every other tracked state downward. Opacity
/// moves toward "placed ? 1 : 0" by the fraction of a fade one frame
/// spans, so any appearance eases in and any disappearance eases out — a
/// tile arriving, a level handing over, a collision won or lost, a zoom
/// cut — all through the same mechanism, with no per-cause bookkeeping.
///
/// Three properties carry the anti-blink guarantees:
///
/// * One opacity per sitting, matched loosely. A sitting is the state
///   nearest the shown anchor within [matchRadius], so the outgoing and
///   the arriving level's copies of one label — whose anchors differ
///   only by simplification noise — resume one shared state: a crossing
///   can never cross-fade a label against itself. The *key* stays
///   position-free; position lives in the match, because an exact
///   positional key would miss on that same noise and re-fade a label
///   that never left.
/// * Position splits what position genuinely separates. Two same-named
///   POIs, every housenumber "12", every parking icon on a layer share
///   one key but sit far apart; per-sitting state lets each fade in and
///   out on its own. One state per key held every such copy at the
///   key's opacity while *any* of them was placed — so the others
///   appeared and vanished as hard pops, never fading at all. Along-line
///   labels need the same split for a different reason: their anchors
///   are re-derived from `symbol-spacing` per display layout, so the
///   arriving level's copy genuinely sits somewhere else on its street
///   and must cross-fade there instead of teleporting at full opacity.
/// * Direction changes resume, never restart. A sitting re-placed mid
///   fade-out rises from its current opacity, so a label briefly
///   unplaced — a tile republish, a lost frame of collision — dips at
///   most a step instead of blinking to zero.
///
/// The tracker is self-pruning: a state that stays unplaced fades to
/// zero and is dropped, so the map holds roughly the set of recently
/// visible labels. Pure Dart and clock-agnostic — the caller supplies
/// `now` — which is what makes it unit-testable.
class LabelFadeTracker {
  /// How far a label's anchor may move between sightings and still be
  /// the same sitting, in screen pixels. Deliberately the same value as
  /// `PlacementMemory._radius`, for the same reason: well inside the
  /// default `symbol-spacing`, so the repeats of one name along a
  /// street keep their own fades, and comfortably above the per-frame
  /// camera drift plus cross-level simplification noise.
  static const double matchRadius = 32.0;

  /// Fade states: per key, one entry per sitting position.
  final _sittings = <Object, List<_SittingFade>>{};
  var _frame = 0;
  DateTime? _lastFrameAt;

  /// Fraction of a full fade this frame advances.
  var _step = 0.0;
  var _anyActive = false;

  /// Whether the last frame left any fade mid-flight — the caller keeps
  /// scheduling frames while true.
  bool get anyActive => _anyActive;

  /// Whether [key] currently holds fade state (visible or fading out).
  bool isTracked(Object key) => _sittings.containsKey(key);

  /// The tracked opacity of the sitting of [key] nearest [position]
  /// (within [matchRadius]), or null when none is.
  double? opacityNear(Object key, Offset position) {
    final entries = _sittings[key];
    return entries == null ? null : _nearest(entries, position)?.opacity;
  }

  /// Whether [key] is steadily visible at [position] right now: a
  /// sitting within [matchRadius] at full opacity. The placement pass
  /// reads this to recognise incumbents — candidates whose label is on
  /// screen here, which a same-layer newcomer must not evict — across
  /// the instance replacement every republish and level swap brings.
  bool isVisibleAt(Object key, Offset position) {
    final entries = _sittings[key];
    if (entries == null) return false;
    return (_nearest(entries, position)?.opacity ?? 0) >= 1;
  }

  /// Starts a frame at [now]. The step is derived from the elapsed
  /// wall-clock time, so fades are frame-rate independent; a long gap
  /// (a suspended app) simply completes them.
  void beginFrame(DateTime now, Duration fadeDuration) {
    _frame++;
    final last = _lastFrameAt;
    _lastFrameAt = now;
    final span = fadeDuration.inMicroseconds;
    _step = span <= 0 || last == null
        ? 1.0
        : (now.difference(last).inMicroseconds / span).clamp(0.0, 1.0);
    _anyActive = false;
  }

  /// Marks the sitting of [key] at [position] as placed this frame and
  /// returns its opacity, risen by this frame's step.
  ///
  /// The sitting is the state nearest [position] within [matchRadius],
  /// created at 0 when none is — the caller's quantization keeps a new
  /// sitting's first frame one step above invisible. So a label whose
  /// anchor genuinely moved (the next zoom level re-spaced its street)
  /// fades in at the new position while the old one sweeps out, and a
  /// label that only drifted a few pixels resumes its state. The
  /// matched entry's position is refreshed on every sighting, which is
  /// what lets it follow the camera: between two painted frames a label
  /// moves only as far as the gesture does, always well inside the
  /// radius. Idempotent within a frame: seam twins and the retained
  /// copy of a carried-over label match one sitting and share its state.
  double showAt(Object key, Offset position) {
    final entries = _sittings[key] ??= <_SittingFade>[];
    final match = _nearest(entries, position);
    if (match == null) {
      entries.add(_SittingFade(position)..stamp = _frame);
      _anyActive = true;
      return 0;
    }
    if (match.stamp == _frame) return match.opacity;
    match.stamp = _frame;
    match.position = position;
    match.fading = false;
    if (match.opacity < 1) {
      match.opacity = math.min(1, match.opacity + _step);
      if (match.opacity < 1) _anyActive = true;
    }
    return match.opacity;
  }

  /// Advances every state *not* shown this frame toward zero, reporting
  /// the ones still visible to [fadingOut] so the caller can draw their
  /// ghosts; states that reached zero are dropped. Call once per frame,
  /// after all [show]/[showAt] calls.
  ///
  /// With [hold], a state that no pass has yet confirmed gone keeps its
  /// opacity instead of decaying — it is still reported, so its ghost
  /// keeps drawing. Replay frames pass this: only a placement pass has
  /// the authority to start a fade-out, because between passes an
  /// un-shown key usually means its instance was *replaced*, not that
  /// the label left — a tile republish or a level swap re-creates every
  /// instance, and the throttled pass picks the successor up later.
  /// Decaying through that window made a label dim and rise again at
  /// every crossing: fading into itself, the exact artefact the
  /// one-opacity-per-key design exists to prevent. A fade-out a pass
  /// *has* started keeps advancing on every frame, held or not — one
  /// step per pass would stretch a 150ms fade across minutes.
  ///
  /// [fadingOut] receives the sitting's screen position and returns
  /// where it actually drew the ghost (or null when it drew nothing) —
  /// the sitting's position is refreshed to that, so a ghost keeps
  /// tracking the camera through its fade-out and a re-appearance still
  /// matches it. [fadingOut] must not touch the tracker beyond that
  /// return value.
  void sweep(
      Offset? Function(Object key, Offset position, double opacity) fadingOut,
      {bool hold = false}) {
    _sittings.removeWhere((key, entries) {
      entries.removeWhere((entry) {
        if (entry.stamp == _frame) return false;
        if (!hold) entry.fading = true;
        if (entry.fading) entry.opacity -= _step;
        if (entry.opacity <= 0) return true;
        _anyActive = true;
        final drawnAt = fadingOut(key, entry.position, entry.opacity);
        if (drawnAt != null) entry.position = drawnAt;
        return false;
      });
      return entries.isEmpty;
    });
  }

  /// Forgets everything — for theme/provider swaps, where every symbol
  /// instance is replaced and layer indices change meaning.
  void clear() {
    _sittings.clear();
    _lastFrameAt = null;
    _anyActive = false;
  }

  static _SittingFade? _nearest(List<_SittingFade> entries, Offset position) {
    _SittingFade? best;
    var bestDistance = matchRadius * matchRadius;
    for (final entry in entries) {
      final distance = (entry.position - position).distanceSquared;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = entry;
      }
    }
    return best;
  }
}

/// One sitting's fade: its opacity, where on screen it is (so
/// [LabelFadeTracker.showAt] can match it by position), the frame it
/// was last shown in ([LabelFadeTracker.sweep] fades everything whose
/// stamp is stale), and whether a placement pass has confirmed its
/// disappearance — until one has, a held sweep keeps the opacity where
/// it is (see [LabelFadeTracker.sweep]).
class _SittingFade {
  Offset position;
  var opacity = 0.0;
  var stamp = 0;
  var fading = false;

  _SittingFade(this.position);
}

/// Decides which frames re-run the label collision pass.
///
/// Placement is deliberately *not* a per-frame decision. Label boxes
/// scale with the zoom and swing with the rotation, so a gesture drags
/// neighbouring labels through each other constantly; re-placing every
/// frame samples every one of those transients, and a label that lost a
/// spot for three frames disappears and comes straight back. That reads
/// as flicker even when both directions are faded — the collision
/// decision is simply being observed far more often than it is
/// meaningful. MapLibre re-places on a timer (once per fade duration)
/// and holds the decision frozen in between, accepting a little
/// transient overlap in exchange; this is that timer.
///
/// Between passes the caller replays the last decision: layout still
/// follows the camera every frame, only *who is shown* is frozen. A
/// changed camera or candidate set marks that decision dirty and is
/// picked up when the interval next permits a pass; a viewport resize
/// still places immediately. Repainting unchanged input never creates
/// a placement debt of its own.
class PlacementThrottle {
  DateTime? _lastPass;
  int? _placedGeneration;
  Size _screenSize = Size.zero;
  var _deferred = false;

  /// Whether the last frame deferred a pass, and one is therefore still
  /// owed. The caller keeps scheduling frames while this is true: a
  /// frozen decision was taken at an older camera, and once a gesture
  /// stops producing frames nothing else would ever re-place it.
  bool get deferred => _deferred;

  /// Whether this frame runs a full collision pass. Records the answer,
  /// so it must be called exactly once per frame.
  ///
  /// An [interval] of zero places every frame — that is what disabling
  /// the label fades asks for, since without fades a frozen decision
  /// buys nothing and every change is a hard cut anyway.
  bool shouldPlace({
    required DateTime now,
    required Duration interval,
    required int generation,
    required Size screenSize,
  }) {
    final last = _lastPass;
    final changed = generation != _placedGeneration;
    // A changed candidate set (tiles published or expired) does not jump
    // the queue: during a zoom crossing the set churns every few frames,
    // and placing on each churn is a full O(candidates) collision pass
    // per churn — on a symbol-heavy style that alone is a 10ms+
    // UI-thread spike several times a second (the label-pass numbers in
    // `bench/`). The interval is the budget for how often that cost may
    // recur; a freshly published label waits at most one interval, the
    // same duration its fade-in takes anyway, and [deferred] keeps
    // frames coming until the owed pass runs. A resize still places at
    // once — replaying decisions taken for another screen misplaces
    // everything at each frame in between.
    // Time alone is not a reason to place. In particular, the repaint
    // requested by the tick that settles a pass sees unchanged input and
    // must not create a fresh debt, or the ticker restarts forever on an
    // otherwise idle map.
    final due = last == null ||
        interval <= Duration.zero ||
        screenSize != _screenSize ||
        (changed && !now.isBefore(last.add(interval))) ||
        // A clock stepped backwards (manual change, NTP) would otherwise
        // freeze placement until it caught up again.
        now.isBefore(last);
    _deferred = changed && !due;
    if (!due) return false;
    _lastPass = now;
    _placedGeneration = generation;
    _screenSize = screenSize;
    return true;
  }

  /// Forgets the last pass, so the next frame places again.
  void reset() {
    _lastPass = null;
    _placedGeneration = null;
    _deferred = false;
  }
}

/// The placement choices a label has already made, held apart from the
/// [SymbolInstance] that made them.
///
/// Each of these is a tie-break the geometry alone does not settle, and
/// each is visible the moment it changes its mind — so what matters is
/// not which way it goes but that it keeps going that way. See
/// [PlacementMemory] for why they cannot live on the instance.
class SittingPlacement {
  /// The `text-variable-anchor` this label was last placed at, tried
  /// first at the next placement so an anchor only moves when it
  /// genuinely stops fitting. Null until the label is first placed, and
  /// never set for labels whose layer declares no variable anchors.
  String? anchor;

  /// Whether this along-line label last read *against* its line's
  /// direction. Sticky — see `LabelPainter._readsBackwards`.
  bool? flip;

  /// Whether this label's text lost its space at the last placement and
  /// only its icon was drawn (`text-optional`). Replayed between passes,
  /// where nothing competes for space and the text would otherwise flash
  /// back in for those frames.
  bool textDropped = false;

  Offset _at;
  int _seen;

  SittingPlacement._(this._at, this._seen);
}

/// Where each label's [SittingPlacement] lives: keyed by continuity key
/// *and* screen position, so a decision outlives the instance that took
/// it.
///
/// A `SymbolInstance` is built per display-tile layout, so every zoom
/// crossing, provisional→final swap and re-layout hands the painter a
/// brand-new object for a street that never left the screen. State kept
/// on the instance dies with it: the arriving copy picks its anchor and
/// its reading direction cold, and since its continuity key is unchanged
/// the fade tracker already holds it at full opacity — so the new choice
/// lands instantly, with no crossfade to cover it. That is a name
/// jumping to the other side of its street at the exact moment a zoom
/// level hands over.
///
/// Position is part of the key here, unlike [labelContinuityKey], and
/// deliberately so: the two are keys for different questions, whose
/// failure directions point opposite ways. Missing a match costs a
/// *fade* the blink it exists to prevent, so that key errs loose. For a
/// *decision*, a loose key is what does the damage — every "Hauptstraße"
/// on screen would share one side-of-the-street — while a missed match
/// merely decides cold, which is the behaviour we already have. This is
/// the useful core of MapLibre's `CrossTileSymbolIndex`, which matches
/// symbols across zoom levels by position for much the same reason; the
/// index proper exists to give MapLibre's per-tile placement an identity
/// our screen-space pass already has.
///
/// Entries are matched to the nearest sighting within [_radius] and
/// refreshed on every painted frame, so between two frames a label moves
/// only as far as the camera does. [_radius] stays well inside the
/// default `symbol-spacing`, so the repeats of one name along a single
/// street keep their own entries.
class PlacementMemory {
  /// How far a label may move between sightings and still be recognised
  /// as the same one, in logical pixels.
  static const _radius = 32.0;

  /// Frames an entry survives unseen. Passes are the slow clock here
  /// (one per fade duration, capped at 300ms), so this has to span
  /// several of them; a map that is not painting is not moving either,
  /// which is why the clock is frames rather than wall time.
  static const _maxIdleFrames = 90;

  final _entries = <Object, List<SittingPlacement>>{};
  var _frame = 0;

  /// Starts a frame. Expiry runs only on [prune] frames — the placement
  /// passes — since it walks every entry and nothing can go stale in
  /// between anyway.
  void beginFrame({required bool prune}) {
    _frame++;
    if (!prune) return;
    _entries.removeWhere((key, entries) {
      entries.removeWhere((entry) => _frame - entry._seen > _maxIdleFrames);
      return entries.isEmpty;
    });
  }

  /// The placement state for the label [key] sitting at [position],
  /// creating it on first sight. Refreshes the entry's position, so it
  /// follows the camera.
  SittingPlacement sitting(Object key, Offset position) {
    final entries = _entries[key] ??= <SittingPlacement>[];
    final match = _nearest(entries, position);
    if (match == null) {
      final entry = SittingPlacement._(position, _frame);
      entries.add(entry);
      return entry;
    }
    match._at = position;
    match._seen = _frame;
    return match;
  }

  /// The placement state remembered for [key] near [position], without
  /// creating one. For tests, and for callers that only want to know
  /// whether a label has been placed before.
  SittingPlacement? lookup(Object key, Offset position) {
    final entries = _entries[key];
    return entries == null ? null : _nearest(entries, position);
  }

  static SittingPlacement? _nearest(
      List<SittingPlacement> entries, Offset position) {
    SittingPlacement? best;
    var bestDistance = _radius * _radius;
    for (final entry in entries) {
      final distance = (entry._at - position).distanceSquared;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = entry;
      }
    }
    return best;
  }

  /// Forgets everything — for theme/provider swaps, where layer indices
  /// change meaning and no remembered choice still applies.
  void clear() => _entries.clear();
}
