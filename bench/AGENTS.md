<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-25 | Updated: 2026-08-25 -->

# bench

## Purpose

An on-device frame-timing harness for zoom crossings. It exists because this
package's interesting costs cannot be seen from `flutter test`: they are
frame-time *distributions*, on real hardware, under a real style, at the zoom
band where that style turns its labels on. A microbenchmark in `test/` measures
Dart-side work; this measures what the user feels.

Excluded from the published package (`.pubignore`), so it costs pub.dev nothing.

## Key Files

| File | Description |
|------|-------------|
| `lib/main.dart` | The whole harness: an `AnimationController`-driven zoom sweep across a configurable band, `SchedulerBinding.addTimingsCallback` recording per-frame build and raster durations, and a phase matrix of (sweep speed × `showLabels` × `rasterCacheMaxBytes` × cold/warm). Each phase clears the caches; warm arms then re-warm with two slow sweeps, while the `cold` arm measures the first sweeps directly — the decode/rasterize/shaping costs the warm arms exclude |
| `test/anchor_continuity_test.dart` | Investigation evidence, not a regression gate: quantifies how far along-line anchors move across a zoom crossing (same continuity key, ~half the `symbol-spacing` for a straight street) — the mechanism behind the pre-fix street-name jumps, kept runnable so the numbers stay reproducible. In this gitignored `test/` dir on purpose; run with `flutter test` from `bench/` |
| `README.md` | How to run it, how to read the output, and how to aim it at the right zoom band |
| `run.sh` | Generates the iOS scaffold if absent, launches in profile mode, waits for the run, prints the `BENCH[…]` lines, kills the app |
| `pubspec.yaml` | Depends on the parent package by path, so it measures the working tree |

Platform scaffolds are **not** checked in — `run.sh` runs
`flutter create --platforms=ios .` on first use, then deletes the two
files that generation also drops: an `analysis_options.yaml` that would
override the repo lints, and a default `test/widget_test.dart` that
references a `MyApp` this harness has no such class for. Both are
gitignored, but `flutter analyze` at the repo root still reads them, so
leaving them behind reports 18 errors that have nothing to do with the
package. Delete them by hand if you ever run `flutter create` yourself.

## For AI Agents

### Working In This Directory

- **BUILD and RASTER are different threads and mixing them up wastes days.**
  Tile rasterization, symbol layout and text shaping run on the UI thread and
  land in BUILD. `saveLayer` costs land in RASTER and *nowhere else*, because a
  `saveLayer` only records an op during picture recording — no Dart-side
  stopwatch can observe it. A theory about render passes can only be confirmed
  or killed by the RASTER column.
- **Aim at a real threshold or measure nothing.** Styles gate labels by zoom,
  and the interesting frames are the ones just after a gate opens. Liberty
  holds most POIs behind `poi_r20`/z17; a sweep across z14 shows street names
  and transit stops and reports that everything is fine. Read the style's POI
  layers' `minzoom` before choosing `BENCH_LO`/`BENCH_HI`, and confirm visually
  with `BENCH_MODE=idle` plus a screenshot.
- **Sweep, never jump.** `MapController.move` to a new zoom produces roughly one
  frame per crossing; the animated sweep produces ~100. An early version jumped
  and reported a flawless map.
- **Profile mode on a real device, or don't bother.** Debug distorts the UI
  thread; iOS simulators cannot run profile at all and their host GPU is far too
  fast to reproduce GPU-bound costs. A simulator run here once reported a
  perfectly smooth map for a device that was visibly stuttering.
- **Check `interrupted=` before believing a run.** An auto-lock or a
  backgrounding parks the render pump (the layer stops rasterizing from
  `inactive` onwards) and the numbers become fiction.
- **`layouts=0 rasterizes=0` is the cache signal.** It means the crossing was
  served entirely from `TileResultCache`. Any other number means the screen was
  re-rendered.
- **Run A/B arms back to back.** Thermal state drifts; an hour-old baseline is
  not a baseline.
- **The `src/` imports here are deliberate**, unlike in `example/`. The bench is
  a development tool rather than a consumer, and `SymbolLayouter.debugLayoutCount`
  / `TileRasterizer.debugRasterizeCount` are debug counters that have no business
  in the public barrel. Do not "fix" them by adding exports.

### Testing Requirements

There is nothing to assert — the output is a distribution a human compares.
Keep it lint-clean, since `flutter analyze` at the repo root covers this
directory:

```
flutter analyze
```

### Common Patterns

- Config through `--dart-define` only, and zooms/coordinates as scaled integers,
  because `double.fromEnvironment` does not exist.
- Percentiles plus over-budget counts, never means: the whole question is the
  tail, and a mean hides it.
- Both the 8.3 ms and 16.7 ms budgets are reported — on a ProMotion device,
  clearing 16.7 ms is not "smooth".

## Dependencies

### Internal

- The parent package by path, through the public barrel plus two debug counters
  from `src/render/`

### External

- `flutter_map`, `latlong2`
