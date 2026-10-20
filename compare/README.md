# flutter_map_vector_tiles vs vector_map_tiles

One Flutter app that renders the same OpenFreeMap style with
[`flutter_map_vector_tiles`](https://pub.dev/packages/flutter_map_vector_tiles)
and with [`vector_map_tiles`](https://pub.dev/packages/vector_map_tiles)
`9.0.0-beta.13`, drives both along the same scripted camera paths, and
measures what a user would see. It is two things:

- **A benchmark** you can run on your own devices. The latest numbers and
  screenshots are in [RESULTS.md](RESULTS.md), and
  [SUMMARY.md](SUMMARY.md) explains them in plain words.
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
| `fmvt-raster` | `flutter_map_vector_tiles` with `labelMode: LabelMode.tile`: labels drawn into the tile images |
| `vmt-raster` | `vector_map_tiles` at its defaults (raster mode) plus `maximumZoom: 22`, without which its layer goes blank past z18 |
| `vmt-vector` | `vector_map_tiles` in vector mode, which its docs recommend for sharpness |
| `fmvt-none` | control: `flutter_map_vector_tiles` with `TileOffset.none` |
| `fmvt-raster-none` | control: `fmvt-raster` with `TileOffset.none` |

The packages draw labels in different ways, so the arms pair up by
strategy rather than by default. `vector_map_tiles`' raster mode bakes
labels and icons into each tile image, so a moving map costs it no label
work; `flutter_map_vector_tiles` by default draws every label every frame
in screen space (global collision, upright text under rotation), which
costs UI-thread time while the camera moves. `vector_map_tiles`' vector
mode redraws everything, geometry included, every frame. Like against
like is therefore `fmvt-raster` ↔ `vmt-raster` (labels baked into the
tiles) and `fmvt` ↔ `vmt-vector` (labels drawn per frame).

The control arm exists because the two packages do not draw the same map
at the same camera. `flutter_map_vector_tiles` evaluates a 512 px style
at flutter_map zoom − 1, as MapLibre does; `vector_map_tiles` evaluates it
at the flutter_map zoom, one level deeper, so it opens label layers a
level early and draws more of them (compare the screenshots in
RESULTS.md with MapLibre's). `TileOffset.none` makes this package do the
same, so the gap between `fmvt` and `fmvt-none` is the cost of that extra
content, not of either renderer. `fmvt-raster-none` is the same control
for the baked-label pair: it draws what `vmt-raster` draws.

## Method

- **Same tiles, same latency.** `tool/lab_server.dart` proxies OpenFreeMap
  and records every response into `.lab-cache/` on first use; every later
  run replays it, so both packages read identical bytes over loopback (or
  USB: through `adb reverse` on Android, and on iOS over the network link
  a wired iPhone also is). That also pins OpenFreeMap's dated tileset.
  `--offline` refuses anything not recorded. Replayed responses are
  cacheable, as OpenFreeMap's are, so on the web a re-request within a
  run is served by the browser's HTTP cache, which this package relies
  on there in place of a disk cache.
- **Fresh process, empty caches.** The app asks the lab server which arm to
  run (`GET /_next`), measures it and exits. Each run gets new disk-cache
  directories (on web, `vector_map_tiles`' IndexedDB is deleted and the
  browser context is new).
- **Balanced order.** Rounds come in pairs: the second of a pair runs the
  arms in the reverse of the first one's order, and each pair starts one
  arm further along. Every arm's two slots in a pair add up to the same
  number, so a drift that grows steadily over a session (the phone
  warming up, the battery draining) costs each arm the same on average
  over a pair. That holds for an even number of rounds only; an odd last
  round has no partner, which is why the scripts default to 4. It does
  not cancel a drift that comes and goes.
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
  Settled means no frame for 4 s and no tile request in flight. The
  window has to outlast the longest pause between two frames while a
  package is still working: `vector_map_tiles` renders and PNG-encodes
  tiles between frames, and went up to 1.75 s without one while filling
  a fresh screen. Sessions before 2026-10-12 used 1.5 s, which cut some of
  its work off: see RESULTS.md.
- **Fidelity screenshots** at fixed cameras, next to MapLibre GL JS
  rendering the same style from the same tiles (`tool/reference_shots.mjs`).
- Any pass during which the app was not `resumed` (focus lost, screen
  locked) is flagged `interrupted` and reported as such.

## Running it

Each script builds the app in profile mode, starts the lab server, runs
the queue and leaves the raw results in `results/raw/<date>-<platform>/`.
The platform scaffolds are generated on first use and not checked in.
`pubspec.lock` is checked in: it pins the `vector_map_tiles` renderer
packages (`vector_tile_renderer`, `executor_lib`) along with the package
itself.

```sh
cd compare
./tool/run_android.sh <adb serial> 4     # USB; keep the phone unlocked
IOS_TEAM=<team> ./tool/run_ios.sh <udid> 4   # USB; see below
./tool/run_macos.sh 4                    # keep the window in front
./tool/run_web.sh 4                      # headed Chrome via Playwright
dart run tool/summarize.dart results/raw/<session>   # → Markdown tables
```

Extra arguments go to the lab server: `--arms fmvt,vmt-raster`,
`--scenarios zoom,rotate`, `--offline`, `--latency-ms 50` (adds a fixed
delay to every tile, to emulate a network), `--session <name>`,
`--run-timeout <s>`.

- **One session, one directory.** The lab server refuses to start when
  the session's `results.jsonl` already exists, so a second session on
  the same day and platform needs its own `--session` name; it never
  appends to the first. It also refuses a port another process holds
  (a lab server left over from an earlier session, say), and a script
  stopped with Ctrl-C still stops its lab server and, on Android, puts
  the phone's settings back.
- **A crashed run is given up, not waited for.** When the lab server
  hears nothing about a running run for `--run-timeout` seconds (120 by
  default; a healthy run is never quiet for longer than one 16 s camera
  path), it writes an error row for it and moves on to the next run.

**Profile mode on real hardware, and hands off.** A Mac or browser window
that loses focus is `inactive`, and a pass that ran unfocused measures the
platform's throttling, not the packages. iOS needs a real device too
(simulators cannot run profile mode).

**An iPhone reaches the lab over its cable.** iOS has no `adb reverse`,
but a wired iPhone is also a network link: the Mac lists it as a "USB
Ethernet" interface with a 169.254 address. `run_ios.sh` builds the app
against that address and has the lab server bind it too (`--bind`), so
the tiles come over USB, as on Android, not over Wi-Fi. The first launch
asks to find devices on the local network: unlock the phone and tap
Allow. `IOS_TEAM` is the team that signs the app, read only when the
scaffold is generated; `LAB_HOST` picks the address when more than one
USB link is up. The app keeps the screen on while it runs, and the
scaffold allows portrait only.

## Reading the numbers

- Compare arms within one session only. Each session records its device,
  display refresh rate, Flutter version, viewport, device pixel ratio and
  commit; `summarize.dart` warns when a session mixes viewports or
  commits or holds a measurement twice.
- "Requests per run" counts every resource a run fetched through the lab
  server (style, TileJSON, sprites and tiles), from the style to the end
  of its last pass, before round 0's screenshots. Sessions recorded
  before 2026-10-13 lack that count; for them `summarize.dart` prints
  "requests while opening and in the measured passes", which leaves out
  the jump to each scenario's start. A settle that never came within the
  app's 25 s wait shows as "timed out" and counts as longer than any
  measured one.
- `vector_map_tiles` rasterizes every tile at a fixed 512 px (2×), this
  package at 256 px × the device pixel ratio. On a dpr-2.6 phone this
  package therefore rasterizes ~1.7× the pixels per tile and its geometry
  is sharper for it.
- The two draw different label sets (see above), and different features:
  `vector_map_tiles` 9 draws Liberty's dashed lines solid, drops road
  shields and one-way arrows, and has no cross-tile label collision.
  Frame numbers compare what each package actually does with the same
  style; the screenshots show what that is.

## Reproducing the results

Every number in RESULTS.md, and in the package README's comparison,
comes from a session under `results/raw/`, and you can measure each one
again. You need a Mac with Flutter at the version in the repository's
`.tool-versions` (each result row also records the Flutter it was built
with), Xcode for macOS and iOS, `adb` for Android, Node for Chrome, and
Python 3 with Pillow for the screenshots.

The quickest check needs none of that. The
[web demo](https://jonasgrunau.github.io/flutter-map-vector-tiles/) has
two "Benchmark" buttons, which run `fmvt`, `fmvt-raster`, `vmt-raster`
and `vmt-vector` along the same camera paths in your browser and show
the table at the end. That is one round against the live OpenFreeMap
servers, not recorded tiles, so expect its numbers to vary more than a
lab session's.

1. **Build what was measured.** Each session's `notes.md` names the
   commit it was built from, and every row of its `results.jsonl`
   carries it (`commit`), along with the device and the Flutter version.
   Check that commit out and run `flutter pub get --directory compare`.
   The checked-in `pubspec.lock` pins `vector_map_tiles` and the packages
   it renders with.
2. **Record the tiles once, then replay them.** The lab cache is not in
   the repository (the tiles are OpenFreeMap's, under its terms), so your
   first session records your own: leave out `--offline` that one time,
   then pass it to every session after, so that every platform replays
   the same bytes. The quoted sessions replayed a recording of
   OpenFreeMap's `planet/20261004_113936_pt` build. Yours holds whichever
   build OpenFreeMap serves on the day you record, so the maps can
   differ in detail.
3. **Run the sessions.**

   ```sh
   cd compare
   ./tool/run_android.sh <adb serial> 4 --offline
   IOS_TEAM=<team> ./tool/run_ios.sh <udid> 4 --offline
   ./tool/run_macos.sh 4 --offline
   ./tool/run_web.sh 4 --offline
   ```

   The quoted Android, macOS and Chrome sessions ran 3 rounds, before the
   scripts' default became 4. Keep a phone plugged in, unlocked and
   untouched; the scripts keep its screen on and lock it to portrait. For
   macOS and Chrome, run on mains power with other apps closed and the
   window in front, and leave the Mac alone: the quoted sessions waited
   until nobody had touched it for 10 minutes. `run_android.sh` also
   writes the GPU memory samples (`gpu-memory.txt`, see
   `tool/gpu_sampler.sh`).
4. **The label-fades A/B** is two Android sessions of the `fmvt` arm, 2
   rounds each. Run the first as is. For the second, add
   `labelFadeDuration: Duration.zero,` to the `VectorTileLayer` in
   `lib/src/arms.dart`, after its `labelMode:` argument, and undo that
   afterwards:

   ```sh
   ./tool/run_android.sh <adb serial> 2 --offline --arms fmvt --session <name>-fades-150ms
   ./tool/run_android.sh <adb serial> 2 --offline --arms fmvt --session <name>-fades-off
   ```

5. **MapLibre's screenshots** in the Chrome grid come from
   `tool/reference_shots.mjs`, which fetches through a lab server of its
   own and drives the Playwright that `run_web.sh` installs. Glyphs reach
   the cache only once MapLibre has fetched them (neither Flutter package
   reads them), so start that lab without `--offline` the first time:

   ```sh
   dart run tool/lab_server.dart --platform maplibre --rounds 1 --session refs --out /tmp/refs-lab &
   node tool/reference_shots.mjs http://localhost:8790 results/raw/<chrome session>/shots
   kill %1
   ```

6. **Make the tables.**

   ```sh
   dart run tool/summarize.dart results/raw/<session>                 # frames, gaps, settle, RSS, requests
   python3 -I tool/gpu_memory.py results/raw/<session>/gpu-memory.txt # Android GPU memory
   python3 -I tool/fidelity.py results/raw/<session>                  # the screenshot grid
   ```

   Run `summarize.dart` on the quoted session's directory as well, and
   put the two side by side.

**What should agree.** Another device gives other absolute numbers.
What should hold is the order within each pair (`fmvt-raster` against
`vmt-raster`, `fmvt` against `vmt-vector`) and roughly the size of the
gap. For scale: from one round to the next, the same arm and pass in
the quoted sessions moved by up to 7.3 points of frames delivered on
Android (1.8 at the median), 4.2 on the iPhone (0.4), 3.7 in Chrome
(0.5) and 1.1 on macOS (0.1).
If yours disagree, open an issue and attach the session's directory:
its `results.jsonl` holds everything the tables are made from.

`bench/` in the repository root is a different harness. It measures
this package on its own (frame times and label stability across zoom
crossings) and answers whether a change made it faster, not how it
compares with `vector_map_tiles`; see `bench/README.md`.

## Files

| file | |
|---|---|
| `lib/main.dart` | entry point: lab run, in-browser benchmark, results page or demo |
| `lib/src/arms.dart` | the six configurations |
| `lib/src/scenarios.dart` | camera paths and screenshot cameras |
| `lib/src/metrics.dart` | frame log, pacing and timing statistics |
| `lib/src/bench_page.dart` | one measured run |
| `lib/src/demo_page.dart`, `results_page.dart` | the web demo |
| `tool/lab_server.dart` | record/replay proxy, run queue, results sink |
| `tool/run_*.sh`, `run_web.mjs` | per-platform drivers |
| `tool/summarize.dart` | raw results → RESULTS.md tables |
| `tool/gpu_sampler.sh`, `gpu_memory.py` | Android GPU memory samples → the GPU table in RESULTS.md |
| `tool/reference_shots.mjs`, `maplibre.html` | MapLibre reference renders |
| `tool/fidelity.py` | raw screenshots → the WebP grids in RESULTS.md |
