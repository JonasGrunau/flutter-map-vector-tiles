/// Frame timings inside one recording window, and the report block that
/// sums one up.
library;

import 'package:flutter/scheduler.dart' show FrameTiming;
// The labels a frame drew come from the package's internal probe.
// ignore: implementation_imports
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart'
    show DrawnLabelRecord;

import 'extrusion_stats.dart';
import 'report.dart';
import 'worker_stats.dart';

/// Keeps each frame's BUILD (UI thread) and RASTER (GPU thread) time; see
/// main.dart for why the two must not be mixed up.
///
/// BUILD is also split by whether the frame ran a label placement pass,
/// matched to its [FrameTiming] by engine frame number — placing frames
/// are where the label pass's jank concentrates, so their share of the
/// slow frames is the number a placement change has to move. Plus the
/// labels drawn per frame, which a placement change must not quietly cut.
class FrameRecorder {
  /// Whether a window is open. Frames outside one are not kept.
  bool get recording => _recording;
  var _recording = false;

  /// Whether the app left the foreground while recording: that parks the
  /// render pump, so the window's numbers would be fiction.
  var interrupted = false;

  /// The 3D-building pass, reported with every window once started.
  final extrusion = ExtrusionWindow();

  DateTime? _start;
  var _allFrames = 0;
  var _build = <int>[];
  var _raster = <int>[];
  var _buildPlacing = <int>[];
  var _buildOther = <int>[];
  final _framePlacing = <int, bool>{};
  var _workerBefore = const <int>[];

  // The labels drawn per frame, ghosts apart, and by style zoom in fifths
  // of a level; [countDrawn] parks one frame's until [endFrame].
  var _drawnCounts = <int>[];
  var _ghostCounts = <int>[];
  var _drawnByZoom = <int, List<int>>{};
  var _pendingDrawn = -1;
  var _pendingGhosts = 0;
  var _pendingZoom = 0.0;

  // The zoom band the window covered, for manual mode's report.
  var _zoomLo = double.infinity;
  var _zoomHi = double.negativeInfinity;

  /// Opens a window: everything counted so far is dropped.
  void start() {
    _build = <int>[];
    _raster = <int>[];
    _buildPlacing = <int>[];
    _buildOther = <int>[];
    _framePlacing.clear();
    _drawnCounts = <int>[];
    _ghostCounts = <int>[];
    _drawnByZoom = {};
    _workerBefore = placementWorkerCounters();
    _allFrames = 0;
    interrupted = false;
    _zoomLo = double.infinity;
    _zoomHi = double.negativeInfinity;
    _start = DateTime.now();
    _recording = true;
  }

  void stop() => _recording = false;

  /// Whether the window saw any frame. A manual window with none means an
  /// untouched screen.
  bool get hasFrames => _build.isNotEmpty;

  /// The zoom band the window covered: `z=lo..hi`, or `z=?`.
  String get zoomBand => _zoomLo.isFinite
      ? 'z=${_zoomLo.toStringAsFixed(2)}..${_zoomHi.toStringAsFixed(2)}'
      : 'z=?';

  /// One batch of the engine's frame timings. [zoom] is the camera's now:
  /// the callback lags the frames it describes by a beat, which is close
  /// enough to tag a jank with the zoom that caused it.
  void addTimings(List<FrameTiming> timings, double? zoom) {
    _allFrames += timings.length;
    if (!_recording) return;
    if (zoom != null) {
      if (zoom < _zoomLo) _zoomLo = zoom;
      if (zoom > _zoomHi) _zoomHi = zoom;
    }
    for (final timing in timings) {
      final build = timing.buildDuration.inMicroseconds;
      final raster = timing.rasterDuration.inMicroseconds;
      _build.add(build);
      _raster.add(raster);
      switch (_framePlacing.remove(timing.frameNumber)) {
        case true:
          _buildPlacing.add(build);
        case false:
          _buildOther.add(build);
        case null:
      }
      // A frame past the 60 Hz budget is a hitch anyone can see; log it the
      // moment it happens so it lines up with what the finger just did.
      if (zoom != null && (build > 16667 || raster > 16667)) {
        benchLog('JANK z=${zoom.toStringAsFixed(2)} '
            'build=${(build / 1000).toStringAsFixed(1)}ms '
            'raster=${(raster / 1000).toStringAsFixed(1)}ms');
      }
    }
  }

  /// What the label pass drew this frame, at [styleZoom].
  void countDrawn(double styleZoom, List<DrawnLabelRecord> drawn) {
    _pendingDrawn = drawn.length;
    _pendingZoom = styleZoom;
    _pendingGhosts = 0;
    for (final label in drawn) {
      if (label.ghost) _pendingGhosts++;
    }
  }

