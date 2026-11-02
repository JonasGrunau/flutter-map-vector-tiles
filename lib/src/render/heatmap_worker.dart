import 'heatmap_density.dart';
import 'heatmap_worker_inline.dart'
    if (dart.library.io) 'heatmap_worker_isolate.dart' as impl;

/// Runs [renderHeatmap] off the UI thread where the platform allows: in
/// one long-lived worker isolate on native platforms, on the event loop
/// on web, which has no isolates.
///
/// Everything per point is pure arithmetic over the job's typed lists —
/// placing, culling, summing and colouring — so all of it leaves the
/// root isolate; turning the pixels into an image needs `dart:ui`, and
/// stays.
abstract class HeatmapWorker {
  /// [job] rendered; null when no point counts, when the worker was
  /// disposed meanwhile or when the job failed — never an error.
  Future<HeatmapResult?> render(HeatmapJob job);

  void dispose();

  factory HeatmapWorker() = impl.PlatformHeatmapWorker;
}
