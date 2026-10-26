import 'dart:typed_data';

import 'heatmap_density.dart';
import 'heatmap_worker_inline.dart'
    if (dart.library.io) 'heatmap_worker_isolate.dart' as impl;

/// Runs [renderHeatmap] off the UI thread where the platform allows: in
/// one long-lived worker isolate on native platforms, on the event loop
/// on web, which has no isolates.
///
/// The density is pure arithmetic over the job's typed lists, the one
/// part of a heatmap pass that can leave the root isolate — gathering
/// the points needs the tiles, and turning pixels into an image needs
/// `dart:ui`, both of which stay.
abstract class HeatmapWorker {
  /// [job]'s pixels; null when the worker was disposed meanwhile or the
  /// job failed — never an error.
  Future<Uint8List?> render(HeatmapJob job);

  void dispose();

  factory HeatmapWorker() = impl.PlatformHeatmapWorker;
}
