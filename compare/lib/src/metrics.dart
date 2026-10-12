import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';

import 'platform/host.dart';

/// Records every frame the engine produces, for the measured passes and for
/// the demo's live readout.
///
/// The headline metric is **frame pacing**, taken from the engine's vsync
/// timestamp of each frame (`currentSystemFrameTimeStamp`): while a camera
/// path is animating, a frame is requested every vsync, so any gap longer
/// than one refresh interval is a frame the user did not get — no matter
/// whether the time went into building it, rasterizing it, or into work
/// scheduled between frames (an image decode, a PNG encode, a microtask
/// chain). Build and raster durations from `FrameTiming` are reported too,
/// but only explain a gap; they cannot find all of them, because work done
/// outside a frame never shows up in either.
class FrameLog {
  FrameLog._() {
    SchedulerBinding.instance
      ..addPersistentFrameCallback(_onFrame)
      ..addTimingsCallback(_onTimings);
  }

  static final FrameLog instance = FrameLog._();

  final _clock = Stopwatch()..start();
  _Recording? _recording;

  /// Wall-clock time of the most recent frame, in this log's clock.
  int lastFrameUs = 0;
  int get nowUs => _clock.elapsedMicroseconds;

  /// The last few seconds of frames, for the live readout.
  final recentFrames = ListQueue<int>();
  final recentTimings = ListQueue<FrameTiming>();

  void _onFrame(Duration _) {
    final vsync =
        SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
    lastFrameUs = nowUs;
    if (_recording case final recording? when !recording.closed) {
      recording.frames.add(vsync);
    }
    recentFrames.add(vsync);
    while (recentFrames.length > 2 &&
        vsync - recentFrames.first > 3 * 1000 * 1000) {
      recentFrames.removeFirst();
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    _recording?.timings.addAll(timings);
    recentTimings.addAll(timings);
    while (recentTimings.length > 400) {
      recentTimings.removeFirst();
    }
  }

  /// Starts collecting frames for one pass.
  void start() => _recording = _Recording();

  /// Stops collecting and summarizes the pass. Timings arrive in batches
  /// after their frames, so this waits for the last batch before cutting
  /// the window.
  Future<FrameStats> stop({required double refreshMs}) async {
    final recording = _recording!;
    // Frames produced from here on belong to no pass; timings still arrive.
    recording.closed = true;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    _recording = null;
    return FrameStats.from(
      recording.frames,
      recording.timings,
      refreshMs: refreshMs,
    );
  }

  /// Median frame interval while something requests a frame every vsync,
  /// i.e. the display's refresh interval as Flutter experiences it.
  Future<double> calibrate() async {
    final ticker = Ticker((_) {});
    unawaited(ticker.start());
    start();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    ticker.dispose();
    final frames = List<int>.of(_recording!.frames);
    _recording = null;
    final gaps = _gaps(frames.skip(5).toList())..sort();
    return gaps.isEmpty ? 16.667 : _pct(gaps, 0.5);
  }

  /// A live summary of the last two seconds, for the demo's readout.
  FrameStats recent({required double refreshMs}) {
    if (recentFrames.isEmpty) return FrameStats.empty;
    final cutoff = recentFrames.last - 2 * 1000 * 1000;
    final frames = recentFrames.where((f) => f >= cutoff).toList();
    return FrameStats.from(
      frames,
      recentTimings.where(
        (t) => t.timestampInMicroseconds(FramePhase.vsyncStart) >= cutoff,
      ),
      refreshMs: refreshMs,
      // Between gestures nothing asks for frames, and an idle second is not
      // a dropped second; only gaps inside continuous motion count.
      idleGapMs: 400,
    );
  }
}

class _Recording {
  final frames = <int>[];
  final timings = <FrameTiming>[];
  bool closed = false;
}

List<double> _gaps(List<int> vsyncs) => [
      for (var i = 1; i < vsyncs.length; i++)
        (vsyncs[i] - vsyncs[i - 1]) / 1000,
    ];

double _pct(List<double> sorted, double q) => sorted.isEmpty
    ? 0
    : sorted[math.min(sorted.length - 1, (sorted.length * q).floor())];

class Percentiles {
  Percentiles(List<double> values) : _sorted = values..sort();