  /// Closes engine frame [frameNumber]: whether it did placement work,
  /// and the labels [countDrawn] parked for it.
  void endFrame(int frameNumber, {required bool placing}) {
    final drawn = _pendingDrawn;
    _pendingDrawn = -1;
    if (!_recording) return;
    _framePlacing[frameNumber] = placing;
    if (drawn >= 0) {
      _drawnCounts.add(drawn - _pendingGhosts);
      _ghostCounts.add(_pendingGhosts);
      (_drawnByZoom[(_pendingZoom * 5).floor()] ??= [])
          .add(drawn - _pendingGhosts);
    }
  }

  /// Prints the window's report block. [layerUs] adds the `LAYERS` line
  /// and [labelSplit] the `LABELS-SPLIT` one.
  void report(String phase, WorkCounters work,
      {Map<String, int>? layerUs, bool labelSplit = false}) {
    final seconds = DateTime.now().difference(_start!).inMilliseconds / 1000;
    // layouts/rasterizes are the headline for cache work: a crossing served
    // entirely from the finished-tile cache reports zero of both.
    benchLog('--- $phase --- '
        'window=${seconds.toStringAsFixed(1)}s '
        'fps=${(_allFrames / seconds).toStringAsFixed(1)} '
        'layouts=${work.layouts} rasterizes=${work.rasters} '
        'interrupted=$interrupted');
    benchLog('  ${frameStats("BUILD ", _build)}');
    benchLog('  ${frameStats("RASTER", _raster)}');
    // BUILD of the frames that ran a placement pass vs the rest, and how
    // many of the slow (>16.7 ms) frames the placing ones are. Frames whose
    // timing could not be matched to a post-frame record count in BUILD only.
    benchLog('  ${frameStats("B-PLACE", _buildPlacing)}');
    benchLog('  ${frameStats("B-OTHER", _buildOther)}');
    final slowPlacing = _buildPlacing.where((x) => x > 16667).length;
    final slowAll = _build.where((x) => x > 16667).length;
    benchLog('  SLOW   >16.7=$slowAll placing=$slowPlacing '
        '(${slowAll == 0 ? 0 : (100 * slowPlacing / slowAll).round()}%) '
        'matched=${_buildPlacing.length + _buildOther.length}/${_build.length}');
    final worker = placementWorkerLine(_workerBefore);
    if (worker != null) benchLog('  $worker');
    if (_drawnCounts.isNotEmpty) benchLog('  ${_drawnLine()}');
    // Where the window's publish work went, in UI-thread wall time. The
    // remainder of BUILD (flutter_map, widget build, everything else) is
    // whatever these three do not account for.
    benchLog('  WORK   rasterize=${ms(work.rasterUs)}ms '
        'layout=${ms(work.layoutUs)}ms labels=${ms(work.labelUs)}ms');
    for (final line in extrusion.lines()) {
      benchLog('  $line');
    }
    // The label pass split: full placement passes (and how many frames ran
    // one), replayed frames, the per-frame candidate sort, and paragraph
    // shaping on cache misses. Whatever `labels` holds beyond these is
    // drawing the placed symbols.
    if (labelSplit) {
      benchLog('  LABELS-SPLIT '
          'place=${ms(work.placeUs)}ms/${work.placing}passes '
          'replay=${ms(work.replayUs)}ms sort=${ms(work.sortUs)}ms '
          'shape=${ms(work.shapeUs)}ms sweep=${ms(work.sweepUs)}ms '
          'draw=${ms(work.drawUs)}ms');
    }
    // Which style layers the rasterize time went to, worst first — the
    // level below WORK's phase split, naming the actual culprit.
    if (layerUs != null && layerUs.isNotEmpty) {
      final top = layerUs.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      benchLog('  LAYERS '
          '${top.take(8).map((e) => '${e.key}=${ms(e.value)}').join(' ')}');
    }
  }

  /// Labels drawn per frame, and their mean per fifth of a zoom level: a
  /// placement change that drops or doubles labels mid-sweep shows as a
  /// zoom band out of line with the baseline's.
  String _drawnLine() {
    final sorted = [..._drawnCounts]..sort();
    int at(double p) => sorted[((sorted.length - 1) * p).round()];
    final mean = sorted.reduce((a, b) => a + b) / sorted.length;
    final ghosts = _ghostCounts.isEmpty
        ? 0.0
        : _ghostCounts.reduce((a, b) => a + b) / _ghostCounts.length;
    final bands = (_drawnByZoom.keys.toList()..sort()).map((band) {
      final counts = _drawnByZoom[band]!;
      final mean = counts.reduce((a, b) => a + b) / counts.length;
      return '${(band / 5).toStringAsFixed(1)}:${mean.round()}';
    });
    return 'DRAWN  frames=${sorted.length} '
        'mean=${mean.toStringAsFixed(1)} p10=${at(0.1)} p50=${at(0.5)} '
        'p90=${at(0.9)} ghosts=${ghosts.toStringAsFixed(1)} '
        'byZoom ${bands.join(' ')}';
  }
}
