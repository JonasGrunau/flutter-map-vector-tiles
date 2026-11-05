/// The `OPEN` line: the process's first screen.
library;

// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter/scheduler.dart' show FrameTiming;
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart'
    show LabelPainter;

import 'report.dart';

/// From the first build with the style until the map has drawn its first
/// screen and gone quiet. Covers what no phase sees: the process's first
/// tiles and first labels, fonts included.
class OpeningRecorder {
  /// Whether the first screen is still being recorded.
  bool get active => _active;
  var _active = true;

  DateTime? _start;
  DateTime? _firstLabelAt;
  DateTime? _lastFrameAt;
  final _build = <int>[];
  var _shapeMax = 0;
  var _shapeUs0 = 0;

  /// The first build with the style; later calls do nothing.
  void start() {
    if (_start != null) return;
    _start = DateTime.now();
    _shapeUs0 = LabelPainter.debugShapeMicros;
  }

  void addTimings(List<FrameTiming> timings) {
    if (!_active) return;
    for (final timing in timings) {
      _build.add(timing.buildDuration.inMicroseconds);
    }
  }

  /// One frame's end, with the label painting and shaping it did.
  void endFrame({required int labelUs, required int shapeUs}) {
    if (!_active || _start == null) return;
    final now = DateTime.now();
    _lastFrameAt = now;
    if (labelUs > 0) _firstLabelAt ??= now;
    if (shapeUs > _shapeMax) _shapeMax = shapeUs;
  }

  /// Waits for the first screen to finish — no frame for 2 s, at most 20 s
  /// — and reports how opening went: when the first label frame came, when
  /// the last frame did, and the UI-thread frames on the way.
  Future<void> report() async {
    final start = _start!;
    while (true) {
      final now = DateTime.now();
      final last = _lastFrameAt ?? start;
      if (now.difference(last) > const Duration(seconds: 2) ||
          now.difference(start) > const Duration(seconds: 20)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Let the timings callback deliver the last batch.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _active = false;
    final sorted = [..._build]..sort();
    final over = sorted.where((b) => b > 16667).length;
    final total = sorted.fold<int>(0, (a, b) => a + b);
    benchLog('OPEN '
        'firstLabel=${_firstLabelAt?.difference(start).inMilliseconds}ms '
        'settled=${(_lastFrameAt ?? start).difference(start).inMilliseconds}ms '
        'frames=${sorted.length} build=${ms(total)}ms '
        'max=${sorted.isEmpty ? '-' : ms(sorted.last)}ms '
        'top3=${sorted.reversed.take(3).map(ms).join('/')} '
        '>16.7=$over '
        'shape=${ms(LabelPainter.debugShapeMicros - _shapeUs0)}ms '
        'shapeMaxFrame=${ms(_shapeMax)}ms');
  }
}
