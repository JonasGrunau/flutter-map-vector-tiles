import 'dart:async';
import 'dart:isolate';

import 'heatmap_density.dart';
import 'heatmap_worker.dart';

/// The native [HeatmapWorker]: one isolate, spawned on the first job and
/// kept for the layer's lifetime, so a pass pays no spawn. Should
/// spawning fail, or the isolate die, jobs run on the event loop instead
/// — slower frames beat no heatmap.
class PlatformHeatmapWorker implements HeatmapWorker {
  Future<SendPort?>? _port;
  Isolate? _isolate;
  ReceivePort? _results;
  ReceivePort? _exit;
  final _pending = <int, Completer<HeatmapResult?>>{};
  var _nextId = 0;
  var _disposed = false;

  @override
  Future<HeatmapResult?> render(HeatmapJob job) async {
    if (_disposed) return null;
    final port = await (_port ??= _spawn());
    if (_disposed) return null;
    if (port == null) {
      try {
        return renderHeatmap(job);
      } catch (_) {
        return null;
      }
    }
    final id = _nextId++;
    final result = _pending[id] = Completer<HeatmapResult?>();
    port.send((id, job));
    return result.future;
  }

  Future<SendPort?> _spawn() async {
    final startup = ReceivePort();
    final exit = ReceivePort();
    try {
      _isolate = await Isolate.spawn(_workerMain, startup.sendPort,
          debugName: 'vector-tile-heatmap', onExit: exit.sendPort);
    } catch (_) {
      startup.close();
      exit.close();
      return null;
    }
    final port = await startup.first as SendPort;
    if (_disposed) {
      exit.close();
      _isolate?.kill(priority: Isolate.immediate);
      return null;
    }
    final results = _results = ReceivePort()..listen(_onResult);
    _exit = exit..listen((_) => _onExit());
    port.send(results.sendPort);
    return port;
  }

  void _onResult(Object? message) {
    if (message is! (int, _Rendered?)) return;
    final (id, rendered) = message;
    _pending.remove(id)?.complete(rendered?.result);
  }

  /// The isolate died under us (killed by the OS): fail what it held and
  /// spawn afresh for the next job.
  void _onExit() {
    if (_disposed) return;
    _results?.close();
    _exit?.close();
    _results = _exit = null;
    _isolate = null;
    _port = null;
    _failPending();
  }

  void _failPending() {
    for (final result in _pending.values) {
      result.complete(null);
    }
    _pending.clear();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _failPending();
    _results?.close();
    _exit?.close();
    _isolate?.kill(priority: Isolate.immediate);
  }
}

void _workerMain(SendPort startup) {
  final commands = ReceivePort();
  startup.send(commands.sendPort);
  SendPort? results;
  commands.listen((message) {
    if (message is SendPort) {
      results = message;
    } else if (message is (int, HeatmapJob)) {
      final (id, job) = message;
      _Rendered? rendered;
      try {
        final result = renderHeatmap(job);
        if (result != null) rendered = _Rendered(result);
      } catch (_) {
        rendered = null;
      }
      results?.send((id, rendered));
    }
  });
}

/// A [HeatmapResult] on its way back, its pixels moved rather than
/// copied.
class _Rendered {
  final TransferableTypedData pixels;
  final int width;
  final int height;
  final double left;
  final double top;
  final double coverWidth;
  final double coverHeight;

  _Rendered(HeatmapResult result)
      : pixels = TransferableTypedData.fromList([result.pixels]),
        width = result.width,
        height = result.height,
        left = result.left,
        top = result.top,
        coverWidth = result.coverWidth,
        coverHeight = result.coverHeight;

  HeatmapResult get result => HeatmapResult(
        pixels: pixels.materialize().asUint8List(),
        width: width,
        height: height,
        left: left,
        top: top,
        coverWidth: coverWidth,
        coverHeight: coverHeight,
      );
}
