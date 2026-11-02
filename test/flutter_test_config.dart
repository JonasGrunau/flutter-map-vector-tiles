import 'dart:async';

import 'package:flutter_map_vector_tiles/src/render/label_worker.dart';

/// Runs every test with label placement in-frame: widget tests pump on a
/// fake clock that never waits for the placement worker's answer, and
/// they assert on what one frame placed. The worker has its own tests,
/// which turn it back on.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  LabelPlacementWorker.debugDisabled = true;
  await testMain();
}
