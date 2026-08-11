/// The two per-tile render phases, in processing order: geometry
/// rasters land for every pending tile before any symbol extraction
/// runs, so a zoom-level crossing shows imagery first and labels a
/// frame or two later instead of paying both costs per tile at once.
enum RenderPhase { raster, symbols }

/// Per-tile job queue for the render pump, keyed by tile handle.
///
/// Semantics the pump relies on:
/// - at most one job per (tile, phase); a replaced job is handed to
///   [onDrop] (jobs own resources such as raster image handles);
/// - accepting a raster job drops the tile's pending symbols job — the
///   raster re-enqueues symbol extraction from its own, newer sources.
///   A caller that must not lose those symbols therefore has to reject
///   the raster before enqueueing it ([pendingRaster], [pendingSymbols]
///   report what is queued);
/// - [pop] is phase-major (all rasters before any symbols), then by
///   ascending priority (viewport centre first). The linear scan is
///   fine at queue sizes of a zoom-level change (≤ ~50 entries).
class RenderJobQueue<T, J> {
  final void Function(J job) onDrop;
  final _raster = <T, ({int priority, J job})>{};
  final _symbols = <T, ({int priority, J job})>{};

  RenderJobQueue({required this.onDrop});

  bool get isEmpty => _raster.isEmpty && _symbols.isEmpty;
  int get length => _raster.length + _symbols.length;

  /// The tile's queued raster job, for replacement policies (a queued
  /// final raster must not be displaced by a provisional one).
  J? pendingRaster(T key) => _raster[key]?.job;

  /// The tile's queued symbols job — same purpose as [pendingRaster],
  /// for the phase whose job an incoming raster would supersede.
  J? pendingSymbols(T key) => _symbols[key]?.job;

  void enqueueRaster(T key, int priority, J job) {
    final existingRaster = _raster.remove(key);
    if (existingRaster != null) onDrop(existingRaster.job);
    // Superseded: the accepted raster re-enqueues symbols itself.
    final existingSymbols = _symbols.remove(key);
    if (existingSymbols != null) onDrop(existingSymbols.job);
    _raster[key] = (priority: priority, job: job);
  }

  void enqueueSymbols(T key, int priority, J job) {
    final existing = _symbols.remove(key);
    if (existing != null) onDrop(existing.job);
    _symbols[key] = (priority: priority, job: job);
  }

  ({T key, RenderPhase phase, J job})? pop() {
    for (final (map, phase) in [
      (_raster, RenderPhase.raster),
      (_symbols, RenderPhase.symbols),
    ]) {
      if (map.isEmpty) continue;
      T? bestKey;
      var bestPriority = 0;
      map.forEach((key, entry) {
        if (bestKey == null || entry.priority < bestPriority) {
          bestKey = key;
          bestPriority = entry.priority;
        }
      });
      final job = map.remove(bestKey as T)!.job;
      return (key: bestKey as T, phase: phase, job: job);
    }
    return null;
  }

  /// Drops the tile's jobs in both phases (tile disposed/cancelled).
  void remove(T key) {
    final raster = _raster.remove(key);
    if (raster != null) onDrop(raster.job);
    final symbols = _symbols.remove(key);
    if (symbols != null) onDrop(symbols.job);
  }

  void clear() {
    final dropped = [
      for (final entry in _raster.values) entry.job,
      for (final entry in _symbols.values) entry.job,
    ];
    _raster.clear();
    _symbols.clear();
    dropped.forEach(onDrop);
  }
}
