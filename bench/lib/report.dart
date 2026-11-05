/// Log lines and the package's work counters they are built from.
library;

// The package's debug counters live in its `src/`; see main.dart for why
// the bench reads them anyway.
// ignore_for_file: implementation_imports
// ignore_for_file: invalid_use_of_visible_for_testing_member

import 'package:flutter/foundation.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart'
    show LabelPainter;
import 'package:flutter_map_vector_tiles/src/render/symbol_layouter.dart'
    show SymbolLayouter;
import 'package:flutter_map_vector_tiles/src/render/tile_rasterizer.dart'
    show TileRasterizer;

import 'env.dart';

/// Prints one line, tagged with the run's label so two runs can be diffed
/// and `summarize.py` can find them.
void benchLog(String line) => debugPrint('BENCH[${Env.label}] $line');

/// Microseconds as milliseconds with one decimal.
String ms(num us) => (us / 1000).toStringAsFixed(1);

/// A frame-time distribution, in ms: `name n=… p50=… p90=… p99=… max=…`
/// and the frames over each refresh budget. 8.33ms is the budget on a
/// ProMotion device and 16.7ms on a 60Hz one. Both are reported because a
/// run that clears 16.7 but misses 8.3 on a 120Hz phone is still a visible
/// hitch.
String frameStats(String name, List<int> samples) {
  if (samples.isEmpty) return '$name: no frames';
  final sorted = [...samples]..sort();
  int percentile(double p) => sorted[((sorted.length - 1) * p).round()];
  String ms2(int us) => (us / 1000).toStringAsFixed(2);
  final over8 = samples.where((x) => x > 8333).length;
  final over16 = samples.where((x) => x > 16667).length;
  return '$name n=${samples.length} '
      'p50=${ms2(percentile(0.5))} p90=${ms2(percentile(0.90))} '
      'p99=${ms2(percentile(0.99))} max=${ms2(sorted.last)} '
      '>8.3=$over8 (${(100 * over8 / samples.length).toStringAsFixed(1)}%) '
      '>16.7=$over16 '
      '(${(100 * over16 / samples.length).toStringAsFixed(1)}%)';
}

/// A distribution of anything counted in thousandths, shown divided by
/// 1000: `n=… p50=… p90=… p99=… max=…`.
String distribution(List<int> micros) {
  if (micros.isEmpty) return 'n=0';
  final s = [...micros]..sort();
  String at(double q) =>
      (s[((s.length - 1) * q).round()] / 1000).toStringAsFixed(2);
  return 'n=${s.length} p50=${at(.5)} p90=${at(.9)} p99=${at(.99)} '
      'max=${at(1)}';
}

/// The package's cumulative work counters at one moment, or, from
/// [since], what they did between two moments.
class WorkCounters {
  /// Tiles rasterized, and the UI time it took.
  final int rasters, rasterUs;

  /// Symbol layouts run, and the UI time they took.
  final int layouts, layoutUs;

  /// Label painting in all, then split: full placement passes, replayed
  /// frames, the candidate sort, paragraph shaping, the fade sweep and
  /// drawing.
  final int labelUs, placeUs, replayUs, sortUs, shapeUs, sweepUs, drawUs;

  /// Frames that ran a placement pass in-frame.
  final int placing;

  WorkCounters.now()
      : rasters = TileRasterizer.debugRasterizeCount,
        rasterUs = TileRasterizer.debugRasterizeMicros,
        layouts = SymbolLayouter.debugLayoutCount,
        layoutUs = SymbolLayouter.debugLayoutMicros,
        labelUs = LabelPainter.debugPaintMicros,
        placeUs = LabelPainter.debugPlaceMicros,
        replayUs = LabelPainter.debugReplayMicros,
        sortUs = LabelPainter.debugSortMicros,
        shapeUs = LabelPainter.debugShapeMicros,
        sweepUs = LabelPainter.debugSweepMicros,
        drawUs = LabelPainter.debugDrawMicros,
        placing = LabelPainter.debugPlacingFrames;

  WorkCounters.zero()
      : rasters = 0,
        rasterUs = 0,
        layouts = 0,
        layoutUs = 0,
        labelUs = 0,
        placeUs = 0,
        replayUs = 0,
        sortUs = 0,
        shapeUs = 0,
        sweepUs = 0,
        drawUs = 0,
        placing = 0;

  WorkCounters.since(WorkCounters a, WorkCounters b)
      : rasters = a.rasters - b.rasters,
        rasterUs = a.rasterUs - b.rasterUs,
        layouts = a.layouts - b.layouts,
        layoutUs = a.layoutUs - b.layoutUs,
        labelUs = a.labelUs - b.labelUs,
        placeUs = a.placeUs - b.placeUs,
        replayUs = a.replayUs - b.replayUs,
        sortUs = a.sortUs - b.sortUs,
        shapeUs = a.shapeUs - b.shapeUs,
        sweepUs = a.sweepUs - b.sweepUs,
        drawUs = a.drawUs - b.drawUs,
        placing = a.placing - b.placing;

  /// What the counters did from [before] until this snapshot.
  WorkCounters since(WorkCounters before) => WorkCounters.since(this, before);
}

/// Rasterize time per style layer so far.
Map<String, int> layerTimesNow() =>
    Map<String, int>.of(TileRasterizer.debugLayerMicros);

/// Rasterize time per style layer since [before] was taken with
/// [layerTimesNow], leaving out the layers that took none.
Map<String, int> layerTimesSince(Map<String, int> before) {
  final delta = <String, int>{};
  TileRasterizer.debugLayerMicros.forEach((id, us) {
    final d = us - (before[id] ?? 0);
    if (d > 0) delta[id] = d;
  });
  return delta;
}
