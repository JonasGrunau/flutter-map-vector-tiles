/// Label steadiness: pop-ins, pop-outs, blinks and jumps, for the
/// `stability` and `manual` modes.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter_map/flutter_map.dart' show MapCamera;
// The labels a frame drew come from the package's internal probe.
// ignore: implementation_imports
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart'
    show DrawnLabelRecord;

import 'env.dart';
import 'report.dart';
import 'worker_stats.dart';

/// Matches what the label pass drew each frame against the frame before,
/// per continuity key, in zoom-20 world pixels — a frame-rate- and
/// camera-independent identity, so a label can be recognised across a
/// whole sweep, not just across one frame — and counts the violations.
///
/// Counters only move while recording; the frame-to-frame memory runs
/// always, so a window never opens against an empty previous frame.
class LabelStabilityTracker {
  /// How long after a label disappears a reappearance nearby still counts
  /// as a blink. At sweep speed this spans ~0.5 zoom — further apart than
  /// that reads as two events, not a twitch.
  static const blinkWindow = Duration(seconds: 4);

  /// Matching radii, in screen pixels at the moment of the event. A
  /// continuation must be found within one frame's camera drift; a blink
  /// may return slightly off (the successor level re-derives anchors).
  static const _continuityRadiusPx = 48.0;
  static const _blinkRadiusPx = 64.0;

  /// A jump: the same label leaves one sitting and takes up another
  /// further away than a blink but still on screen, within
  /// [_jumpWindow] — a street name re-anchored along its road at a
  /// zoom crossing reads as this (cross-faded, so it is neither a pop
  /// nor a blink). Either order counts: the new sitting often fades in
  /// before the old one's ghost has finished.
  static const _jumpRadiusPx = 600.0;
  static const _jumpWindow = Duration(milliseconds: 1000);

  /// Seam twins draw one label twice at (near) the same anchor; merged
  /// before matching or every twin count change reads as an event.
  static const _twinRadiusPx = 4.0;

  /// The current window's counts.
  var counters = StabilityCounters();

  final _prev = <Object, List<_SeenLabel>>{};
  final _gone = <_GoneLabel>[];
  final _appeared = <_GoneLabel>[];
  final _rejects = <String, int>{};
  var _lastCommits = 0;

  /// The continuity key of every label id drawn so far: a fade-out with
  /// no copy left to draw (`ghost:none`) is reported by id alone, and
  /// this names it, for the tallies and for `BENCH_WATCH`.
  final _keyOfId = <int, Object>{};

  /// Starts a new window's counts.
  void reset() => counters = StabilityCounters();

  /// One candidate the label pass did not draw, and why.
  void onReject(Object key, String reason, bool replay, {double? zoom}) {
    if (key is int) key = _keyOfId[key] ?? key;
    final k = '$reason${replay ? '/replay' : ''} $key';
    if (Env.watch?.hasMatch('$key') ?? false) {
      benchLog('WATCH z=${zoom?.toStringAsFixed(3)} '
          't=${DateTime.now().millisecondsSinceEpoch % 100000} $k');
    }
    _rejects[k] = (_rejects[k] ?? 0) + 1;
  }

  /// Consumes one frame's drawn-label report from the painter. Converts
  /// every anchor to zoom-20 world pixels, matches it against last
  /// frame's, and counts the three stability violations: a label
  /// *appearing* at full opacity (pop-in — it skipped its fade-in), a
  /// full-opacity label *vanishing* with no ghost behind it (pop-out),
  /// and a label returning to a spot it left within [blinkWindow]
  /// (blink — the visible→hidden→visible twitch). [camera] is null until
  /// the map is ready.
  void onFrame(List<DrawnLabelRecord> drawn,
      {required MapCamera? camera, required bool recording}) {
    // Whether this label pass adopted a placement worker's answer.
    final commits = placementWorkerCommits();
    final adopted = commits != _lastCommits;
    _lastCommits = commits;
    final watch = recording ? Env.watch : null;
    for (final record in drawn) {
      _keyOfId[record.id] = record.key;
      if (watch != null && watch.hasMatch('${record.key}')) {
        benchLog('DRAWN z=${camera?.zoom.toStringAsFixed(3)} '
            't=${DateTime.now().millisecondsSinceEpoch % 100000} '
            'id=${record.id} at=${record.position.dx.toStringAsFixed(1)},'
            '${record.position.dy.toStringAsFixed(1)} '
            'opacity=${record.opacity.toStringAsFixed(2)}'
            '${record.ghost ? ' ghost' : ''} ${record.key}');
      }
    }
    if (camera == null) return;
    _FrameMatch(this, camera, drawn, recording: recording, adopted: adopted)
        .run();
  }

