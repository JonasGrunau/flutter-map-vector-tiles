import 'package:flutter_map_vector_tiles/src/grid/render_job_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pop is phase-major: all rasters before any symbol job', () {
    final dropped = <String>[];
    final queue = RenderJobQueue<String, String>(onDrop: dropped.add);
    queue.enqueueRaster('a', 5, 'raster-a');
    queue.enqueueSymbols('b', 0, 'symbols-b');
    queue.enqueueRaster('c', 1, 'raster-c');

    expect(queue.pop()!.job, 'raster-c'); // lowest raster priority first
    expect(queue.pop()!.job, 'raster-a');
    final last = queue.pop()!;
    expect(last.phase, RenderPhase.symbols);
    expect(last.job, 'symbols-b');
    expect(queue.isEmpty, isTrue);
    expect(dropped, isEmpty);
  });

  test('tile-major pop finishes the most central tile first', () {
    // LabelMode.tile: a tile shows only once both phases ran, so the
    // centre tile's symbols must not wait behind every other raster.
    final queue = RenderJobQueue<String, String>(onDrop: (_) {});
    queue.enqueueRaster('far', 5, 'raster-far');
    queue.enqueueRaster('centre', 0, 'raster-centre');
    queue.enqueueRaster('near', 1, 'raster-near');
    expect(queue.pop(tileMajor: true)!.job, 'raster-centre');
    // What the pump does after a raster: queue the tile's symbol phase
    // at the same priority.
    queue.enqueueSymbols('centre', 0, 'symbols-centre');
    final next = queue.pop(tileMajor: true)!;
    expect(next.phase, RenderPhase.symbols);
    expect(next.job, 'symbols-centre');
    expect(queue.pop(tileMajor: true)!.job, 'raster-near');

    // Ties go to the symbols phase: a started tile is finished first.
    queue.enqueueSymbols('near', 1, 'symbols-near');
    queue.enqueueRaster('other', 1, 'raster-other');
    expect(queue.pop(tileMajor: true)!.job, 'symbols-near');
    expect(queue.pop(tileMajor: true)!.job, 'raster-other');
    expect(queue.pop(tileMajor: true)!.job, 'raster-far');
    expect(queue.pop(tileMajor: true), isNull);
  });

  test('within a phase, lower priority pops first', () {
    final queue = RenderJobQueue<String, String>(onDrop: (_) {});
    queue.enqueueSymbols('far', 9, 's-far');
    queue.enqueueSymbols('near', 1, 's-near');
    queue.enqueueSymbols('mid', 4, 's-mid');
    expect(queue.pop()!.job, 's-near');
    expect(queue.pop()!.job, 's-mid');
    expect(queue.pop()!.job, 's-far');
  });

  test('a new raster job replaces the tile\'s pending raster job', () {
    final dropped = <String>[];
    final queue = RenderJobQueue<String, String>(onDrop: dropped.add);
    queue.enqueueRaster('a', 3, 'old');
    queue.enqueueRaster('a', 3, 'new');
    expect(dropped, ['old']);
    expect(queue.pop()!.job, 'new');
    expect(queue.isEmpty, isTrue);
  });

  test('an accepted raster job supersedes the tile\'s pending symbols', () {
    final dropped = <String>[];
    final queue = RenderJobQueue<String, String>(onDrop: dropped.add);
    queue.enqueueSymbols('a', 3, 'stale-symbols');
    queue.enqueueRaster('a', 3, 'raster');
    expect(dropped, ['stale-symbols'],
        reason: 'the raster re-enqueues its own symbol job when it runs');
    expect(queue.pop()!.job, 'raster');
    expect(queue.isEmpty, isTrue);
  });

  test('pendingRaster exposes the queued raster job for policy checks', () {
    final queue = RenderJobQueue<String, String>(onDrop: (_) {});
    expect(queue.pendingRaster('a'), isNull);
    queue.enqueueRaster('a', 0, 'raster');
    queue.enqueueSymbols('a', 0, 'symbols');
    expect(queue.pendingRaster('a'), 'raster');
  });

  test('remove drops both phases, clear drops everything', () {
    final dropped = <String>[];
    final queue = RenderJobQueue<String, String>(onDrop: dropped.add);
    queue.enqueueRaster('a', 0, 'raster-a');
    // A tile can hold one job per phase at the same time.
    queue.enqueueSymbols('b', 0, 'symbols-b');
    queue.enqueueSymbols('a', 0, 'symbols-a');
    expect(dropped, isEmpty);

    queue.remove('a');
    expect(dropped, unorderedEquals(['raster-a', 'symbols-a']));
    expect(queue.length, 1);

    dropped.clear();
    queue.clear();
    expect(dropped, ['symbols-b']);
    expect(queue.isEmpty, isTrue);
  });
}
