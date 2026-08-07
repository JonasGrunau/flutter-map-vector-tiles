import 'dart:async';

import '../../core/cancellation.dart';
import '../prepared_tile.dart';
import '../tile_processor.dart';
import 'executor.dart';

/// Web executor: no isolate support, so jobs run on the event loop —
/// serialized through a queue with a yield between jobs to keep frames
/// flowing.
class PlatformExecutor implements TilePrepareExecutor {
  final _queue = <_Job>[];
  var _running = false;
  var _disposed = false;

  PlatformExecutor({int concurrency = 2});

  @override
  Future<PreparedTile?> prepare(
    PrepareInput input, {
    int priority = 0,
    CancellationToken? cancellation,
  }) {
    final job = _Job(
        input, priority, cancellation ?? CancellationToken.none, Completer());
    _queue
      ..add(job)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    _pump();
    return job.completer.future;
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    while (_queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      if (_disposed || job.cancellation.isCancelled) {
        job.completer.complete(null);
        continue;
      }
      // Yield to the event loop so input/raster events are not starved.
      await Future<void>.delayed(Duration.zero);
      try {
        job.completer.complete(_disposed || job.cancellation.isCancelled
            ? null
            : prepareTileSync(job.input));
      } catch (_) {
        job.completer.complete(null);
      }
    }
    _running = false;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final job in _queue) {
      job.completer.complete(null);
    }
    _queue.clear();
  }
}

class _Job {
  final PrepareInput input;
  final int priority;
  final CancellationToken cancellation;
  final Completer<PreparedTile?> completer;

  _Job(this.input, this.priority, this.cancellation, this.completer);
}
