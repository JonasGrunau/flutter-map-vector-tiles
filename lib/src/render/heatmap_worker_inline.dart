import 'heatmap_density.dart';
import 'heatmap_worker.dart';

/// The web's [HeatmapWorker]: no isolates, so the job runs on the event
/// loop, after the frame that asked for it.
class PlatformHeatmapWorker implements HeatmapWorker {
  var _disposed = false;

  @override
  Future<HeatmapResult?> render(HeatmapJob job) async {
    await Future<void>.delayed(Duration.zero);
    if (_disposed) return null;
    try {
      return renderHeatmap(job);
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() => _disposed = true;
}
