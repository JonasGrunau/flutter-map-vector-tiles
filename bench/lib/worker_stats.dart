// The label placement worker's counters, apart from main.dart so that an
// A/B arm built from a checkout without the worker can swap this file for
// a stub (zero events, no line) and still run the same harness.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:flutter_map_vector_tiles/src/render/label_worker.dart'
    show LabelPlacementWorker;

/// Placement events on the UI thread so far: pass requests sent to the
/// worker and its answers adopted. A frame with one counts as a placing
/// frame next to the in-frame passes.
int placementWorkerEvents() =>
    LabelPlacementWorker.debugRequests + LabelPlacementWorker.debugCommits;

/// The worker's counters, for diffing over a window.
List<int> placementWorkerCounters() => [
      LabelPlacementWorker.debugRequests,
      LabelPlacementWorker.debugRequestMicros,
      LabelPlacementWorker.debugCommits,
      LabelPlacementWorker.debugCommitLatencyFrames,
      LabelPlacementWorker.debugWorkerMicros,
      LabelPlacementWorker.debugMirrorCount,
      LabelPlacementWorker.debugMirrorBytes,
      LabelPlacementWorker.debugMirrorMicros,
      LabelPlacementWorker.debugUnmeasured,
      LabelPlacementWorker.debugMissingCohorts,
      LabelPlacementWorker.debugAdoptedWinners,
      LabelPlacementWorker.debugAdoptedDrawn,
    ];

/// The `WORKER` report line for counters diffed over a window, or null
/// when the worker did nothing in it.
String? placementWorkerLine(List<int> before) {
  final now = placementWorkerCounters();
  final d = [for (var i = 0; i < now.length; i++) now[i] - before[i]];
  final [
    requests,
    requestUs,
    commits,
    latency,
    workerUs,
    mirrors,
    bytes,
    mirrorUs,
    unmeasured,
    missing,
    adopted,
    adoptedDrawn,
  ] = d;
  if (requests == 0 && commits == 0 && mirrors == 0) return null;
  String ms(int us) => (us / 1000).toStringAsFixed(2);
  String per(int total, int n) => n == 0 ? '-' : ms(total ~/ n);
  return 'WORKER requests=$requests ui=${per(requestUs, requests)}ms/req '
      'commits=$commits latency='
      '${commits == 0 ? '-' : (latency / commits).toStringAsFixed(2)}frames '
      'pass=${per(workerUs, commits)}ms(worker) '
      'mirrors=$mirrors ${(bytes / 1024).round()}KB '
      'ui=${ms(mirrorUs)}ms total ${per(mirrorUs, mirrors)}ms/list '
      'live=${(LabelPlacementWorker.debugMirrorLiveBytes / 1024).round()}KB '
      'unmeasured=$unmeasured missing=$missing '
      'adopted=$adopted drewOnAdopt=$adoptedDrawn';
}
