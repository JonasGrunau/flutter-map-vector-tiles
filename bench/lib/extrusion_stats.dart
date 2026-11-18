/// The 3D-building pass inside one recording window: the `EXTRUDE`,
/// `EXTRUDE-RATE` and `EXTRUDE-SLOW` lines.
library;

// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'dart:math' as math;

import 'package:flutter_map_vector_tiles/src/render/extrusion_painter.dart'
    show ExtrusionPainter;

import 'report.dart';

class ExtrusionWindow {
  var _vertices0 = 0;
  var _rebuilds0 = 0;
  var _rebuildUs0 = 0;

  /// Starts logging every frame's pass. Until the first call the painter
  /// logs nothing and [lines] is empty.
  void start() {
    ExtrusionPainter.debugFrameLog = <int>[];
    ExtrusionPainter.debugFrameVertices = <int>[];
    ExtrusionPainter.debugFrameCullMicros = <int>[];
    _vertices0 = ExtrusionPainter.debugVertices;
    _rebuilds0 = ExtrusionPainter.debugRebuilds;
    _rebuildUs0 = ExtrusionPainter.debugRebuildMicros;
  }

  /// The report lines for the frames since [start] that drew buildings;
  /// none for a style without extrusions.
  List<String> lines() {
    final times = ExtrusionPainter.debugFrameLog;
    if (times == null || times.isEmpty) return const [];
    final vertices = ExtrusionPainter.debugVertices - _vertices0;
    final rebuilds = ExtrusionPainter.debugRebuilds - _rebuilds0;
    final rebuildUs = ExtrusionPainter.debugRebuildMicros - _rebuildUs0;
    final out = [
      '${frameStats("EXTRUDE", times)} '
          'vertices/frame=${vertices ~/ times.length} '
          'rebuilds=$rebuilds (${ms(rebuildUs)}ms)',
    ];
    final verts = ExtrusionPainter.debugFrameVertices!;
    final culls = ExtrusionPainter.debugFrameCullMicros!;
    if (verts.length == times.length) {
      out.addAll(_slowFrames(times, verts, culls));
    }
    return out;
  }

  /// The slowest 1 % of the frames: their vertices and candidate
  /// gathering against every frame's, to tell a frame that drew more from
  /// one that gathered the candidates again — and microseconds per vertex,
  /// the median of the frames that built vertices (the rest redrew the
  /// last frame's) against the slow ones', to tell either from a UI thread
  /// that ran slower.
  static List<String> _slowFrames(
      List<int> times, List<int> verts, List<int> culls) {
    final order = [for (var i = 0; i < times.length; i++) i]
      ..sort((a, b) => times[b] - times[a]);
    final slow = order.take(math.max(1, times.length ~/ 100)).toList();
    final culled = [
      for (final c in culls)
        if (c > 0) c
    ];
    final built = [
      for (var i = 0; i < times.length; i++)
        if (verts[i] > 0) times[i] / verts[i],
    ]..sort();
    final slowRate = [
      for (final i in slow)
        if (verts[i] > 0) times[i] / verts[i],
    ];
    String at(double q) => built.isEmpty
        ? '0'
        : built[(built.length * q).floor().clamp(0, built.length - 1)]
            .toStringAsFixed(3);
    final slowRateText =
        slowRate.isEmpty ? '0' : _mean(slowRate).toStringAsFixed(3);
    return [
      'EXTRUDE-RATE built=${built.length}/${times.length} '
          'us/vertex p50=${at(0.5)} p90=${at(0.9)} slow=$slowRateText',
      'EXTRUDE-SLOW n=${slow.length} '
          'ms=${ms(_mean([for (final i in slow) times[i]]).round())} '
          'verts=${_mean([for (final i in slow) verts[i]]).round()} '
          '(all ${_mean(verts).round()}) '
          'culled=${slow.where((i) => culls[i] > 0).length}/${slow.length} '
          'cullMs=${ms(_mean([for (final i in slow) culls[i]]).round())} '
          'culls=${culled.length} (mean ${ms(_mean(culled).round())}ms)',
    ];
  }

  // A loop, not `reduce`: a `(num, num) => num` combiner fails the
  // runtime check on a `List<double>`.
  static double _mean(Iterable<num> xs) {
    if (xs.isEmpty) return 0;
    var sum = 0.0;
    for (final x in xs) {
      sum += x;
    }
    return sum / xs.length;
  }
}
