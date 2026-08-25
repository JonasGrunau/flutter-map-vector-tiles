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
| `BENCH_MODE` | `bench` | `idle` parks the map at `BENCH_ZOOM10` for inspection |
| `BENCH_ZOOM10` | `170` | idle-mode zoom, in tenths |

The phase matrix (speed × labels on/off × cache budget) is the `_phases` list in
`lib/main.dart`. The labels-off arm is a control, not filler: if the label
pipeline is what costs, turning it off at the same speed has to flatten the
profile — and if it does not, the cost is somewhere else and the rest of the run
is a distraction.

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
