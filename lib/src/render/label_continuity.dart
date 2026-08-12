import 'dart:math' as math;

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

  /// Whether the last frame left any fade mid-flight — the caller keeps
  /// scheduling frames while true.
  bool get anyActive => _anyActive;

  /// Whether [key] currently holds fade state (visible or fading out).
  bool isTracked(Object key) => _states.containsKey(key);

  /// The tracked opacity of [key], or null when untracked.
  double? opacityOf(Object key) => _states[key]?.opacity;

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

  /// Marks [key] as placed this frame and returns its opacity, risen by
  /// this frame's step. A key new to the tracker starts at 0 — the
  /// caller's quantization keeps its first frame one step above
  /// invisible. Idempotent within a frame: seam twins and the retained
  /// copy of a carried-over label share one state.
  double show(Object key) {
    final state = _states[key];
    if (state == null) {
      _states[key] = _KeyFade()..stamp = _frame;
      _anyActive = true;
      return 0;
    }
    if (state.stamp == _frame) return state.opacity;
    state.stamp = _frame;
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
    _lastFrameAt = null;
    _anyActive = false;
  }
}

class _KeyFade {
  var opacity = 0.0;

  /// The frame this key was last shown in — [LabelFadeTracker.sweep]
  /// fades everything whose stamp is stale.
  var stamp = 0;
}
