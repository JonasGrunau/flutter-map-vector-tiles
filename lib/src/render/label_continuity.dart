import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'symbol_layouter.dart';

/// What a label *is*, across layouts: the same text (or the same icon)
/// on the same style layer.
///
/// Deliberately position-free: it is the first half of a label's
/// identity, and `LabelIdentityIndex` supplies the second — it matches
/// copies of one key by world position, within a tolerance, and hands
/// each distinct label an integer id. Splitting it that way is what
/// tolerates the noise between two layouts of one label (a coarser
/// level simplifies differently, so the same feature's anchor lands a
/// fraction of a pixel apart), where an exact positional key would miss
/// and re-fade a label that never left — while two same-named POIs,
/// every housenumber "12" and every parking icon still get ids of their
/// own.
///
/// A [ContinuityKey], not an `Object.hash` value: grouping must compare
/// the actual triple, or a hash collision between unrelated labels would
/// silently conflate them. Its hash is computed once, and it is memoized
/// on the instance — the label pass looks it up several times per
/// candidate per frame.
Object labelContinuityKey(SymbolInstance symbol) => symbol.continuityKey;

/// The indices of a cohort whose label [ids] the last label pass drew,
/// in order — or null when it drew every one of them.
///
/// A cohort is pinned to this subset the moment its level is replaced:
/// an outgoing level exists to *keep* what was visible until the new
/// level covers it, never to introduce labels. Its losing candidates
/// would otherwise pop in mid-transition the instant a zoom-range cut
/// removes whatever was suppressing them — street names flashing up
/// just before a level with sparser labelling arrives, only to be faded
/// straight back out by the new level. Membership is by label id, so a
/// label counts as drawn whichever copy of it the pass drew.
List<int>? drawnLabels(Int32List ids, Set<int> drawn) {
  if (ids.isEmpty) return null;
  final kept = <int>[
    for (var i = 0; i < ids.length; i++)
      if (drawn.contains(ids[i])) i,
  ];
  return kept.length == ids.length ? null : kept;
}

/// Per-label fade state, keyed by label id (see `LabelIdentityIndex`):
/// one opacity per label, whatever instance happens to draw it.
///
/// Every frame the label pass marks the labels it placed ([show]); the
/// [sweep] then walks every other tracked state downward. Opacity moves
/// toward "placed ? 1 : 0" by the fraction of a fade one frame spans,
/// so any appearance eases in and any disappearance eases out — a tile
/// arriving, a level handing over, a collision won or lost, a zoom cut —
/// all through the same mechanism, with no per-cause bookkeeping.
///
/// Two properties carry the anti-blink guarantees:
///
/// * One opacity per label id. The outgoing and the arriving level's
///   copies of a label, seam twins and a republished tile's successor
///   all carry the label's id, so they resume one shared state: a
///   crossing can never cross-fade a label against itself. Labels the
///   index keeps apart fade apart: two same-named POIs, every
///   housenumber "12", every parking icon on a layer, and a street name
///   whose next level re-spaced its anchor (it cross-fades from the old
///   position to the new one instead of teleporting).
/// * Direction changes resume, never restart. A label re-placed mid
///   fade-out rises from its current opacity, so a label briefly
///   unplaced — a lost frame of collision — dips at most a step instead
///   of blinking to zero.
///
/// The tracker is self-pruning: a state that stays unplaced fades to
/// zero and is dropped, so the map holds roughly the set of recently
/// visible labels. Pure Dart and clock-agnostic — the caller supplies
/// `now` — which is what makes it unit-testable.
class LabelFadeTracker {
  final _fades = <int, _LabelFade>{};
  var _frame = 0;
  DateTime? _lastFrameAt;

  /// Fraction of a full fade this frame advances.
  var _step = 0.0;
  var _anyActive = false;

  /// Whether the last frame left any fade mid-flight — the caller keeps
  /// scheduling frames while true.
  bool get anyActive => _anyActive;

  /// Whether label [id] currently holds fade state (visible or fading
  /// out).
  bool isTracked(int id) => _fades.containsKey(id);

  /// The tracked opacity of label [id], or null when it has none.
  double? opacityOf(int id) => _fades[id]?.opacity;

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

  /// Marks label [id] as placed this frame and returns its opacity,
  /// risen by this frame's step — created at 0 on first sight (the
  /// caller's quantization keeps a new label's first frame one step
  /// above invisible). Idempotent within a frame.
  double show(int id) {
    final fade = _fades[id];
    if (fade == null) {
      _fades[id] = _LabelFade()..stamp = _frame;
      _anyActive = true;
      return 0;
    }
    if (fade.stamp == _frame) return fade.opacity;
    fade.stamp = _frame;
    fade.fading = false;
    if (fade.opacity < 1) {
      fade.opacity = math.min(1, fade.opacity + _step);
      if (fade.opacity < 1) _anyActive = true;
    }
    return fade.opacity;
  }

