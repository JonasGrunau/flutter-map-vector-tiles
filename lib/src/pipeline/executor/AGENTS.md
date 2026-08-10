<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-09 | Updated: 2026-08-09 -->

# executor

## Purpose

Runs tile preparation off the UI thread where the platform allows, behind one
interface with two platform implementations selected by conditional import.
This is the package's only platform-conditional code.

## Key Files

| File | Description |
|------|-------------|
| `executor.dart` | `abstract class TilePrepareExecutor` — the contract, plus the factory redirect `factory TilePrepareExecutor({int concurrency}) = impl.PlatformExecutor` wired through a conditional import |
| `isolate_executor.dart` | Native `PlatformExecutor`: a pool of long-lived worker isolates (default concurrency 3) with a priority queue, `_Worker` spawn/ready/idle/exit lifecycle, worker replacement on death, and a sticky inline fallback when no worker can be spawned |
| `direct_executor.dart` | Web `PlatformExecutor`: no isolate support for this workload, so jobs run chunked on the event loop (default concurrency 2) |

## For AI Agents

### Working In This Directory

- **Both implementations must export the same class name** (`PlatformExecutor`)
  with the same constructor shape — the conditional import in `executor.dart`
  binds by name. Renaming one and not the other breaks only the other platform's
  build, which nothing here will catch locally.
- **Priority is viewport-centre-first.** Jobs carry a priority computed by
  `GridLayout.priorityOf`; the queue must remain a priority queue, not FIFO, or
  tiles under the user's thumb load last.
- **Cancellation is silent.** A cancelled job completes with a discarded result
  and never surfaces an exception — the pool must not `completeError` on
  cancellation.
- `_Worker.spawn` may fail (constrained devices, spawn errors). The
  `onReady(null)` path releases the pool slot and — once no worker is alive —
  flips the executor into *sticky* inline mode, so jobs enqueued after the
  first drain still run. Keep both halves alive when touching the pool, or the
  map silently stops loading tiles.
- Workers carry an `onExit` port: an isolate killed underneath the executor
  (OS kill, OOM) fails its in-flight job with a null result, leaves the pool
  and is replaced on the next dispatch — never a permanently busy ghost.
- `dispose()` must kill isolates *and* drain pending jobs, otherwise closing a
  map leaks an isolate per open.

### Testing Requirements

`test/executor_test.dart` covers the contract: ordering by priority, silent
cancellation, and disposal. Test against the interface, not a concrete
implementation, so both platforms stay honest.

### Common Patterns

- Long-lived workers with a ready/idle callback pair rather than one isolate
  per job — spawn cost dominates decode cost for small tiles.

## Dependencies

### Internal

- `pipeline/tile_processor.dart` (the job payload and the function run),
  `core/cancellation.dart`

### External

- `dart:isolate` (native only), `dart:async`

<!-- MANUAL: -->
