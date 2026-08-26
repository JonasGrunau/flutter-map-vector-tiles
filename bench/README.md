# bench

A frame-timing harness for zoom crossings. It drives scripted zoom sweeps on a
real device and reports UI-thread and raster-thread frame times, plus how much
work the caches avoided.

It exists because the interesting costs in this package are invisible to unit
tests and to `flutter test`: they are frame-time distributions on real hardware,
under a real style, at the zoom band where a style turns its labels on.

## Running it

```sh
flutter devices                      # find your device id
./run.sh 00008130-000…401C before    # baseline
# …change something…
./run.sh 00008130-000…401C after     # compare
```

`run.sh` generates the iOS scaffold on first use (it is not checked in),
launches in profile mode, waits for the run to finish, prints the `BENCH[…]`
lines and kills the app.

**Profile mode is mandatory.** Debug distorts the UI thread badly enough to be
useless, and iOS simulators cannot run profile at all — nor do they reproduce
GPU-bound costs, because the host GPU is far too fast. A simulator run of this
harness once reported a perfectly smooth map for a device that was visibly
stuttering.

**Keep the screen awake.** iOS auto-lock mid-run parks the render pump and the
numbers become fiction. After `flutter create` generates `ios/`, add to
`ios/Runner/AppDelegate.swift`, in `application(_:didFinishLaunchingWithOptions:)`:

```swift
application.isIdleTimerDisabled = true
```

Every phase also reports `interrupted=` — if that says `true`, throw the run
away.

## Profiling by hand (manual mode)

The scripted sweep is for A/B numbers; some stutters only show up under a real
pinch. `BENCH_MODE=manual` enables gestures and turns the harness into a
passive recorder:

```sh
flutter run --profile -d <device> --dart-define=BENCH_MODE=manual
```

You zoom; it prints a `BENCH[…]` report for every 5-second window that
produced frames (same format as the phase reports, with the zoom band the
window covered), and an immediate line for every frame over the 60 Hz budget,
tagged with the zoom it happened at:

```
BENCH[run] JANK z=16.98 build=24.3ms raster=3.1ms
```

