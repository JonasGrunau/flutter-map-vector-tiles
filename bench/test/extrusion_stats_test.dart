// The EXTRUDE lines from a hand-filled frame log.
// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member
library;

import 'package:flutter_map_vector_tiles/src/render/extrusion_painter.dart'
    show ExtrusionPainter;
import 'package:flutter_map_vector_tiles_bench/extrusion_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    ExtrusionPainter.debugFrameLog = null;
    ExtrusionPainter.debugFrameVertices = null;
    ExtrusionPainter.debugFrameCullMicros = null;
  });

  test('nothing before start, nor for a window that drew no buildings', () {
    ExtrusionPainter.debugFrameLog = null;
    expect(ExtrusionWindow().lines(), isEmpty);
    expect((ExtrusionWindow()..start()).lines(), isEmpty);
  });

  test('the pass, its rate per vertex and its slowest frames', () {
    final window = ExtrusionWindow()..start();
    // 200 frames: 198 that built 1000 vertices in 2 ms, one that redrew
    // the last frame's, and one slow frame that gathered candidates.
    ExtrusionPainter.debugFrameLog!
        .addAll([for (var i = 0; i < 198; i++) 2000, 500, 9000]);
    ExtrusionPainter.debugFrameVertices!
        .addAll([for (var i = 0; i < 198; i++) 1000, 0, 1500]);
    ExtrusionPainter.debugFrameCullMicros!
        .addAll([for (var i = 0; i < 199; i++) 0, 3000]);
    expect(window.lines(), [
      'EXTRUDE n=200 p50=2.00 p90=2.00 p99=2.00 max=9.00 '
          '>8.3=1 (0.5%) >16.7=0 (0.0%) vertices/frame=0 rebuilds=0 (0.0ms)',
      'EXTRUDE-RATE built=199/200 us/vertex p50=2.000 p90=2.000 slow=4.000',
      'EXTRUDE-SLOW n=2 ms=5.5 verts=1250 (all 998) culled=1/2 '
          'cullMs=1.5 culls=1 (mean 3.0ms)',
    ]);
  });
}