  /// Advances every state *not* shown this frame toward zero, reporting
  /// the ones still visible to [fadingOut] so the caller can draw their
  /// ghosts; states that reached zero are dropped. Call once per frame,
  /// after all [show] calls.
  ///
  /// With [hold], a state that no pass has yet confirmed gone keeps its
  /// opacity instead of decaying — it is still reported, so its ghost
  /// keeps drawing. Replay frames pass this: only a placement pass has
  /// the authority to start a fade-out, because between passes a winner
  /// may simply be unavailable — its tile gone before the successor
  /// arrived, say — and the throttled pass decides later. A fade-out a
  /// pass *has* started keeps advancing on every frame, held or not —
  /// one step per pass would stretch a 150ms fade across minutes.
  ///
  /// [fadingOut] must not touch the tracker.
  void sweep(void Function(int id, double opacity) fadingOut,
      {bool hold = false}) {
    _fades.removeWhere((id, fade) {
      if (fade.stamp == _frame) return false;
      if (!hold) fade.fading = true;
      if (fade.fading) fade.opacity -= _step;
      if (fade.opacity <= 0) return true;
      _anyActive = true;
      fadingOut(id, fade.opacity);
      return false;
    });
  }

  /// Forgets everything — for theme/provider swaps, where every label
  /// is replaced and layer indices change meaning.
  void clear() {
    _fades.clear();
    _lastFrameAt = null;
    _anyActive = false;
  }
}

/// One label's fade: its opacity, the frame it was last shown in
/// ([LabelFadeTracker.sweep] fades everything whose stamp is stale), and
/// whether a placement pass has confirmed its disappearance — until one
/// has, a held sweep keeps the opacity where it is (see
/// [LabelFadeTracker.sweep]).
class _LabelFade {
  var opacity = 0.0;
  var stamp = 0;
  var fading = false;
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

  /// The same for the icon: it lost its space at the last placement and
  /// only the text was drawn (`icon-optional`).
  bool iconDropped = false;

  /// The placement pass that last seated a symbol here, as `LabelPainter`
  /// stamps its passes. Several copies of one label share a sitting; the
  /// first placed in a pass owns the choices above for that pass.
  int seatedPass = 0;

  int _seen;

  SittingPlacement._(this._seen);
}

/// Where each label's [SittingPlacement] lives: keyed by label id (see
/// `LabelIdentityIndex`), so a decision outlives the instance that took
/// it.
///
/// A `SymbolInstance` is built per display-tile layout, so every zoom
/// crossing, provisional→final swap and re-layout hands the painter a
/// brand-new object for a street that never left the screen. State kept
/// on the instance dies with it: the arriving copy picks its anchor and
/// its reading direction cold, and since its fade carries over at full
/// opacity, the new choice lands instantly, with no crossfade to cover
/// it. That is a name jumping to the other side of its street at the
/// exact moment a zoom level hands over. The label id is what the
/// arriving copy shares with the one it replaces, and it is specific to
/// one label: every "Hauptstraße" on screen gets its own, so they never
/// share one side of the street.
class PlacementMemory {
  /// Frames an entry survives unseen. Passes are the slow clock here
  /// (one per fade duration, capped at 300ms), so this has to span
  /// several of them; a map that is not painting is not moving either,
  /// which is why the clock is frames rather than wall time.
  static const _maxIdleFrames = 90;

  final _entries = <int, SittingPlacement>{};
  var _frame = 0;

  /// Starts a frame. Expiry runs only on [prune] frames — the placement
  /// passes — since it walks every entry and nothing can go stale in
  /// between anyway.
  void beginFrame({required bool prune}) {
    _frame++;
    if (!prune) return;
    _entries.removeWhere((_, entry) => _frame - entry._seen > _maxIdleFrames);
  }

  /// The placement state of label [id], creating it on first sight.
  SittingPlacement sitting(int id) =>
      (_entries[id] ??= SittingPlacement._(_frame)).._seen = _frame;

  /// The placement state remembered for label [id], without creating
  /// one. For tests, and for callers that only want to know whether a
  /// label has been placed before.
  SittingPlacement? lookup(int id) => _entries[id];

  /// Forgets everything — for theme/provider swaps, where layer indices
  /// change meaning and no remembered choice still applies.
  void clear() => _entries.clear();
}
