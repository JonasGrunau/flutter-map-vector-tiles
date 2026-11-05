// The stability counters, fed frames by hand: what counts as a pop-in,
// a pop-out, a blink and a jump, and what does not count at all.
// ignore_for_file: implementation_imports
library;

import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/src/render/label_painter.dart'
    show DrawnLabelRecord;
import 'package:flutter_map_vector_tiles_bench/label_stability.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

final _camera = MapCamera(
  crs: const Epsg3857(),
  center: const LatLng(48.1372, 11.5755),
  zoom: 16,
  rotation: 0,
  nonRotatedSize: const Size(400, 800),
);

DrawnLabelRecord _label(Object key, double x, double y,
        {double opacity = 1, bool ghost = false, bool alongLine = false}) =>
    (
      key: key,
      id: key.hashCode,
      position: Offset(x, y),
      opacity: opacity,
      ghost: ghost,
      alongLine: alongLine,
    );

void main() {
  final lines = <String>[];
  late DebugPrintCallback print0;
  setUp(() {
    lines.clear();
    print0 = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
  });
  tearDown(() => debugPrint = print0);

  LabelStabilityTracker track(List<List<DrawnLabelRecord>> frames,
      {bool recording = true}) {
    final tracker = LabelStabilityTracker();
    for (final frame in frames) {
      tracker.onFrame(frame, camera: _camera, recording: recording);
    }
    return tracker;
  }

  test(
      'a label that leaves and comes back at full opacity: pop-in, '
      'pop-out, then a blink', () {
    final s = track([
      [_label('A', 200, 400)],
      [],
      [_label('A', 202, 400)],
      [_label('A', 202, 400)],
    ]).counters;
    expect(s.frames, 4);
    expect(s.seen, 3);
    expect((s.appearPt, s.popInPt, s.gonePt, s.popOutPt, s.blinkPt),
        (2, 2, 1, 1, 1));
    expect(s.appearLn + s.popInLn + s.blinkLn + s.jumpPt, 0);
    expect(lines.where((l) => l.contains(' BLINK ')), hasLength(1));
  });

  test('a fade-in and a ghost fade-out are not pops', () {
    final s = track([
      [_label('A', 200, 400, opacity: 0.2)],
      [_label('A', 200, 400, opacity: 0.6, ghost: true)],
      [],
    ]).counters;
    expect((s.appearPt, s.popInPt, s.gonePt, s.popOutPt), (1, 0, 1, 0));
  });

  test('an along-line label taking up a sitting 300 px off: a jump', () {
    final s = track([
      [_label('Street', 200, 100, alongLine: true)],
      [],
      [_label('Street', 200, 400, alongLine: true)],
    ]).counters;
    expect((s.jumpLn, s.blinkLn, s.jumpPt), (1, 0, 0));
  });

  test('off screen counts nothing; neither does a window not recording', () {
    expect(
        track([
          [_label('A', -100, 400)]
        ]).counters.appearPt,
        0);
    final idle = track([
      [_label('A', 200, 400)],
      [],
    ], recording: false)
        .counters;
    expect((idle.frames, idle.appearPt, idle.gonePt), (0, 0, 0));
  });

  test('labels carried over from before the window continue', () {
    final tracker = LabelStabilityTracker()
      ..onFrame([_label('A', 200, 400)], camera: _camera, recording: false)
      ..onFrame([_label('A', 201, 400)], camera: _camera, recording: true);
    expect(tracker.counters.appearPt, 0);
  });

  test('report: rejects, then the STABILITY line', () {
    final tracker = track([
      [_label('A', 200, 400)],
    ])
      ..onReject('A', 'collision', false);
    tracker.report('cold-in');
    expect(
        lines.where((l) => l.contains(' REJECT 1 collision A')), hasLength(1));
    expect(
        lines.last,
        'BENCH[run] STABILITY cold-in frames=1 seen/frame=1 · '
        'pt popIn=1 popOut=0 blink=0 jump=0 appear=1 gone=0 · '
        'ln popIn=0 popOut=0 blink=0 jump=0 appear=0 gone=0');
  });
}
