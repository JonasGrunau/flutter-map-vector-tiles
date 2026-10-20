<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-10-09 | Updated: 2026-10-20 -->

# compare

## Purpose

The head-to-head with `vector_map_tiles` 9.0.0-beta.13 that
fleaflet/flutter_map#2272 asked for: one app that is both a benchmark run on
real devices (driven by a local record/replay lab server) and the web demo
CI deploys to GitHub Pages. `bench/` answers "did this change make *this*
package faster"; `compare/` answers "how does it compare to the other one",
so it measures only what both packages expose and nothing internal.

Excluded from the published package (`.pubignore`).

## Key Files

| File | Description |
|------|-------------|
| `lib/main.dart` | Entry: a lab run when `LAB` is set (dart-define, or on web a `?lab=` naming the page's own origin), else the demo, the in-browser benchmark (`?mode=bench`) or its results page (`?mode=results`) |
| `lib/src/config.dart` | `Config`: the start-up settings (`lab`, `arm`, `mode`, `style`, `device`), from the page URL on web and from `--dart-define` natively |
| `lib/src/arms.dart` | `Arm` (`fmvt`, `fmvt-none`, `fmvt-raster`, `fmvt-raster-none`, `vmt-raster`, `vmt-vector`) and `loadArm`, which reads the style with that package's own reader and builds its layer. `Arm.parse` throws on an unknown id (a measured run then records an error row); the demo's URL goes through the lenient `Arm.tryParse`. `vector_map_tiles`' `cacheFolder` has a per-platform type — hence the analyzer `ignore` and the `vmtCacheFolder` shim |
| `lib/src/scenarios.dart` | The four camera paths (each over its own city, as a function of time) and `shotPoses`, the fidelity cameras — mirrored in `tool/reference_shots.mjs` |
| `lib/src/metrics.dart` | `FrameLog`: engine vsync timestamps per frame (pacing) plus `FrameTiming` matched to the same window; `FrameStats` (nearest-rank percentiles), `RssSampler` |
| `lib/src/bench_page.dart` | One measured run: calibrate refresh, take a run from the lab queue, open → settle, each scenario cold then warm, a `net` row with the run's whole traffic, screenshots in round 0, exit. Also the reload-per-arm in-browser benchmark, whose warm-up fills the HTTP cache with both packages' tile zooms (`fmvt`, then `fmvt-none`) |
| `lib/src/demo_page.dart`, `results_page.dart` | The web demo: one package per page load, live readout, "Play" paths, side-by-side, benchmark buttons and the results table |
| `lib/src/lab.dart` | Client for the lab server; `log` names its run, which keeps the run alive for the inactivity timeout |
| `lib/src/platform/` | `host_io.dart` / `host_web.dart`: fresh cache dirs, RSS, IndexedDB reset, exit, localStorage |
| `tool/lab_server.dart` | dart:io only. Listens on loopback, plus the one address `--bind` names (`run_ios.sh` passes the Mac's end of the iPhone's USB link). Record/replay proxy for `tiles.openfreemap.org` (`/r/<run>/ofm/…`, rewriting style.json/TileJSON URLs back to itself; upstream errors pass through uncached), run queue in balanced order (`_roundOrder`: rounds in mirrored pairs), per-run request/byte/in-flight counters, results and screenshot sink, static serving of a web build at `/app/`. Refuses an existing session directory; gives up a run nothing was heard of for `--run-timeout` s (120) with an error row. CORS headers on the proxied paths only, for `maplibre.html` |
| `tool/run_android.sh`, `run_ios.sh`, `run_macos.sh`, `run_web.sh` (+ `run_web.mjs`), `common.sh` | Build once in profile mode, start the lab, launch the app until the queue is empty. `run_ios.sh` launches through `devicectl --console`, which waits for the app to exit. `common.sh` generates and patches the scaffolds, refuses a taken port, and installs the EXIT/INT/TERM traps that run its `CLEANUP` steps (stop the lab; on Android also put the phone's settings back) |
| `tool/gpu_sampler.sh`, `gpu_memory.py` | Android GPU memory: `run_android.sh` starts the sampler for every session (`dumpsys gpu --gpumem` every ~3 s into the session's `gpu-memory.txt`, so every Android session carries the same load), and `gpu_memory.py` turns the samples into RESULTS.md's GPU table. iOS has no counterpart |
| `tool/summarize.dart` | `results/raw/<session>/results.jsonl` → the Markdown tables in `RESULTS.md` (medians over rounds, ranges for the headline column, timeouts counted as the longest). Warns on mixed viewports, mixed commits and duplicate rows |
| `tool/reference_shots.mjs`, `maplibre.html` | MapLibre GL JS renders of the fidelity cameras, through the lab |
| `tool/fidelity.py` | A session's raw screenshots → `results/shots/<session>/*.webp` and the Markdown grid in `RESULTS.md` (needs Pillow with WebP) |
| `SUMMARY.md` | The results in plain words, for readers who will not read RESULTS.md: what was compared, how to read frames delivered, the four-platform table, where `vector_map_tiles` is ahead, fidelity, limits. Every number in it comes from RESULTS.md; update the two together |
| `pubspec.lock` | Checked in, unlike the package's: it pins what `vector_map_tiles` renders with (`vector_tile_renderer`, `executor_lib`), not only `vector_map_tiles` itself |
| `RESULTS.md`, `results/` | Published numbers and processed screenshots; `results/raw/*/results.jsonl` are the raw data behind them (plus `lab-runs.txt`, the lab server's whole-run counts, where a session predates the `net` row and its log survived) |

## For AI Agents

### Working In This Directory

- **Only public API, from both packages.** No `src/` imports from either
  side: a number that needs an internal counter cannot be produced for the
  other package, so it does not belong here (it belongs in `bench/`).
- **Frames delivered is the metric that cannot be gamed.** It is computed
  from the vsync timestamp of every frame while a camera path animates.
  Build/raster durations miss work done between frames — exactly where
  `vector_map_tiles` raster mode does its PNG encoding and where the web
  queue executor runs — so never report them alone.
- **Prove the run measured a map.** Check the screenshots of a new session
  before reading its numbers. The first macOS smoke run here rendered only
  the background colour for `fmvt` (an unfocused window was `inactive`,
  which the layer then treated as backgrounded — fixed in the package) and
  its frame times looked superb. A pass flagged `interrupted` is not data.
- **"Settled" must outlast every package's silent work.** `_settle` waits
  for a quiet window with no frame. `vector_map_tiles` renders and
  PNG-encodes tiles between frames and went 1.75 s without one on the
  Nothing Phone; the 1.5 s window used until 2026-10-12 shot its z14 screen
  half-empty and started its cold passes with the previous view still
  rendering. The window is now 4 s. On a slower device, check that a
  screenshot taken a few seconds later shows nothing new before trusting it.
- **Arms pair up by label strategy, not by default.** `fmvt-raster` ↔
  `vmt-raster` (labels baked into the tiles), `fmvt` ↔ `vmt-vector`
  (labels drawn per frame); `fmvt-none` and `fmvt-raster-none` are the
  content controls, drawing what `vector_map_tiles` draws. Report a
  package-vs-package number from a pair, never across strategies.
- **Fairness choices are written down in README.md "The arms".** Changing
  an arm's configuration changes what the results mean; update README.md,
  RESULTS.md and the root README's comparison section with it.
- **Keep `shotPoses` and `reference_shots.mjs` in sync**, and remember
  MapLibre's zoom is one lower and its bearing has the opposite sign.
- **Platform scaffolds are generated, not checked in** (except `web/`, which
  CI builds). `common.sh` patches them: macOS network entitlement, arm64
  only and deployment target 12.0 (Xcode 27), Android cleartext to the lab;
  on iOS portrait only, the local-network prompt's text, the idle timer off
  in `AppDelegate.swift`, deployment target 15.0 (Xcode 27) and
  `DEVELOPMENT_TEAM` from `IOS_TEAM`. `flutter create` also drops
  `analysis_options.yaml` and `test/`; both are deleted and gitignored. It
  also overwrites `pubspec.lock`, so `scaffold` puts the checked-in one
  back; otherwise the next `pub get` would pick `vector_map_tiles`'
  renderer packages anew.
- **Never commit the lab cache** (`.lab-cache/`, tiles under OpenFreeMap's
  terms) or raw screenshots; processed WebP shots go in `results/shots/`.
- **One session per directory, an even number of rounds.** The lab server
  will not append to an existing `results.jsonl`; name a second same-day
  session with `--session`. The arm order is balanced over pairs of
  rounds only, hence the scripts' default of 4.
- **Requests per run come from the `net` row.** Pass rows count only
  their own motion and settle. Sessions recorded before 2026-10-13 have
  no `net` row, and their request figures are labelled as covering the
  opening and the measured passes only.
- **Changing the root package's dependencies?** Re-run
  `flutter pub get --directory compare` and commit the updated
  `compare/pubspec.lock`.

### Testing Requirements

`flutter analyze` at the repo root covers this directory (CI runs
`flutter pub get --directory compare` first). `.github/workflows/demo.yml`
builds the web demo on every PR that touches `lib/` or `compare/`.

### Common Patterns

- Settings come from `--dart-define` natively and from the URL query on
  web (`config.dart`), so the demo switches packages by reloading. A
  `?lab=` counts only when it is the page's own origin, which a real lab
  always is (it serves the app at `/app/`); anything else is ignored, so
  a link to the public demo cannot point it at someone else's server.
- Every arm switch in the demo is a page load: two packages in one process
  would share an isolate pool, image cache and frame budget.

## Dependencies

### Internal

- The parent package by path, through the public barrel only

### External

- `vector_map_tiles` 9.0.0-beta.13 (pinned exactly in `pubspec.yaml`, its
  renderer `vector_tile_renderer` 6.1.0 and `executor_lib` 1.1.2 by the
  checked-in `pubspec.lock`), `flutter_map`, `latlong2`, `http`, `web`
- Node + Playwright (`tool/node_modules`, installed on first web run) for
  the Chrome runs and MapLibre reference shots

<!-- MANUAL: -->