  /// Prints the window's `REJECT` tallies and its `STABILITY` line, and
  /// starts the tallies afresh.
  void report(String phase) {
    final top = _rejects.entries.toList()..sort((a, b) => b.value - a.value);
    for (final e in top.take(15)) {
      benchLog('REJECT ${e.value} ${e.key}');
    }
    for (final e in top.skip(15)) {
      if (e.key.startsWith('ghost') || e.key.contains('/replay')) {
        benchLog('REJECT ${e.value} ${e.key}');
      }
    }
    _rejects.clear();
    final s = counters;
    final frames = s.frames == 0 ? 1 : s.frames;
    benchLog('STABILITY $phase frames=${s.frames} '
        'seen/frame=${(s.seen / frames).toStringAsFixed(0)} · '
        'pt popIn=${s.popInPt} popOut=${s.popOutPt} blink=${s.blinkPt} '
        'jump=${s.jumpPt} '
        'appear=${s.appearPt} gone=${s.gonePt} · '
        'ln popIn=${s.popInLn} popOut=${s.popOutLn} blink=${s.blinkLn} '
        'jump=${s.jumpLn} '
        'appear=${s.appearLn} gone=${s.goneLn}');
  }
}

/// One frame's matching against the frame before, in the camera of that
/// moment.
class _FrameMatch {
  _FrameMatch(this.tracker, MapCamera camera, this.drawn,
      {required this.recording, required this.adopted})
      : zoom = camera.zoom,
        scale = math.pow(2.0, 20 - camera.zoom).toDouble(),
        worldCenter = camera.projectAtZoom(camera.center, camera.zoom),
        size = camera.nonRotatedSize,
        cosR = math.cos(camera.rotationRad),
        sinR = math.sin(camera.rotationRad),
        now = DateTime.now() {
    double r2(double px) => math.pow(px * scale, 2).toDouble();
    twinR2 = r2(LabelStabilityTracker._twinRadiusPx);
    contR2 = r2(LabelStabilityTracker._continuityRadiusPx);
    blinkR2 = r2(LabelStabilityTracker._blinkRadiusPx);
    jumpR2 = r2(LabelStabilityTracker._jumpRadiusPx);
  }

  /// The tracker whose memory this frame reads and updates.
  final LabelStabilityTracker tracker;
  final List<DrawnLabelRecord> drawn;
  final bool recording, adopted;
  final double zoom, cosR, sinR;

  /// Screen pixels to zoom-20 world pixels.
  final double scale;
  final Offset worldCenter;
  final Size size;
  final DateTime now;

  /// The matching radii, squared, in zoom-20 world pixels.
  late final double twinR2, contR2, blinkR2, jumpR2;

  StabilityCounters get s => tracker.counters;

  void run() {
    final current = _merged();
    current.forEach(_matchKey);
    _missing();
    tracker._appeared.removeWhere(
        (a) => now.difference(a.at) > LabelStabilityTracker._jumpWindow);
    tracker._gone.removeWhere(
        (gone) => now.difference(gone.at) > LabelStabilityTracker.blinkWindow);
    tracker._prev
      ..clear()
      ..addAll(current);
    if (recording) {
      s.frames++;
      s.seen += drawn.length;
    }
  }

