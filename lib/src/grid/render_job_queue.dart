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
///   ascending priority (viewport centre first) — or, asked for
///   `tileMajor`, by priority alone, a tile's symbols ahead of rasters
///   of equal priority. Within a phase, a `resumed` job (one the pump
///   put back after it ran out of tick) wins a tie, so tiles of equal
///   priority finish one after the other instead of taking turns a
///   slice each. The linear scan is fine at queue sizes of a
///   zoom-level change (≤ ~50 entries).
class RenderJobQueue<T, J> {
  final void Function(J job) onDrop;
  final _raster = <T, _Entry<J>>{};
  final _symbols = <T, _Entry<J>>{};

  RenderJobQueue({required this.onDrop});

  bool get isEmpty => _raster.isEmpty && _symbols.isEmpty;
  int get length => _raster.length + _symbols.length;

  /// The tile's queued raster job, for replacement policies (a queued
  /// final raster must not be displaced by a provisional one).
  J? pendingRaster(T key) => _raster[key]?.job;

  /// The tile's queued symbols job — same purpose as [pendingRaster],
  /// for the phase whose job an incoming raster would supersede.
  J? pendingSymbols(T key) => _symbols[key]?.job;

  /// Every queued symbols job, in no particular order.
  Iterable<J> get symbolJobs => _symbols.values.map((entry) => entry.job);

  /// [resumed] marks a job the pump started and is putting back
  /// unfinished; it goes ahead of other jobs of equal priority.
  void enqueueRaster(T key, int priority, J job, {bool resumed = false}) {
    final existingRaster = _raster.remove(key);
    if (existingRaster != null) onDrop(existingRaster.job);
    // Superseded: the accepted raster re-enqueues symbols itself.
    final existingSymbols = _symbols.remove(key);
    if (existingSymbols != null) onDrop(existingSymbols.job);
    _raster[key] = (priority: priority, resumed: resumed, job: job);
  }

  /// [resumed] as for [enqueueRaster].
  void enqueueSymbols(T key, int priority, J job, {bool resumed = false}) {
    final existing = _symbols.remove(key);
    if (existing != null) onDrop(existing.job);
    _symbols[key] = (priority: priority, resumed: resumed, job: job);
  }

  /// The next job to run. [tileMajor] is for a pump whose tiles only
  /// show once both phases are done (`LabelMode.tile`): phase-major
  /// order would hold every tile back until the last raster had run,
  /// while this finishes the most central tile first. Ties go to the
  /// symbols phase, so a tile whose raster just ran is finished before
  /// the next one is started.
  ({T key, RenderPhase phase, J job})? pop({bool tileMajor = false}) {
    if (tileMajor) {
      final symbols = _best(_symbols);
      final raster = _best(_raster);
      if (symbols == null && raster == null) return null;
      final takeSymbols = raster == null ||
          (symbols != null && symbols.priority <= raster.priority);
      final (map, phase, key) = takeSymbols
          ? (_symbols, RenderPhase.symbols, symbols!.key)
          : (_raster, RenderPhase.raster, raster.key);
      return (key: key, phase: phase, job: map.remove(key)!.job);
    }
    for (final (map, phase) in [
      (_raster, RenderPhase.raster),
      (_symbols, RenderPhase.symbols),
    ]) {
      final best = _best(map);
      if (best == null) continue;
      final job = map.remove(best.key)!.job;
      return (key: best.key, phase: phase, job: job);
    }
    return null;
  }

  /// The key with the lowest priority in [map], a resumed job first
  /// among equals, or null when the map is empty.
  ({T key, int priority})? _best(Map<T, _Entry<J>> map) {
    T? bestKey;
    _Entry<J>? best;
    map.forEach((key, entry) {
      if (best == null ||
          entry.priority < best!.priority ||
          (entry.priority == best!.priority &&
              entry.resumed &&
              !best!.resumed)) {
        bestKey = key;
        best = entry;
      }
    });
    return best == null ? null : (key: bestKey as T, priority: best!.priority);
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

typedef _Entry<J> = ({int priority, bool resumed, J job});
