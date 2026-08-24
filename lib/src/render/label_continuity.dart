import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'symbol_layouter.dart';

/// Identity of a label for cross-zoom continuity: the same text (or the
/// same icon) on the same style layer.
///
/// Deliberately position-free. Geometry simplification differs per zoom
/// level, so the same feature's anchor lands a fraction of a pixel apart
/// at two levels and a position-sensitive key would miss the match. The
/// two failure directions are not symmetric: a *missed* match re-fades a
/// label that is already on screen — the blink this whole mechanism
/// exists to prevent — while a *spurious* match only makes a genuinely
/// new label appear instantly instead of fading in, or lets a departing
/// duplicate skip its fade-out because the same text survives elsewhere
/// on the arriving level. So the key errs loose on purpose.
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

/// Per-label fade state, keyed by [labelContinuityKey]: one opacity per
/// label *identity*, whatever instance happens to draw it.
///
/// Every frame the label pass marks the keys it placed ([show]); the
/// [sweep] then walks every other tracked key downward. Opacity moves
/// toward "placed ? 1 : 0" by the fraction of a fade one frame spans,
/// so any appearance eases in and any disappearance eases out — a tile
/// arriving, a level handing over, a collision won or lost, a zoom cut
/// — all through the same mechanism, with no per-cause bookkeeping.
///
/// Two properties carry the anti-blink guarantees:
///
/// * One opacity per key. Two copies of the same label (the outgoing
///   level's and the arriving one's) can never cross-fade against each
///   other: whichever copy wins placement draws at the key's single
///   opacity. This is what stops a label "fading into itself" across a
///   zoom crossing.
/// * Direction changes resume, never restart. A key re-placed mid
///   fade-out rises from its current opacity, so a label briefly
///   unplaced — a tile republish, a lost frame of collision — dips at
///   most a step instead of blinking to zero.
///
/// The tracker is self-pruning: a key that stays unplaced fades to zero
/// and is dropped, so the map holds roughly the set of recently visible
/// labels. Pure Dart and clock-agnostic — the caller supplies `now` —
/// which is what makes it unit-testable.
class LabelFadeTracker {
  final _states = <Object, _KeyFade>{};
  var _frame = 0;
  DateTime? _lastFrameAt;

  /// Fraction of a full fade this frame advances.
  var _step = 0.0;
  var _anyActive = false;

  /// The cohort currently fading in, and the one new keys are joining.
  /// At most one cohort rises at a time, which is the whole point — see
  /// [_Cohort]. They are the same object while a wave starts on the
  /// frame it opened.
  _Cohort? _rising;
  _Cohort? _arriving;

  /// Whether the last frame left any fade mid-flight — the caller keeps
  /// scheduling frames while true.
  bool get anyActive => _anyActive;

  /// Whether [key] currently holds fade state (visible or fading out).
  bool isTracked(Object key) => _states.containsKey(key);

  /// The tracked opacity of [key], or null when untracked.
  double? opacityOf(Object key) => _states[key]?.opacity;

  /// Whether [key] is queued behind an arrival wave still in flight.
  ///
  /// Such a label is placed and holds the collision space it won, but
  /// must paint nothing until its own wave starts — the caller's
  /// first-frame opacity floor has to stand aside for it, or every
  /// queued label would show at one step instead of waiting. Distinct
  /// from an opacity of zero, which a rising key also reports on the
  /// frame it appears.
  bool isWaiting(Object key) {
    final cohort = _states[key]?.cohort;
    return cohort != null && !cohort.rising;
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

    // A wave that has started closes to new members: labels arriving
    // now are a later wave. One still waiting keeps accumulating, so
    // everything that shows up while a wave is in flight fades in
    // together when its turn comes.
    if (_arriving?.rising ?? false) _arriving = null;
    // The wave in flight lands before the next one starts, so exactly
    // one cohort is ever rising and every label fading in shares its
    // opacity. Promote first, so a cohort's first frame as the rising
    // one already carries a step.
    if (_rising == null) {
      _rising = _arriving;
      _arriving = null;
      _rising?.rising = true;
    }
    final rising = _rising;
    if (rising != null) {
      rising.opacity = math.min(1, rising.opacity + _step);
      // Landed: cleared here rather than on the next frame's check, so
      // a key arriving later this frame opens its wave immediately
      // instead of waiting out a cohort that is already done.
      if (rising.opacity >= 1) _rising = null;
    }
  }

