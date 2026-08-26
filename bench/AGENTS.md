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
| `lib/main.dart` | The whole harness: an `AnimationController`-driven zoom sweep across a configurable band, `SchedulerBinding.addTimingsCallback` recording per-frame build and raster durations, and a phase matrix of (sweep speed × `showLabels` × `rasterCacheMaxBytes` × cold/warm). Each phase clears the caches; warm arms then re-warm with two slow sweeps, while the `cold` arm measures the first sweeps directly — the decode/rasterize/shaping costs the warm arms exclude. `BENCH_MODE=manual` swaps the driver for the user's fingers: gestures on, windowed reports every 5 s, and a `JANK z=… build=… raster=…` line for every frame past the 60 Hz budget. `BENCH_MODE=stability` measures label steadiness instead of frame time: four slow *monotonic* sweeps (cold in/out, warm in/out — one-way so a zoom gate fires at most once and every blink is a genuine placement flip-flop), each reporting a `STABILITY` line of pop-ins (appeared at full opacity), pop-outs (vanished from full opacity with no ghost) and blinks (left and returned to the same spot inside 4 s), split point vs along-line, from `LabelPainter.debugDrawnProbe` records matched frame-to-frame in zoom-20 world space; manual mode appends the same line per window. Reports carry a `WORK` line (UI-thread time split into rasterize / symbol layout / label paint, from the `debug*Micros` accumulators in `src/render/`), a `LABELS-SPLIT` line breaking the label paint down further (full placement passes and their count, replay frames, the per-frame candidate sort — which on placing frames also carries the incumbent flagging — paragraph shaping, the fade sweep, and drawing), a `LAYERS` line (rasterize time per style layer, worst first), and per-frame `WORK z=… tiles=N …` lines whenever one frame's publish work alone exceeds 6 ms. `BENCH_SETUP=safenow` mirrors the SafeNow app's layer wiring (no raster sources, 16 MiB memory cache, 150 MiB disk cache, zoom 2–21); its style URL and key pass through `run.sh` from the environment and are never committed |
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
