import '../../core/cancellation.dart';
import '../prepared_tile.dart';
import '../tile_processor.dart';
import 'direct_executor.dart' if (dart.library.io) 'isolate_executor.dart'
    as impl;

/// Runs tile preparation off the UI thread where the platform allows.
///
/// Returns null for cancelled jobs — cancellation never throws.
abstract class TilePrepareExecutor {
  /// [priority]: lower values run first.
  Future<PreparedTile?> prepare(
    PrepareInput input, {
    int priority = 0,
    CancellationToken? cancellation,
  });

  void dispose();

  /// Creates the platform executor: an isolate pool on native, a
  /// yielding event-loop executor on web.
  factory TilePrepareExecutor({int concurrency}) = impl.PlatformExecutor;
}
