import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';

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

  /// Sticky fallback: once isolate spawning has failed with no worker
  /// alive, every job — including those enqueued later — runs on the
  /// event loop. Without this, `concurrency` failed spawns would leave
  /// the pool permanently empty and later jobs hanging forever.
  var _inlineMode = false;
  var _inlineDraining = false;

  /// Makes every spawn attempt fail, as on embedders without isolate
  /// support. For tests only.
  @visibleForTesting
  static var debugFailSpawns = false;

  PlatformExecutor({this.concurrency = 3});

  @override
  Future<PreparedTile?> prepare(
    PrepareInput input, {
    int priority = 0,
    CancellationToken? cancellation,
  }) {
    if (_disposed) return Future.value(null);
    final job = _Job(
        input, priority, cancellation ?? CancellationToken.none, Completer());
    _queue
      ..add(job)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    _dispatch();
    return job.completer.future;
  }

  void _dispatch() {
    if (_disposed) return;
    if (_inlineMode) {
      unawaited(_drainInline());
      return;
    }
    if (_spawnedWorkers < concurrency && _queue.isNotEmpty) {
      _spawnedWorkers++;
      _Worker.spawn(
          onReady: _onWorkerReady, onIdle: _dispatch, onDied: _onWorkerDied);
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
      // embedders). Release the never-filled pool slot; with no worker
      // alive, fall back to the event loop — stickily, so jobs enqueued
      // after this drain cannot hang waiting for a pool that will never
      // exist.
      _spawnedWorkers--;
      if (_workers.isEmpty && !_disposed) {
        _inlineMode = true;
        unawaited(_drainInline());
      }
      return;
    }
    if (_disposed || _inlineMode) {
      worker.dispose();
      return;
    }
    _workers.add(worker);
    _dispatch();
  }

  /// The worker's isolate died without being disposed (OS kill, OOM).
  /// Its in-flight job has already been failed; free the pool slot and
  /// re-dispatch so a replacement spawns while there is work.
  void _onWorkerDied(_Worker worker) {
    if (_disposed) return;
    _workers.remove(worker);
    _spawnedWorkers--;
    worker.dispose();
    _dispatch();
  }

  Future<void> _drainInline() async {
    if (_inlineDraining) return;
    _inlineDraining = true;
    try {
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
    } finally {
      _inlineDraining = false;
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

  /// Kills every worker isolate without disposing the executor,
  /// simulating workers dying underneath it (OS kill). For tests only.
  @visibleForTesting
  void debugKillWorkers() {
    for (final worker in _workers) {
      worker._isolate.kill(priority: Isolate.immediate);
    }
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
  final ReceivePort _exitPort;
  final void Function() onIdle;
  final void Function(_Worker) onDied;
  _Job? _current;
  var _disposed = false;

  _Worker._(this._isolate, this._sendPort, this._receivePort, this._exitPort,
      {required this.onIdle, required this.onDied}) {
    _receivePort.listen(_onResult);
    _exitPort.listen(_onExit);
  }

  bool get busy => _current != null;

  /// Spawns a worker; reports it via [onReady] once its send port is
  /// established, or reports null when isolates are unavailable.
  static void spawn({
    required void Function(_Worker?) onReady,
    required void Function() onIdle,
    required void Function(_Worker) onDied,
  }) {
    if (PlatformExecutor.debugFailSpawns) {
      scheduleMicrotask(() => onReady(null));
      return;
    }
    final startupPort = ReceivePort();
    final exitPort = ReceivePort();
    Isolate.spawn(
      _workerMain,
      startupPort.sendPort,
      debugName: 'vector-tile-prepare',
      onExit: exitPort.sendPort,
    ).then((isolate) {
      startupPort.first.then((message) {
        final resultPort = ReceivePort();
        final sendPort = message as SendPort;
        sendPort.send(resultPort.sendPort);
        onReady(_Worker._(isolate, sendPort, resultPort, exitPort,
            onIdle: onIdle, onDied: onDied));
      });
    }).catchError((Object _) {
      startupPort.close();
      exitPort.close();
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

  /// The isolate exited without [dispose] — killed by the OS, not us.
  /// Fail the in-flight job (a null result is a throttled retry, never a
  /// hang) and let the executor free the pool slot.
  void _onExit(Object? _) {
    if (_disposed) return;
    final job = _current;
    _current = null;
    if (job != null && !job.completer.isCompleted) {
      job.completer.complete(null);
    }
    onDied(this);
  }

  void dispose() {
    _disposed = true;
    final job = _current;
    _current = null;
    if (job != null && !job.completer.isCompleted) {
      job.completer.complete(null);
    }
    _receivePort.close();
    _exitPort.close();
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
