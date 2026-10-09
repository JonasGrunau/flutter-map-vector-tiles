# flutter_map_vector_tiles vs vector_map_tiles

One Flutter app that renders the same OpenFreeMap style with
[`flutter_map_vector_tiles`](https://pub.dev/packages/flutter_map_vector_tiles)
and with [`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles)
`9.0.0-beta.13`, drives both along the same scripted camera paths, and
measures what a user would see. It is two things:

- **A benchmark** you can run on your own devices. The latest numbers and
  screenshots are in [RESULTS.md](RESULTS.md).
- **A web demo**, built from `main` by CI:
  <https://jonasgrunau.github.io/flutter-map-vector-tiles/>. Switch
  packages, play the benchmark's camera paths, watch the frame readout,
  compare the two side by side, or run the benchmark in your browser.

It is not published to pub.dev and the package does not depend on it.

## Which vector_map_tiles

`9.0.0-beta.13`, the newest release that supports flutter_map 8 on stable
Flutter. The stable `8.0.0` requires flutter_map 7. The `10.0.0` betas
render with `flutter_gpu`, which needs Flutter's main channel and the
`--enable-flutter-gpu` flag, and has no web support; they are not
comparable on the same Flutter release, so they are not included.

## The arms

Every run measures exactly one arm, in a fresh process.

| arm | configuration |
|---|---|
| `fmvt` | `flutter_map_vector_tiles` at its defaults |
| `vmt-raster` | `vector_map_tiles` at its defaults (raster mode) plus `maximumZoom: 22`, without which its layer goes blank past z18 |
| `vmt-vector` | `vector_map_tiles` in vector mode, which its docs recommend for sharpness |
| `fmvt-none` | control: `flutter_map_vector_tiles` with `TileOffset.none` |

The control arm exists because the two packages do not draw the same map
at the same camera. `flutter_map_vector_tiles` evaluates a 512 px style
at flutter_map zoom − 1, as MapLibre does; `vector_map_tiles` evaluates it
at the flutter_map zoom, one level deeper, so it opens label layers a
level early and draws more of them (compare the screenshots in
RESULTS.md with MapLibre's). `TileOffset.none` makes this package do the
same, so the gap between `fmvt` and `fmvt-none` is the cost of that extra
content, not of either renderer.

## Method

- **Same tiles, same latency.** `tool/lab_server.dart` proxies OpenFreeMap
  and records every response into `.lab-cache/` on first use; every later
  run replays it, so both packages read identical bytes over loopback (or
  USB, via `adb reverse`). That also pins OpenFreeMap's dated tileset.
  `--offline` refuses anything not recorded.
- **Fresh process, empty caches.** The app asks the lab server which arm to
  run (`GET /_next`), measures it and exits. Each run gets new disk-cache
  directories (on web, `vector_map_tiles`' IndexedDB is deleted and the
  browser context is new). Arms rotate their order every round, so thermal
  drift cannot favour one.
- **Scripted camera paths**, driven by elapsed time, not by frame count:
  a janky arm covers the same ground in fewer frames. Each path runs over
  its own dense city, first cold (tiles never loaded in this process),
  then warm (the immediate repeat):

  | scenario | path |
  |---|---|
  | `zoom` | z14 → z18 → z14 over Munich, 16 s, linear in zoom; spans Liberty's POI label gates for both packages |
  | `pan` | 3000 px east at z16 over Berlin, 10 s |
  | `rotate` | 360° at z16 over Paris, 10 s |
  | `fling` | z15 ↔ z17 over London, four eased round trips, 8 s |

- **Frames delivered** is the headline metric: the share of display
  refreshes that got a frame while the camera moved, from the engine's
  vsync timestamp of every frame. It counts every kind of stall: slow
  builds, slow rasterization, and work scheduled *between* frames (an
  image decode, a PNG encode, a microtask chain), which never shows up in
  `FrameTiming`'s build or raster durations at all. Those durations are
  reported too, to explain a drop; a stall is a gap over 50 ms.
- **Settle** is the time from the camera stopping to the last repaint —
  how long tiles and labels keep arriving and fading after motion.
  Settled means no frame for 1.5 s and no tile request in flight.
- **Fidelity screenshots** at fixed cameras, next to MapLibre GL JS
  rendering the same style from the same tiles (`tool/reference_shots.mjs`).
- Any pass during which the app was not `resumed` (focus lost, screen
  locked) is flagged `interrupted` and reported as such.

## Running it

Each script builds the app in profile mode, starts the lab server, runs
the queue and leaves the raw results in `results/raw/<date>-<platform>/`.
The platform scaffolds are generated on first use and not checked in.

```sh
cd compare
./tool/run_android.sh <adb serial> 3     # USB; keep the phone unlocked
./tool/run_macos.sh 3                    # keep the window in front
./tool/run_web.sh 3                      # headed Chrome via Playwright
dart run tool/summarize.dart results/raw/<session>   # → Markdown tables
```

Extra arguments go to the lab server: `--arms fmvt,vmt-raster`,
`--scenarios zoom,rotate`, `--offline`, `--latency-ms 50` (adds a fixed
delay to every tile, to emulate a network).

**Profile mode on real hardware, and hands off.** A Mac or browser window
that loses focus is `inactive`, and a pass that ran unfocused measures the
platform's throttling, not the packages. iOS needs a real device too
(simulators cannot run profile mode); that is not scripted yet.

## Reading the numbers

- Compare arms within one session only. Each session records its device,
  display refresh rate, Flutter version, viewport, device pixel ratio and
  commit.
- `vector_map_tiles` rasterizes every tile at a fixed 512 px (2×), this
  package at 256 px × the device pixel ratio. On a dpr-2.6 phone this
  package therefore rasterizes ~1.7× the pixels per tile and its geometry
  is sharper for it.
- The two draw different label sets (see above), and different features:
  `vector_map_tiles` 9 draws Liberty's dashed lines solid, drops road
  shields and one-way arrows, and has no cross-tile label collision.
  Frame numbers compare what each package actually does with the same
  style; the screenshots show what that is.

## Files

| file | |
|---|---|
| `lib/main.dart` | entry point: lab run, in-browser benchmark, results page or demo |
| `lib/src/arms.dart` | the four configurations |
| `lib/src/scenarios.dart` | camera paths and screenshot cameras |
| `lib/src/metrics.dart` | frame log, pacing and timing statistics |
| `lib/src/bench_page.dart` | one measured run |
| `lib/src/demo_page.dart`, `results_page.dart` | the web demo |
| `tool/lab_server.dart` | record/replay proxy, run queue, results sink |
| `tool/run_*.sh`, `run_web.mjs` | per-platform drivers |
| `tool/summarize.dart` | raw results → RESULTS.md tables |
| `tool/reference_shots.mjs`, `maplibre.html` | MapLibre reference renders |