  /// This frame's labels, seam twins merged, in zoom-20 world pixels.
  Map<Object, List<_SeenLabel>> _merged() {
    final screenCenter = Offset(size.width / 2, size.height / 2);
    final current = <Object, List<_SeenLabel>>{};
    for (final record in drawn) {
      final rel = record.position - screenCenter;
      // Anchors are screen-space; undo the camera rotation.
      final level =
          Offset(rel.dx * cosR + rel.dy * sinR, rel.dy * cosR - rel.dx * sinR);
      final world = (worldCenter + level) * scale;
      final list = current[record.key] ??= [];
      _SeenLabel? twin;
      for (final other in list) {
        if ((other.world - world).distanceSquared < twinR2) {
          twin = other;
          break;
        }
      }
      if (twin != null) {
        twin.opacity = math.max(twin.opacity, record.opacity);
        twin.ghost = twin.ghost && record.ghost;
      } else {
        list.add(_SeenLabel(
            world, record.opacity, record.ghost, record.alongLine, record.id));
      }
    }
    return current;
  }

  /// Events are only counted where a user could see them: labels are
  /// laid out up to 150px past the viewport, and a pop or blink out
  /// there — the cull line sweeping over a label as the zoom drifts —
  /// is invisible.
  bool _onScreen(Offset world) {
    final level = world / scale - worldCenter;
    // Back into screen axes: the matching space above undid the camera
    // rotation.
    final dx = level.dx * cosR - level.dy * sinR;
    final dy = level.dx * sinR + level.dy * cosR;
    return dx.abs() <= size.width / 2 && dy.abs() <= size.height / 2;
  }

  bool _isJump(Offset a, Offset b, DateTime at) {
    if (now.difference(at) > LabelStabilityTracker._jumpWindow) return false;
    final d = (a - b).distanceSquared;
    return d >= blinkR2 && d < jumpR2;
  }

  /// This frame's labels of one key against last frame's: the ones that
  /// continue a label, and what the rest are.
  void _matchKey(Object key, List<_SeenLabel> list) {
    final prev = tracker._prev[key];
    // Closest pairs first, so the order labels are drawn in cannot
    // decide which one continues a label from the last frame: matched
    // in list order, a newcomer drawn ahead of a label of the same name
    // next to it took that label's predecessor, and the label that had
    // not moved counted as a pop-in.
    final continued = Set<_SeenLabel>.identity();
    if (prev != null) {
      final pairs = <(double, _SeenLabel, _SeenLabel)>[];
      for (final label in list) {
        for (final p in prev) {
          final d = (p.world - label.world).distanceSquared;
          if (d < contR2) pairs.add((d, label, p));
        }
      }
      pairs.sort((a, b) => a.$1.compareTo(b.$1));
      for (final (_, label, p) in pairs) {
        if (p.matched || continued.contains(label)) continue;
        p.matched = true;
        continued.add(label);
      }
    }
    for (final label in list) {
      if (continued.contains(label)) continue;
      // A ghost never starts a life: an unmatched one is the tail of a
      // fade whose start this tracker missed.
      if (label.ghost || !recording || !_onScreen(label.world)) continue;
      _appeared(key, label, prev, list);
    }
  }

  /// A label that continues none from last frame: a pop-in if it came at
  /// full opacity, and a blink or jump if one of its key left nearby.
  void _appeared(Object key, _SeenLabel label, List<_SeenLabel>? prev,
      List<_SeenLabel> list) {
    label.alongLine ? s.appearLn++ : s.appearPt++;
    if (label.opacity >= 1) {
      label.alongLine ? s.popInLn++ : s.popInPt++;
      // The same key's labels around this one, last frame and now:
      // which id drew here before, and what else draws here now.
      final near = 64 * scale;
      String around(List<_SeenLabel>? labels) => [
            for (final l in labels ?? const <_SeenLabel>[])
              if (!identical(l, label) &&
                  (l.world - label.world).distance < near)
                l.describe(label.world, scale),
          ].join(', ');
      benchLog('POPIN z=${zoom.toStringAsFixed(2)} '
          'adopt=$adopted ${label.describe(label.world, scale)} '
          'before=[${around(prev)}] now=[${around(list)}] key=$key');
    }
    for (var i = 0; i < tracker._gone.length; i++) {
      final gone = tracker._gone[i];
      if (gone.key == key &&
          (gone.world - label.world).distanceSquared < blinkR2) {
        label.alongLine ? s.blinkLn++ : s.blinkPt++;
        benchLog('BLINK z=${zoom.toStringAsFixed(2)} '
            'off=${now.difference(gone.at).inMilliseconds}ms '
            'from-centre=${_fromCentre(label.world)}px '
            'key=$key');
        tracker._gone.removeAt(i);
        return;
      }
    }
    for (var i = 0; i < tracker._gone.length; i++) {
      final gone = tracker._gone[i];
      if (gone.key == key && _isJump(gone.world, label.world, gone.at)) {
        label.alongLine ? s.jumpLn++ : s.jumpPt++;
        _logJump(key, gone.world, label.world);
        tracker._gone.removeAt(i);
        return;
      }
    }
    tracker._appeared.add(_GoneLabel(key, label.world, now, label.alongLine));
  }