  /// Marks [key] as placed this frame and returns its opacity, risen by
  /// this frame's step. A key new to the tracker starts at 0 — the
  /// caller's quantization keeps its first frame one step above
  /// invisible. Idempotent within a frame: seam twins and the retained
  /// copy of a carried-over label share one state.
  double show(Object key) {
    final state = _states[key];
    if (state == null) {
      // Joins the cohort that has not started rising yet, at its
      // opacity — which is always 0, so joining never pops a label
      // partway into a fade already in progress.
      final cohort = _arriving ??= _Cohort();
      if (_rising == null) {
        // Nothing in flight to queue behind: this wave starts now, so a
        // label appearing on a quiet map is never held back, and a map
        // that paints a single frame still shows its labels. [_arriving]
        // deliberately keeps pointing at it, so the rest of this frame's
        // arrivals join the same wave instead of opening their own.
        _rising = cohort;
        cohort.rising = true;
      }
      _states[key] = _KeyFade()
        ..stamp = _frame
        ..cohort = cohort;
      _anyActive = true;
      return cohort.opacity;
    }
    if (state.stamp == _frame) return state.opacity;
    state.stamp = _frame;
    final cohort = state.cohort;
    if (cohort != null) {
      state.opacity = cohort.opacity;
      // Graduated: a key at full opacity has nothing left to share, and
      // holding the reference would drag it back down if it ever needs
      // to fade out on its own.
      if (state.opacity >= 1) {
        state.cohort = null;
      } else {
        _anyActive = true;
      }
      return state.opacity;
    }
    if (state.opacity < 1) {
      state.opacity = math.min(1, state.opacity + _step);
      if (state.opacity < 1) _anyActive = true;
    }
    return state.opacity;
  }

  /// Advances every key *not* shown this frame toward zero, reporting
  /// the ones still visible to [fadingOut] so the caller can draw their
  /// ghosts; keys that reached zero are dropped. Call once per frame,
  /// after all [show] calls. [fadingOut] must not touch the tracker.
  void sweep(void Function(Object key, double opacity) fadingOut) {
    _states.removeWhere((key, state) {
      if (state.stamp == _frame) return false;
      // A key that stopped being placed decays on its own clock: it is
      // no longer arriving, so it has no business in an arrival cohort.
      state.cohort = null;
      state.opacity -= _step;
      if (state.opacity <= 0) return true;
      _anyActive = true;
      fadingOut(key, state.opacity);
      return false;
    });
  }

  /// Forgets everything — for theme/provider swaps, where every symbol
  /// instance is replaced and layer indices change meaning.
  void clear() {
    _states.clear();
    _rising = null;
    _arriving = null;
    _lastFrameAt = null;
    _anyActive = false;
  }
}

/// One arrival wave: every label that first appears while this cohort is
/// the waiting one shares its single opacity, and they fade in together.
///
/// Labels do not arrive all at once. The render pump publishes roughly
/// one tile per frame, so a zoom crossing dribbles a screen's labels in
/// over tens of frames. Fading each key from its own arrival moment puts
/// them at as many different opacities, and the painter draws each
/// distinct opacity through its own `saveLayer` — whose bounds are the
/// union of its members', which for screen-scattered POI labels is the
/// whole screen. Measured on a real crossing that peaked at seven
/// near-full-screen offscreen passes *per frame*, for the whole
/// crossing: invisible to any Dart-side timing (a `saveLayer` only
/// records an op) and squarely a raster-thread stall on a tiled mobile
/// GPU, where each one flushes the tile buffer.
///
/// Sharing one opacity per wave collapses that to a single bucket. The
/// cost is that a label arriving mid-wave waits, invisible, for the
/// current wave to land before starting its own — bounded by one fade
/// duration, and it reads as labels appearing in deliberate waves rather
/// than dribbling in. Waiting at 0 rather than joining the wave in
/// progress is what keeps it from popping.
class _Cohort {
  var opacity = 0.0;

  /// Whether this wave has started fading in. A cohort accumulates
  /// members at zero while `false`, and every member paints nothing
  /// until it flips.
  var rising = false;
}

class _KeyFade {
  var opacity = 0.0;

  /// The frame this key was last shown in — [LabelFadeTracker.sweep]
  /// fades everything whose stamp is stale.
  var stamp = 0;

  /// The arrival wave this key is fading in with, or null once it has
  /// reached full opacity (or started fading out) and owns its clock.
  _Cohort? cohort;
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
/// pass also runs the moment the candidate set itself changes
/// ([generation]) or the viewport is resized, so labels from a tile
/// that just landed never wait on the clock.
class PlacementThrottle {
  DateTime? _lastPass;
  int _generation = 0;
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
    final due = last == null ||
        interval <= Duration.zero ||
        generation != _generation ||
        screenSize != _screenSize ||
        !now.isBefore(last.add(interval)) ||
        // A clock stepped backwards (manual change, NTP) would otherwise
        // freeze placement until it caught up again.
        now.isBefore(last);
    _deferred = !due;
    if (!due) return false;
    _lastPass = now;
    _generation = generation;
    _screenSize = screenSize;
    return true;
  }

  /// Forgets the last pass, so the next frame places again.
  void reset() {
    _lastPass = null;
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