  final List<double> _sorted;

  double get p50 => _pct(_sorted, 0.50);
  double get p90 => _pct(_sorted, 0.90);
  double get p99 => _pct(_sorted, 0.99);
  double get max => _sorted.isEmpty ? 0 : _sorted.last;

  Map<String, double> toJson() => {
        'p50': _round(p50),
        'p90': _round(p90),
        'p99': _round(p99),
        'max': _round(max),
      };
}

double _round(double v) => (v * 100).roundToDouble() / 100;

/// One pass, summarized.
class FrameStats {
  FrameStats._({
    required this.frames,
    required this.durationMs,
    required this.refreshMs,
    required this.dropped,
    required this.stalls50,
    required this.gaps,
    required this.build,
    required this.raster,
    required this.timingsMatched,
  });

  factory FrameStats.from(
    List<int> vsyncs,
    Iterable<FrameTiming> timings, {
    required double refreshMs,
    double? idleGapMs,
  }) {
    var gaps = _gaps(vsyncs);
    if (idleGapMs != null) gaps = gaps.where((g) => g < idleGapMs).toList();
    var dropped = 0;
    for (final g in gaps) {
      dropped += math.max(0, (g / refreshMs).round() - 1);
    }
    final first = vsyncs.isEmpty ? 0 : vsyncs.first - 1000;
    final last = vsyncs.isEmpty ? 0 : vsyncs.last + 1000;
    final inWindow = timings.where((t) {
      final v = t.timestampInMicroseconds(FramePhase.vsyncStart);
      return v >= first && v <= last;
    }).toList();
    return FrameStats._(
      frames: vsyncs.length,
      durationMs: vsyncs.length < 2 ? 0 : (vsyncs.last - vsyncs.first) / 1000,
      refreshMs: refreshMs,
      dropped: dropped,
      stalls50: gaps.where((g) => g > 50).length,
      gaps: Percentiles(List.of(gaps)),
      build: Percentiles([
        for (final t in inWindow) t.buildDuration.inMicroseconds / 1000,
      ]),
      raster: Percentiles([
        for (final t in inWindow) t.rasterDuration.inMicroseconds / 1000,
      ]),
      timingsMatched: inWindow.length,
    );
  }

  static final empty = FrameStats.from(const [], const [], refreshMs: 16.667);

  final int frames;
  final double durationMs;
  final double refreshMs;

  /// Refresh intervals that passed without a frame.
  final int dropped;

  /// Gaps over 50 ms: the hitches a user notices as a stutter.
  final int stalls50;
  final Percentiles gaps;
  final Percentiles build;
  final Percentiles raster;

  /// How many `FrameTiming`s fell into the window; should be close to
  /// [frames], and is reported so a mismatch is visible rather than silent.
  final int timingsMatched;

  /// Share of the frames the display could have shown that were produced.
  double get deliveredPct =>
      frames + dropped == 0 ? 100 : 100 * frames / (frames + dropped);

  double get fps => durationMs == 0 ? 0 : (frames - 1) * 1000 / durationMs;

  Map<String, Object?> toJson() => {
        'frames': frames,
        'durationMs': _round(durationMs),
        'refreshMs': _round(refreshMs),
        'fps': _round(fps),
        'dropped': dropped,
        'deliveredPct': _round(deliveredPct),
        'stalls50': stalls50,
        'gapMs': gaps.toJson(),
        'buildMs': build.toJson(),
        'rasterMs': raster.toJson(),
        'timingsMatched': timingsMatched,
      };
}

/// Peak resident memory over a pass, sampled every 200 ms (native only).
class RssSampler {
  RssSampler() {
    _sample();
    _timer =
        Timer.periodic(const Duration(milliseconds: 200), (_) => _sample());
  }

  late final Timer _timer;
  int? _max;

  void _sample() {
    final rss = currentRss();
    if (rss != null && (_max == null || rss > _max!)) _max = rss;
  }

  /// Peak RSS in MB, or null on web.
  double? stop() {
    _timer.cancel();
    _sample();
    return _max == null ? null : _round(_max! / (1024 * 1024));
  }
}