`layouts`/`rasterizes` are per-window deltas, so zero still means "served
entirely from cache". The overlay shows the live zoom, so you can see a
threshold (say Liberty's z17 POI gate) coming before you cross it. Windows
where the screen was untouched print nothing.

## Counting flicker (stability mode)

Frame times can be perfect while the labels are ugly: a label that pops in
at full opacity, vanishes without a fade, or drops out and returns half a
zoom level later costs no milliseconds. `BENCH_MODE=stability` measures
exactly that: four slow monotonic sweeps across the band (cold in/out, then
warm in/out), ~16 s each, with a `STABILITY` line per sweep:

```
BENCH[run] STABILITY cold-in z=15.0..17.5 frames=2158 seen/frame=79 · \
  pt popIn=13 popOut=91 blink=36 appear=146 gone=177 · ln popIn=7 …
```

`pt`/`ln` split point labels from along-line ones. `popIn` counts labels
appearing at full opacity (a skipped fade-in), `popOut` full-opacity labels
vanishing with no ghost behind them, `blink` labels disappearing and
returning at the same spot within a few seconds — the
visible→hidden→visible twitch. `appear`/`gone` are all appearances and
disappearances, for rates. Monotonic sweeps are the point: a zoom gate
fires at most once per direction, so every blink is a genuine placement
flip-flop rather than the style re-crossing its thresholds. Labels are
matched frame-to-frame in zoom-20 world space (48 px continuation radius,
64 px blink radius, 4 s blink window) from a painter probe
(`LabelPainter.debugDrawnProbe`) that costs one skipped null-check outside
this mode and `manual` mode — which appends the same `STABILITY` line to
each of its windows.

## Reading the output

```
BENCH[after] --- 150ms labels=true cache=AUTO --- window=8.0s fps=120.1 \
  layouts=0 rasterizes=0 interrupted=false
BENCH[after]   BUILD  n=961 p50=1.63 p90=2.65 p99=6.77 max=7.27 >8.3=0 (0.0%) …
BENCH[after]   RASTER n=961 p50=0.80 p90=1.08 p99=1.67 max=4.76 >8.3=0 (0.0%) …
```

| field | what it means |
|---|---|
| `BUILD` | UI thread. Tile rasterization, symbol layout and text shaping all land here — the render pump runs on this thread. |
| `RASTER` | GPU thread. `saveLayer` costs show up here and **nowhere else**: a `saveLayer` only records an op during picture recording, so no Dart-side stopwatch can see it. |
| `layouts` / `rasterizes` | Symbol extractions and tile rasterizations during the window. **Zero means the crossing was served entirely from the finished-tile cache** — the single clearest signal that caching is working. |
| `WORK` | The window's publish work split into UI-thread wall time: `rasterize` (picture recording + `toImageSync`), `layout` (symbol extraction), `labels` (the per-frame label pass). Whatever BUILD holds beyond these three is flutter_map and widget overhead. A per-frame `WORK z=… tiles=N …` line fires whenever a single frame's split alone exceeds 6 ms — that is the attribution for an adjacent `JANK` line. |
| `LAYERS` | The same rasterize time broken down by style layer id, worst first — names the culprit layer directly. |
| `>8.3` / `>16.7` | Frames over the 120 Hz and 60 Hz budgets. On a ProMotion device the 8.3 ms column is the one that matters; clearing 16.7 there is not "smooth". |
| `fps` | Frames actually produced. Pinned at ~120 (or ~60) means nothing is stalling. |

## Aiming it at the right zoom band

**This is the step that is easy to get wrong, and getting it wrong produces
confident, meaningless numbers.** A style does not load its labels evenly: it
gates them, and the interesting frames are the ones right after a gate opens.
OpenFreeMap Liberty, the default here:

| layer | minzoom | admits |
|---|---|---|
| `poi_transit` | none | bus/rail stops |
| `poi_r1` | 15 | rank 1–6 |
| `poi_r7` | 16 | rank 7–19 |
| `poi_r20` | **17** | rank ≥20 — the long tail, i.e. most POIs |

So the default sweep is z16.3 ↔ z17.7, straddling z17. A sweep across z14 shows
street names and transit stops only, and will tell you everything is fine.

For another style, read its POI layers' `minzoom` values first, then set the
band:

```sh
./run.sh <device> after 154 166      # z15.4 <-> z16.6
```

Confirm visually before trusting a number — park the map and look at it:

```sh
flutter run --profile -d <device> \
  --dart-define=BENCH_MODE=idle --dart-define=BENCH_ZOOM10=170
xcrun simctl io booted screenshot /tmp/z17.png   # or screenshot the device
```

If you cannot see shop and restaurant labels, the harness is not measuring what
you think it is.

## Configuration

All via `--dart-define`. Zooms and coordinates are integers because
`double.fromEnvironment` does not exist.

| define | default | meaning |
|---|---|---|
| `STYLE_URL` | OpenFreeMap Liberty | any MapLibre style URL; `{key}` is substituted |
| `MAPTILER_KEY` | — | key for `{key}` |
| `BENCH_LABEL` | `run` | tag for the log lines, so two runs can be diffed |
| `BENCH_LO` / `BENCH_HI` | `163` / `177` | sweep bounds in tenths of a zoom level |
| `BENCH_LAT_E5` / `BENCH_LON_E5` | Munich centre | centre, in 1e-5 degrees |
| `BENCH_MODE` | `bench` | `idle` parks the map at `BENCH_ZOOM10` for inspection; `manual` enables gestures and reports windows + per-jank lines while you drive; `stability` runs four slow monotonic sweeps and counts label pop-ins/pop-outs/blinks (see below) |
| `BENCH_SETUP` | `default` | `safenow` mirrors the SafeNow app's layer wiring: no raster sources, 16 MiB memory cache, 150 MiB disk cache, zoom 2–21, the app's gesture set in manual mode. Combine with that app's `STYLE_URL`/`MAPTILER_KEY` — keys are passed per invocation and never committed |
| `BENCH_ZOOM10` | `170` | idle-mode zoom, in tenths |

The phase matrix (speed × labels on/off × cache budget × cold/warm) is the
`_phases` list in `lib/main.dart`. The labels-off arm is a control, not filler:
if the label pipeline is what costs, turning it off at the same speed has to
flatten the profile — and if it does not, the cost is somewhere else and the
rest of the run is a distraction. The `cold` arm skips the warm-up sweeps and
records the *first* crossings after the caches are cleared, so decode,
rasterization and text shaping all land inside the measurement window — that is
the crossing a user feels first, and the warmed arms deliberately exclude it
(its `layouts`/`rasterizes` counters are expected to be non-zero; the disk
cache still serves the bytes, so it measures compute, not the network).

## A/B'ing a change

The bench depends on the parent package by path, so it picks up the working
tree. To compare against `main`:

```sh
./run.sh <device> after
git stash push lib/          # or: git checkout main -- lib/
./run.sh <device> before
git stash pop
```

Run the arms back to back — thermal state drifts, so a baseline taken an hour
earlier is not a baseline.