  /// Last frame's labels this frame did not continue: pop-outs if they
  /// left at full opacity with no ghost, and the second half of a jump if
  /// one of their key appeared nearby.
  void _missing() {
    tracker._prev.forEach((key, list) {
      for (final p in list) {
        if (p.matched) continue;
        if (recording && _onScreen(p.world)) {
          p.alongLine ? s.goneLn++ : s.gonePt++;
          if (Env.logGone) {
            benchLog('GONE z=${zoom.toStringAsFixed(3)} '
                't=${now.millisecondsSinceEpoch % 100000} key=$key');
          }
          if (!p.ghost && p.opacity >= 1) {
            p.alongLine ? s.popOutLn++ : s.popOutPt++;
            benchLog('POPOUT z=${zoom.toStringAsFixed(2)} '
                'from-centre=${_fromCentre(p.world)}px '
                'key=$key');
          }
        }
        var jumped = false;
        for (var i = 0; i < tracker._appeared.length; i++) {
          final a = tracker._appeared[i];
          if (a.key == key && _isJump(a.world, p.world, a.at)) {
            if (recording && _onScreen(p.world)) {
              p.alongLine ? s.jumpLn++ : s.jumpPt++;
              _logJump(key, a.world, p.world);
            }
            tracker._appeared.removeAt(i);
            jumped = true;
            break;
          }
        }
        // Only a disappearance someone could see may later pair up as
        // a blink or jump.
        if (!jumped && _onScreen(p.world)) {
          tracker._gone.add(_GoneLabel(key, p.world, now, p.alongLine));
        }
      }
    });
  }

  String _fromCentre(Offset world) =>
      (world / scale - worldCenter).distance.toStringAsFixed(0);

  /// One `JUMP` line per jump, so a count can be read back into the
  /// labels behind it (a re-anchored street vs a same-key sibling).
  void _logJump(Object key, Offset from, Offset to) {
    final d = (to - from).distance / scale;
    benchLog('JUMP z=${zoom.toStringAsFixed(2)} '
        'd=${d.toStringAsFixed(0)}px key=$key');
  }
}

/// One label drawn last frame, in zoom-20 world pixels. [matched] marks
/// it as continued by the current frame during matching.
class _SeenLabel {
  final Offset world;
  double opacity;
  bool ghost;
  final bool alongLine;

  /// The label id of the copy drawn here (the first one, for merged
  /// seam twins); for the `POPIN` line.
  final int id;
  bool matched = false;

  _SeenLabel(this.world, this.opacity, this.ghost, this.alongLine, this.id);

  String describe(Offset from, double scale) =>
      '#$id@${((world - from).distance / scale).toStringAsFixed(0)}px'
      '${ghost ? ' ghost' : ''} ${opacity.toStringAsFixed(2)}';
}

/// A label that stopped (or started) drawing, kept for a while so a
/// reappearance at the same spot can be recognised as a blink, or one
/// further off as a jump.
class _GoneLabel {
  final Object key;
  final Offset world;
  final DateTime at;
  final bool alongLine;

  _GoneLabel(this.key, this.world, this.at, this.alongLine);
}

/// Stability violations inside one recording window, split point (`Pt`)
/// vs along-line (`Ln`) — the two label kinds fail differently and are
/// fixed by different mechanisms.
class StabilityCounters {
  var frames = 0;
  var seen = 0;
  var popInPt = 0, popOutPt = 0, blinkPt = 0, appearPt = 0, gonePt = 0;
  var popInLn = 0, popOutLn = 0, blinkLn = 0, appearLn = 0, goneLn = 0;
  var jumpPt = 0, jumpLn = 0;
}
