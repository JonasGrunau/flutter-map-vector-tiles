import 'dart:async';
import 'dart:isolate';

import '../../core/cancellation.dart';
import '../prepared_tile.dart';
import '../tile_processor.dart';
import 'executor.dart';

/// Native executor: a pool of long-lived worker isolates with a priority
/// queue. Cancelled jobs are dropped from the queue without ever
/// surfacing an error.
class PlatformExecutor implements TilePrepareExecutor {
  final int concurrency;
  final _queue = <_Job>[];
  final _workers = <_Worker>[];
  var _spawnedWorkers = 0;
  var _disposed = false;

  PlatformExecutor({this.concurrency = 3});

  @override
  Future<PreparedTile?> prepare(
    PrepareInput input, {
    int priority = 0,
    CancellationToken? cancellation,
  }) {
    if (_disposed) return Future.value(null);
    final job = _Job(input, priority, cancellation ?? CancellationToken.none,
        Completer());
    _queue
      ..add(job)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    _dispatch();
    return job.completer.future;
  }

  void _dispatch() {
    if (_disposed) return;
    if (_spawnedWorkers < concurrency && _queue.isNotEmpty) {
      _spawnedWorkers++;
      _Worker.spawn(onReady: _onWorkerReady, onIdle: _dispatch);
    }
    for (final worker in _workers) {
      if (worker.busy) continue;
      final job = _nextJob();
      if (job == null) return;
      worker.run(job);
    }
  }

  void _onWorkerReady(_Worker? worker) {
    if (worker == null) {
      // Isolate spawning is unavailable (e.g. heavily constrained
      // embedders). Drain the queue on the event loop instead.
      _drainInline();
      return;
    }
    if (_disposed) {
      worker.dispose();
      return;
    }
    _workers.add(worker);
    _dispatch();
  }

  Future<void> _drainInline() async {
    while (_queue.isNotEmpty && !_disposed) {
      final job = _nextJob();
      if (job == null) break;
      await Future<void>.delayed(Duration.zero);
      PreparedTile? result;
      try {
        result = job.cancellation.isCancelled || _disposed
            ? null
            : prepareTileSync(job.input);
      } catch (_) {
        result = null;
      }
      job.completer.complete(result);
    }
  }

  _Job? _nextJob() {
    while (_queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      if (job.cancellation.isCancelled) {
        job.completer.complete(null);
        continue;
      }
      return job;
    }
    return null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final job in _queue) {
      job.completer.complete(null);
    }
    _queue.clear();
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
  }
}

class _Job {
  final PrepareInput input;
  final int priority;
  final CancellationToken cancellation;
  final Completer<PreparedTile?> completer;

  _Job(this.input, this.priority, this.cancellation, this.completer);
}

/// A single worker isolate. Only constructed in the ready state — see
/// [spawn].
class _Worker {
  final Isolate _isolate;
  final SendPort _sendPort;
  final ReceivePort _receivePort;
  final void Function() onIdle;
  _Job? _current;
  var _disposed = false;

  _Worker._(this._isolate, this._sendPort, this._receivePort,
      {required this.onIdle}) {
    _receivePort.listen(_onResult);
  }

  bool get busy => _current != null;

  /// Spawns a worker; reports it via [onReady] once its send port is
  /// established, or reports null when isolates are unavailable.
  static void spawn({
    required void Function(_Worker?) onReady,
    required void Function() onIdle,
  }) {
    final startupPort = ReceivePort();
    Isolate.spawn(
      _workerMain,
      startupPort.sendPort,
      debugName: 'vector-tile-prepare',
    ).then((isolate) {
      startupPort.first.then((message) {
        final resultPort = ReceivePort();
        final sendPort = message as SendPort;
        sendPort.send(resultPort.sendPort);
        onReady(_Worker._(isolate, sendPort, resultPort, onIdle: onIdle));
      });
    }).catchError((Object _) {
      startupPort.close();
      onReady(null);
    });
  }

  void run(_Job job) {
    assert(_current == null);
    _current = job;
    _sendPort.send(job.input);
  }

  void _onResult(Object? message) {
    final job = _current;
    _current = null;
    if (job != null && !job.completer.isCompleted) {
      job.completer.complete(
        !_disposed && message is PreparedTile && !job.cancellation.isCancelled
            ? message
            : null,
      );
    }
    if (!_disposed) onIdle();
  }

  void dispose() {
    _disposed = true;
    final job = _current;
    _current = null;
    if (job != null && !job.completer.isCompleted) {
      job.completer.complete(null);
    }
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
  }
}

void _workerMain(SendPort startup) {
  final commandPort = ReceivePort();
  startup.send(commandPort.sendPort);
  SendPort? resultPort;
  commandPort.listen((message) {
    if (message is SendPort) {
      resultPort = message;
    } else if (message is PrepareInput) {
      Object? result;
      try {
        result = prepareTileSync(message);
      } catch (_) {
        result = null;
      }
      resultPort?.send(result);
    }
  });
}
