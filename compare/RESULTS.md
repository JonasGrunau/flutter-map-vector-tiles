# Results

How `flutter_map_vector_tiles` and `vector_map_tiles` 9.0.0-beta.13 compare,
measured with this directory's harness (method and arms: [README.md](README.md)).

**Status, 2026-10-13:** complete sessions on Android, macOS and Chrome,
all six arms each, built from c1dc45c, with MapLibre GL JS rendering the
same cameras next to the Chrome screenshots. Every run replayed the same
recorded tiles. Still to come: iOS. The sessions this page quoted
before, and the first macOS and Chrome attempts, are listed under
[Earlier sessions](#earlier-sessions).

The two packages draw labels in different ways, so the arms pair up by
strategy, not by default. Labels baked into the tile images:
`fmvt-raster` (this package with `LabelMode.tile`) against `vmt-raster`
(`vector_map_tiles`' default). Labels drawn every frame: `fmvt` (this
package's default) against `vmt-vector`.

## What the Android session shows

- **Labels baked into the tiles.** This package got a frame on 94.2–98.3 %
  of display refreshes in every scenario, `vector_map_tiles` on
  74.1–98.7 %. It is 16–22 points ahead on the first pass (cold) of zoom
  and pan and on both passes of fling, 4 points ahead on the second pass
  of zoom and the first of rotate, and level, within 1 point, on the
  second pass of pan and rotate, where `vector_map_tiles` shows tiles it
  has already drawn. Its worst stall is 67–84 ms against 67–251 ms, and
  it stalls 2–8 times per pass against 3–46. Both UI threads need about
  the same time per frame (p90 3.6–9.3 ms against 4.8–9.7 ms).
- **Labels drawn every frame.** This package got 78.1–86.0 % of frames
  against vector mode's 19.8–40.2 %, 2 to 4.2 times as many. Its worst
  stall is 134 ms, on the first rotation, and 84 ms or less everywhere
  else, where vector mode's runs to 1.4 s, and vector mode keeps
  repainting for 1.2–4.4 s after a zoom, rotation or fling stops.
- **What live labels cost this package:** 8–19 points of frames, the
  difference between its two label modes, and a UI-thread p90 of
  15.4–21.7 ms instead of 3.6–9.3 ms. That buys text that stays upright
  under rotation, is sized for the exact zoom, is collision-checked across
  tile edges and fades per label (root README, "Choosing a label mode").
- **The content controls** (`TileOffset.none`: this package evaluating
  the style one level deeper, as `vector_map_tiles` does, so it draws the
  same extra label layers). With baked labels the extra labels cost
  nothing measurable: `fmvt-raster-none` is within 2.2 points of
  `fmvt-raster` everywhere, so against `vmt-raster` on equal content the
  picture is the same. With live labels they cost 1–2 points while
  zooming and on the second pan, 9–11 on the first pan and while
  flinging, and 29–30 while rotating (`fmvt-none` 48.3–84.4 %), because
  every label is drawn every frame; that is still 1.7 to 3.6 times
  vector mode.
- **Opening the map:** the first complete map took 0.95 s with baked
  labels and 1.05 s by default, against 3.0 s (raster mode) and 1.9 s
  (vector mode). This package downloaded 31 tiles, 12.8 MB, per run;
  raster mode 41 tiles, 20.4 MB; vector mode 30 tiles, 12.9 MB.
- **Settling:** with baked labels this package stops repainting 16–32 ms
  after the camera stops, except after the long warm-zoom path (162 ms:
  the last tiles' recording is spread over frames, see the CHANGELOG).
  Raster mode takes 16–17 ms, and 151–184 ms after the first pan and
  after a fling. With live labels this package takes 215–334 ms: the
  150 ms label fade plus the placement interval.
- **Memory:** with baked labels this package uses a little less: peak
  RSS 391 against 401 MB, and a peak GPU allocation of 264 against
  313 MB (RSS on this phone does not include GPU memory, so it is
  sampled separately, below the tables). This package's default needs
  more GPU memory, 365 MB, about as much as vector mode's 376 MB;
  vector mode's RSS is 892 MB against this package's 393 MB. Much of the
  default's extra GPU memory goes to its label fades, which draw fading
  labels through translucent layers: with
  `labelFadeDuration: Duration.zero`, the peak fell from 391–409 to
  317–320 MB over two runs each
  (`results/raw/2026-10-12-c1dc45c-fades-android`), still above baked
  labels' 258–290 MB. Turning the fades off costs frames, though: the
  collision pass then runs every frame instead of every 150 ms, and
  frames fell from 75.8–88.1 % to 56.5–85.2 %. With `TileOffset.none`
  this package's RSS climbs to 488–516 MB over a run, because its label
  text cache holds up to 8000 shaped labels and keeps every city's. In
  a same-build A/B over two runs per arm
  (`results/raw/2026-10-12-textcache-android`, built from 9caac25,
  before PR #9), that cache size cost 107–111 MB at
  the peak (491–495 against 384 MB with 2500 entries) and held
  117–119 MB more at the end; with the default offset, 22–29 MB at the
  peak and 37–49 MB at the end. It buys an end to seconds of re-shaping
  after returning to a zoom level: fling settle 0.3–0.4 s against
  1.6–1.8 s with `TileOffset.none`, zoom warm 0.16–0.2 s against
  0.7–0.9 s with the default offset. `VectorTileLayer.clearMemoryCache()`
  now trims it; RSS fell 25–48 MB within 3 s.

## What the macOS session shows

- **Labels baked into the tiles.** Both packages get nearly every frame:
  this package 97.5–100 %, `vector_map_tiles` 99.2–100 %. They are
  level, within 1 point, everywhere except while zooming, where
  `vector_map_tiles` is 1.4–1.7 points ahead. Neither stalls; the worst
  gap is 50 ms against 33 ms.
- **Labels drawn every frame.** This package got 97.1–100 %, vector mode
  56.8–100 %: vector mode keeps up while panning, but gets 57–65 % while
  zooming, rotating and flinging, with gaps of up to 167 ms, against this
  package's 42 ms. Vector mode's raster thread needs 18.0–21.7 ms per
  frame there (p90) against a budget of 8.3 ms at 120 Hz; this package's
  needs
  1.4–4.6 ms, and its UI thread 1.2–3.1 ms. Even with the denser
  `TileOffset.none` content this package gets 95.8–99.9 %.
- **On this machine the label strategy hardly matters for this package:**
  its two label modes are within 1 point of each other everywhere.
- **Opening the map:** 0.34 s with baked labels and 0.47 s by default,
  against 0.98 s (raster mode) and 0.96 s (vector mode). This package
  downloaded 33 tiles, 11.6 MB, per run; raster mode 39 tiles, 18.0 MB;
  vector mode 29 tiles, 11.6 MB.
- **Settling:** one frame (7–8 ms) with baked labels, for both packages.
  With live labels this package takes 189–298 ms, the label fade plus
  the placement interval, and vector mode 91–99 ms after a pan and
  0.56–1.27 s after a zoom, rotation or fling.
- **Memory:** peak RSS 495 MB with baked labels against raster mode's
  577 MB, and 527 MB by default against vector mode's 948 MB; 590 and
  643 MB with `TileOffset.none`. GPU memory was not sampled on macOS.

## What the Chrome session shows

- **Labels baked into the tiles.** This package got 93.7–100 % of frames,
  `vector_map_tiles` 39.0–100 %. They are level, at 100 %, on the second
  pass of pan and rotate, where `vector_map_tiles` shows tiles it has
  already drawn; everywhere else this package is 8–58 points ahead, most
  on the first pass of zoom (39 points) and fling (58). `vector_map_tiles`
  stalls 15–47 times on those passes, with gaps of up to 159 ms, though
  its frames themselves are short (UI p90 1.5–2.4 ms): the stalls are
  work between frames, which `FrameTiming` does not see (README.md,
  Method). This package does not stall; its worst gap is 34 ms.
- **Labels drawn every frame.** This package got 90.8–100 %, vector mode
  2.8–67.5 %. Flinging, vector mode gets 2.8–3.2 % of frames, with a
  raster-thread p90 of 694–717 ms. The worst gap is 42 ms against 858 ms.
- **The one weak spot is rotating with `TileOffset.none`:** 69.0 % on the
  first pass and 75.0 % on the second, with a UI-thread p90 of 14.9 ms
  and 7.5 ms against a budget of 8.3 ms at 120 Hz. The extra label
  layers are drawn every frame, and rotation moves all of them. It gets
  87.1–100 % in the other scenarios, and the default offset 95.2–99.8 %
  while rotating.
- **Opening the map:** 1.22 s by default and 1.25 s with baked labels,
  against 2.6 s (raster mode) and 1.9 s (vector mode).
- **Requests:** in the browser the HTTP cache answers a repeated request,
  so the lab server sees each tile once and these are distinct tiles:
  this package 33 (11.6 MB), raster mode 21 (8.2 MB), vector mode 14
  (5.8 MB). On macOS, in a smaller window, `vector_map_tiles` sent 39
  and 29 requests, so there about half of them went to tiles it had
  already downloaded. This package sent 33 on both.
- **Settling:** with baked labels this package's last repaint comes
  0–83 ms after the camera stops, and 269 ms after the first pan, while
  the last tiles arrive; raster mode's 0–16 ms, and 161–482 ms after a
  pan. With live labels this package takes 191–268 ms, vector mode
  0.5–3.5 s. There is no memory figure: the browser does not give a
  page its process's RSS.

## What the screenshots show

The Chrome grid has MapLibre GL JS in its first column, rendering the
same style from the same tiles at the same cameras.

- `vector_map_tiles` draws more labels at the same camera (compare the
  `munich-z14` row with MapLibre's): it evaluates the style one level
  deeper than MapLibre does. This package's default draws nearly the
  labels MapLibre draws at `munich-z14`; the `TileOffset.none` columns
  show it drawing the denser set.
- Baked labels, in both packages, turn with the map (`munich-z16-rot45`)
  and are dropped where they would cross a tile edge. This package's
  default keeps text upright, as MapLibre does, and collides across tile
  edges.
- `vector_map_tiles` 9 draws Liberty's dashed paths solid and leaves out
  one-way arrows and road shields; this package draws all three as the
  style defines them.
- This package also draws road-number shields on road pieces too short
  to hold them, where MapLibre leaves them out: around Karlsplatz in
  `munich-z16` (KA04, SB43, …). MapLibre places a label along a line
  only where all of it fits on the line; this package puts one at the
  middle of any line shorter than `symbol-spacing`. Some of the POI
  names MapLibre shows nearby are missing from this package's map.
- This package breaks a word that is wider than `text-max-width`:
  `munich-z14` reads LUDWIGSVORST / ADT. MapLibre breaks lines only
  between words and lets a long word run past the width.
- MapLibre draws Liberty's `building-3d` layer as extrusions, so even
  looking straight down the walls show around the edge of the screen.
  Both Flutter packages draw buildings flat (root README, Style support).

## Android · Nothing Phone (1)

Nothing A063 · Android 15 · portrait, on USB power, session
`2026-10-12-c1dc45c-android`.

Flutter 3.44.5 · flutter_map_vector_tiles 2.9.1 (c1dc45c) · vector_map_tiles 9.0.0-beta.13 · 411×914 logical px at dpr 2.625 · display 60 Hz · median of 3 runs per arm

**Frames delivered while the camera moves (higher is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 85.1 % <sub>82.4–86.1</sub> · 19 stalls | 84.4 % <sub>82.7–84.5</sub> · 15 stalls | 94.2 % <sub>93.7–94.6</sub> · 8 stalls | 95.7 % <sub>95.5–96.3</sub> · 6 stalls | 75.3 % <sub>73.2–75.6</sub> · 46 stalls | 34.7 % <sub>34.2–35.3</sub> · 74 stalls |
| zoom · warm | 84.8 % <sub>83.6–85.5</sub> · 13 stalls | 83.6 % <sub>83.0–84.9</sub> · 19 stalls | 94.9 % <sub>94.7–95.0</sub> · 8 stalls | 94.4 % <sub>94.3–94.5</sub> · 8 stalls | 90.7 % <sub>88.8–92.1</sub> · 17 stalls | 34.5 % <sub>34.0–35.1</sub> · 76 stalls |
| pan · cold | 78.6 % <sub>77.1–79.1</sub> · 14 stalls | 69.3 % <sub>68.8–74.1</sub> · 26 stalls | 95.0 % <sub>95.0–95.7</sub> · 6 stalls | 94.0 % <sub>93.2–95.2</sub> · 8 stalls | 78.6 % <sub>78.1–79.6</sub> · 33 stalls | 40.2 % <sub>39.9–40.7</sub> · 94 stalls |
| pan · warm | 78.8 % <sub>75.6–80.8</sub> · 10 stalls | 76.8 % <sub>75.1–77.5</sub> · 20 stalls | 97.7 % <sub>97.5–97.8</sub> · 3 stalls | 98.2 % <sub>97.0–98.5</sub> · 3 stalls | 98.7 % <sub>98.5–99.0</sub> · 3 stalls | 39.9 % <sub>39.9–40.5</sub> · 93 stalls |
| rotate · cold | 78.1 % <sub>78.0–78.3</sub> · 17 stalls | 48.3 % <sub>45.9–52.1</sub> · 64 stalls | 94.2 % <sub>93.8–95.0</sub> · 5 stalls | 92.0 % <sub>90.2–93.2</sub> · 9 stalls | 90.2 % <sub>89.0–91.2</sub> · 16 stalls | 19.8 % <sub>18.4–20.0</sub> · 114 stalls |
| rotate · warm | 81.3 % <sub>79.5–81.6</sub> · 13 stalls | 52.8 % <sub>51.8–55.8</sub> · 63 stalls | 98.3 % <sub>98.0–98.3</sub> · 3 stalls | 98.0 % <sub>97.5–98.5</sub> · 3 stalls | 98.7 % <sub>98.3–98.7</sub> · 3 stalls | 20.8 % <sub>20.7–21.1</sub> · 120 stalls |
| fling · cold | 86.0 % <sub>82.3–88.1</sub> · 5 stalls | 75.3 % <sub>73.8–77.9</sub> · 27 stalls | 94.2 % <sub>91.9–95.2</sub> · 3 stalls | 94.6 % <sub>92.7–96.0</sub> · 3 stalls | 74.4 % <sub>71.3–74.5</sub> · 27 stalls | 20.7 % <sub>20.3–20.9</sub> · 62 stalls |
| fling · warm | 82.2 % <sub>79.5–82.3</sub> · 9 stalls | 71.7 % <sub>71.4–74.7</sub> · 33 stalls | 95.8 % <sub>94.8–96.0</sub> · 2 stalls | 95.6 % <sub>95.0–95.6</sub> · 2 stalls | 74.1 % <sub>71.2–78.5</sub> · 26 stalls | 22.2 % <sub>20.9–23.6</sub> · 65 stalls |

**Worst frame gap, ms (lower is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 84 | 84 | 67 | 67 | 251 | 1373 |
| zoom · warm | 67 | 87 | 67 | 67 | 184 | 1331 |
| pan · cold | 84 | 100 | 83 | 100 | 100 | 100 |
| pan · warm | 50 | 84 | 67 | 67 | 67 | 101 |
| rotate · cold | 134 | 134 | 84 | 84 | 100 | 435 |
| rotate · warm | 67 | 118 | 67 | 67 | 67 | 117 |
| fling · cold | 50 | 92 | 67 | 67 | 167 | 267 |
| fling · warm | 72 | 108 | 67 | 67 | 167 | 266 |

**UI thread p90 / raster thread p90, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 15.4 / 15.6 | 18.7 / 16.4 | 9.3 / 13.4 | 8.2 / 15.2 | 8.3 / 8.3 | 40.2 / 47.1 |
| zoom · warm | 16.6 / 15.6 | 19.2 / 16.4 | 8.6 / 14.6 | 8.7 / 14.3 | 5.2 / 3.8 | 39.9 / 48.4 |
| pan · cold | 20.8 / 7.2 | 26.7 / 9.8 | 8.8 / 3.9 | 9.3 / 10.9 | 7.3 / 11.9 | 7.3 / 59.0 |
| pan · warm | 21.7 / 7.8 | 25.8 / 9.8 | 7.9 / 7.6 | 8.8 / 3.5 | 4.8 / 3.0 | 7.1 / 56.8 |
| rotate · cold | 21.5 / 14.3 | 51.3 / 12.3 | 7.9 / 3.7 | 8.3 / 4.0 | 5.8 / 3.5 | 50.4 / 98.1 |
| rotate · warm | 21.0 / 14.7 | 51.5 / 12.3 | 3.6 / 15.8 | 3.6 / 3.5 | 5.8 / 3.0 | 41.4 / 96.7 |
| fling · cold | 17.1 / 17.4 | 23.6 / 16.3 | 8.7 / 15.3 | 9.7 / 7.0 | 9.7 / 15.9 | 86.6 / 149.7 |
| fling · warm | 21.1 / 17.7 | 30.7 / 16.1 | 9.2 / 4.2 | 7.9 / 4.3 | 7.7 / 16.3 | 84.8 / 131.2 |

**Settle: time from the camera stopping to the last repaint, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 235 | 219 | 17 | 16 | 16 | 3768 |
| zoom · warm | 215 | 751 | 162 | 649 | 16 | 4397 |
| pan · cold | 314 | 350 | 32 | 528 | 152 | 81 |
| pan · warm | 334 | 312 | 32 | 16 | 16 | 116 |
| rotate · cold | 301 | 283 | 16 | 17 | 16 | 1228 |
| rotate · warm | 289 | 316 | 16 | 16 | 17 | 1214 |
| fling · cold | 297 | 251 | 16 | 17 | 151 | 1258 |
| fling · warm | 270 | 264 | 16 | 16 | 184 | 1243 |

**Opening the map, network and memory**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| time to first complete map, ms | 1052 | 1467 | 952 | 1092 | 2990 | 1892 |
| tile requests per run | 31 | 23 | 31 | 23 | 41 | 30 |
| MB downloaded per run | 12.8 | 10.3 | 12.8 | 10.3 | 20.4 | 12.9 |
| peak RSS, MB | 393 | 516 | 391 | 488 | 401 | 892 |

**GPU memory, MB** (peak per run, median of 3 <sub>range</sub>; not part of
`results.jsonl`, see below)

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| peak GPU allocation | 365 <sub>357–486</sub> | 460 <sub>442–503</sub> | 264 <sub>258–290</sub> | 275 <sub>264–304</sub> | 313 <sub>264–313</sub> | 376 <sub>374–415</sub> |

Android's RSS does not include GPU memory on this phone, and tile images
live there. These figures come from `adb shell dumpsys gpu --gpumem`
(the `Proc <pid> total:` line for the app), sampled from the Mac every
~3.5 s for the whole of each run; spikes shorter than that can be missed.
Samples: [results/raw/2026-10-12-c1dc45c-android/gpu-memory.txt](results/raw/2026-10-12-c1dc45c-android/gpu-memory.txt).

**Screenshots** (fixed Munich cameras after round 0; click for full size)

| camera | flutter_map_vector_tiles | flutter_map_vector_tiles · LabelMode.tile | vector_map_tiles · raster | vector_map_tiles · vector | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `munich-z14` | [![flutter_map_vector_tiles, munich-z14](results/shots/2026-10-12-c1dc45c-android/munich-z14-fmvt.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z14-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z14](results/shots/2026-10-12-c1dc45c-android/munich-z14-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z14-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z14](results/shots/2026-10-12-c1dc45c-android/munich-z14-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z14-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z14](results/shots/2026-10-12-c1dc45c-android/munich-z14-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z14-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z14](results/shots/2026-10-12-c1dc45c-android/munich-z14-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z14-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z14](results/shots/2026-10-12-c1dc45c-android/munich-z14-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z14-fmvt-raster-none.webp) |
| `munich-z16` | [![flutter_map_vector_tiles, munich-z16](results/shots/2026-10-12-c1dc45c-android/munich-z16-fmvt.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16](results/shots/2026-10-12-c1dc45c-android/munich-z16-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16](results/shots/2026-10-12-c1dc45c-android/munich-z16-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16](results/shots/2026-10-12-c1dc45c-android/munich-z16-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16](results/shots/2026-10-12-c1dc45c-android/munich-z16-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16](results/shots/2026-10-12-c1dc45c-android/munich-z16-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-fmvt-raster-none.webp) |
| `munich-z16-rot45` | [![flutter_map_vector_tiles, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-fmvt.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z16-rot45-fmvt-raster-none.webp) |
| `munich-z17.5` | [![flutter_map_vector_tiles, munich-z17.5](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-fmvt.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z17.5](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z17.5](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z17.5](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z17.5](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z17.5](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z17.5-fmvt-raster-none.webp) |
| `munich-z18` | [![flutter_map_vector_tiles, munich-z18](results/shots/2026-10-12-c1dc45c-android/munich-z18-fmvt.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z18-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z18](results/shots/2026-10-12-c1dc45c-android/munich-z18-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z18-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z18](results/shots/2026-10-12-c1dc45c-android/munich-z18-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z18-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z18](results/shots/2026-10-12-c1dc45c-android/munich-z18-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z18-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z18](results/shots/2026-10-12-c1dc45c-android/munich-z18-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z18-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z18](results/shots/2026-10-12-c1dc45c-android/munich-z18-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-android/munich-z18-fmvt-raster-none.webp) |

Raw data: [results/raw/2026-10-12-c1dc45c-android/results.jsonl](results/raw/2026-10-12-c1dc45c-android/results.jsonl).

## macOS · MacBook Pro (M4 Pro)

Mac16,7 · Apple M4 Pro · macOS 27.0 · on AC power, the app's window in
front, session `2026-10-12-c1dc45c-macos`.

Flutter 3.44.5 · flutter_map_vector_tiles 2.9.1 (c1dc45c) · vector_map_tiles 9.0.0-beta.13 · 800×600 logical px at dpr 2.0 · display 120 Hz · median of 3 runs per arm

**Frames delivered while the camera moves (higher is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 97.1 % <sub>96.9–97.1</sub> | 95.8 % <sub>95.8–96.0</sub> · 1 stall | 97.5 % <sub>97.4–97.5</sub> | 97.5 % <sub>97.1–97.5</sub> | 99.2 % <sub>99.1–99.3</sub> | 65.0 % <sub>64.8–65.1</sub> · 27 stalls |
| zoom · warm | 98.5 % <sub>98.4–98.6</sub> | 97.8 % <sub>97.8–97.9</sub> | 98.6 % <sub>98.5–98.7</sub> | 98.1 % <sub>98.1–98.3</sub> | 100.0 % <sub>100.0–100.0</sub> | 65.0 % <sub>64.9–65.0</sub> · 30 stalls |
| pan · cold | 99.3 % <sub>99.3–99.4</sub> | 99.3 % <sub>99.0–99.4</sub> | 99.8 % <sub>99.8–99.9</sub> | 99.9 % <sub>99.8–100.0</sub> | 99.8 % <sub>99.8–100.0</sub> | 100.0 % <sub>99.9–100.0</sub> |
| pan · warm | 99.7 % <sub>99.7–99.8</sub> | 99.8 % <sub>99.7–99.8</sub> | 99.7 % <sub>99.7–99.8</sub> | 99.8 % <sub>99.8–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> |
| rotate · cold | 99.8 % <sub>99.8–99.9</sub> | 99.7 % <sub>99.5–99.8</sub> | 100.0 % <sub>99.9–100.0</sub> | 99.9 % <sub>99.8–100.0</sub> | 99.9 % <sub>99.8–99.9</sub> | 56.8 % <sub>56.5–57.3</sub> · 1 stall |
| rotate · warm | 100.0 % <sub>100.0–100.0</sub> | 99.7 % <sub>99.2–99.8</sub> | 99.8 % <sub>99.8–99.9</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>99.9–100.0</sub> | 57.6 % <sub>56.8–57.9</sub> |
| fling · cold | 99.1 % <sub>99.1–99.3</sub> | 99.1 % <sub>98.8–99.2</sub> | 100.0 % <sub>99.9–100.0</sub> | 99.8 % <sub>99.8–99.8</sub> | 99.2 % <sub>99.1–99.5</sub> | 63.2 % <sub>63.0–63.6</sub> · 5 stalls |
| fling · warm | 100.0 % <sub>100.0–100.0</sub> | 99.9 % <sub>99.9–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>99.9–100.0</sub> | 64.0 % <sub>64.0–64.1</sub> · 3 stalls |

**Worst frame gap, ms (lower is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 42 | 58 | 33 | 42 | 33 | 158 |
| zoom · warm | 42 | 42 | 50 | 42 | 8 | 167 |
| pan · cold | 17 | 17 | 17 | 17 | 17 | 8 |
| pan · warm | 17 | 17 | 17 | 17 | 8 | 8 |
| rotate · cold | 17 | 17 | 12 | 17 | 17 | 58 |
| rotate · warm | 8 | 25 | 17 | 8 | 12 | 33 |
| fling · cold | 25 | 25 | 8 | 25 | 25 | 83 |
| fling · warm | 9 | 17 | 8 | 12 | 9 | 67 |

**UI thread p90 / raster thread p90, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 2.3 / 2.3 | 3.3 / 2.0 | 0.6 / 1.3 | 0.7 / 1.1 | 0.9 / 1.1 | 9.4 / 18.3 |
| zoom · warm | 2.5 / 2.1 | 2.5 / 1.7 | 0.6 / 1.0 | 0.6 / 1.1 | 1.1 / 1.1 | 9.3 / 18.1 |
| pan · cold | 3.0 / 1.4 | 3.7 / 1.1 | 0.6 / 1.4 | 0.7 / 1.1 | 0.9 / 1.0 | 0.8 / 3.0 |
| pan · warm | 3.1 / 1.4 | 2.6 / 1.0 | 0.6 / 1.3 | 0.9 / 1.3 | 1.1 / 1.1 | 0.8 / 2.9 |
| rotate · cold | 1.3 / 4.5 | 3.1 / 5.4 | 0.6 / 1.1 | 0.8 / 1.1 | 1.0 / 1.1 | 5.5 / 18.1 |
| rotate · warm | 1.2 / 4.6 | 2.8 / 5.4 | 0.7 / 1.1 | 0.7 / 1.1 | 1.1 / 1.1 | 5.2 / 18.0 |
| fling · cold | 2.3 / 3.0 | 3.2 / 2.9 | 0.6 / 1.0 | 0.8 / 1.1 | 1.3 / 1.0 | 10.9 / 21.6 |
| fling · warm | 2.1 / 2.6 | 3.0 / 2.2 | 0.7 / 1.1 | 0.6 / 1.0 | 1.1 / 1.1 | 11.0 / 21.7 |

**Settle: time from the camera stopping to the last repaint, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 283 | 191 | 8 | 8 | 8 | 561 |
| zoom · warm | 298 | 163 | 8 | 8 | 8 | 576 |
| pan · cold | 189 | 230 | 8 | 8 | 8 | 99 |
| pan · warm | 258 | 265 | 8 | 7 | 8 | 91 |
| rotate · cold | 250 | 241 | 8 | 8 | 8 | 1270 |
| rotate · warm | 200 | 233 | 8 | 8 | 7 | 1263 |
| fling · cold | 200 | 233 | 8 | 8 | 7 | 620 |
| fling · warm | 216 | 242 | 8 | 8 | 8 | 623 |

**Opening the map, network and memory**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| time to first complete map, ms | 470 | 487 | 336 | 341 | 982 | 962 |
| tile requests per run | 33 | 21 | 33 | 21 | 39 | 29 |
| MB downloaded per run | 11.6 | 8.2 | 11.6 | 8.2 | 18.0 | 11.6 |
| peak RSS, MB | 527 | 643 | 495 | 590 | 577 | 948 |

**Screenshots** (fixed Munich cameras after round 0; click for full size)

| camera | flutter_map_vector_tiles | flutter_map_vector_tiles · LabelMode.tile | vector_map_tiles · raster | vector_map_tiles · vector | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `munich-z14` | [![flutter_map_vector_tiles, munich-z14](results/shots/2026-10-12-c1dc45c-macos/munich-z14-fmvt.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z14-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z14](results/shots/2026-10-12-c1dc45c-macos/munich-z14-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z14-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z14](results/shots/2026-10-12-c1dc45c-macos/munich-z14-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z14-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z14](results/shots/2026-10-12-c1dc45c-macos/munich-z14-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z14-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z14](results/shots/2026-10-12-c1dc45c-macos/munich-z14-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z14-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z14](results/shots/2026-10-12-c1dc45c-macos/munich-z14-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z14-fmvt-raster-none.webp) |
| `munich-z16` | [![flutter_map_vector_tiles, munich-z16](results/shots/2026-10-12-c1dc45c-macos/munich-z16-fmvt.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16](results/shots/2026-10-12-c1dc45c-macos/munich-z16-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16](results/shots/2026-10-12-c1dc45c-macos/munich-z16-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16](results/shots/2026-10-12-c1dc45c-macos/munich-z16-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16](results/shots/2026-10-12-c1dc45c-macos/munich-z16-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16](results/shots/2026-10-12-c1dc45c-macos/munich-z16-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-fmvt-raster-none.webp) |
| `munich-z16-rot45` | [![flutter_map_vector_tiles, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-fmvt.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z16-rot45-fmvt-raster-none.webp) |
| `munich-z17.5` | [![flutter_map_vector_tiles, munich-z17.5](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-fmvt.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z17.5](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z17.5](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z17.5](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z17.5](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z17.5](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z17.5-fmvt-raster-none.webp) |
| `munich-z18` | [![flutter_map_vector_tiles, munich-z18](results/shots/2026-10-12-c1dc45c-macos/munich-z18-fmvt.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z18-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z18](results/shots/2026-10-12-c1dc45c-macos/munich-z18-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z18-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z18](results/shots/2026-10-12-c1dc45c-macos/munich-z18-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z18-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z18](results/shots/2026-10-12-c1dc45c-macos/munich-z18-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z18-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z18](results/shots/2026-10-12-c1dc45c-macos/munich-z18-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z18-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z18](results/shots/2026-10-12-c1dc45c-macos/munich-z18-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-macos/munich-z18-fmvt-raster-none.webp) |

Raw data: [results/raw/2026-10-12-c1dc45c-macos/results.jsonl](results/raw/2026-10-12-c1dc45c-macos/results.jsonl).

## Chrome · on the same Mac

Chrome 155 · headed, driven by Playwright · the app built with
`flutter build web --profile` (dart2js), session
`2026-10-12-c1dc45c-web`. MapLibre GL JS 4.7.1 rendered the reference
column in the same browser, from the same recorded tiles.

Flutter 3.44.5 · flutter_map_vector_tiles 2.9.1 (c1dc45c) · vector_map_tiles 9.0.0-beta.13 · 1000×800 logical px at dpr 2 · display 120 Hz · median of 3 runs per arm

**Frames delivered while the camera moves (higher is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 90.8 % <sub>90.5–91.1</sub> | 87.1 % <sub>86.9–87.2</sub> | 93.7 % <sub>93.3–93.9</sub> | 91.6 % <sub>91.5–91.6</sub> | 54.3 % <sub>53.6–54.5</sub> · 29 stalls | 17.2 % <sub>17.1–17.3</sub> · 52 stalls |
| zoom · warm | 94.4 % <sub>94.2–94.6</sub> | 90.0 % <sub>87.9–90.2</sub> · 1 stall | 96.2 % <sub>95.6–96.3</sub> | 93.1 % <sub>90.8–93.2</sub> | 88.0 % <sub>87.9–88.0</sub> · 15 stalls | 17.1 % <sub>17.0–17.5</sub> · 52 stalls |
| pan · cold | 95.3 % <sub>95.3–95.4</sub> | 93.8 % <sub>93.5–93.8</sub> | 97.0 % <sub>96.9–97.1</sub> | 97.0 % <sub>96.8–97.4</sub> | 75.2 % <sub>75.1–75.6</sub> · 20 stalls | 67.2 % <sub>66.8–67.2</sub> · 9 stalls |
| pan · warm | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>99.4–100.0</sub> | 100.0 % <sub>99.8–100.0</sub> | 67.5 % <sub>67.0–67.6</sub> · 12 stalls |
| rotate · cold | 95.2 % <sub>93.9–95.5</sub> | 69.0 % <sub>67.0–70.6</sub> | 97.6 % <sub>97.3–97.6</sub> | 97.6 % <sub>97.3–97.6</sub> | 85.8 % <sub>85.5–86.2</sub> · 19 stalls | 12.4 % <sub>11.1–12.7</sub> · 91 stalls |
| rotate · warm | 99.8 % <sub>99.4–100.0</sub> | 75.0 % <sub>72.8–76.5</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>99.9–100.0</sub> | 100.0 % <sub>99.4–100.0</sub> | 13.7 % <sub>13.6–13.8</sub> · 95 stalls |
| fling · cold | 92.5 % <sub>92.2–92.7</sub> | 88.7 % <sub>87.3–89.3</sub> | 96.5 % <sub>96.3–96.6</sub> | 96.2 % <sub>96.2–96.5</sub> | 39.0 % <sub>38.7–39.4</sub> · 47 stalls | 3.2 % <sub>2.8–3.5</sub> · 27 stalls |
| fling · warm | 95.2 % <sub>94.1–95.3</sub> | 91.2 % <sub>90.5–91.3</sub> | 99.9 % <sub>99.9–100.0</sub> | 99.7 % <sub>99.3–100.0</sub> | 75.4 % <sub>74.4–77.4</sub> · 19 stalls | 2.8 % <sub>2.4–3.3</sub> · 26 stalls |

**Worst frame gap, ms (lower is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 42 | 42 | 34 | 42 | 150 | 733 |
| zoom · warm | 33 | 67 | 33 | 42 | 150 | 762 |
| pan · cold | 33 | 33 | 26 | 25 | 150 | 100 |
| pan · warm | 10 | 10 | 10 | 10 | 10 | 108 |
| rotate · cold | 42 | 50 | 33 | 33 | 159 | 367 |
| rotate · warm | 23 | 27 | 10 | 12 | 12 | 117 |
| fling · cold | 26 | 33 | 26 | 33 | 158 | 858 |
| fling · warm | 25 | 32 | 13 | 18 | 134 | 832 |

**UI thread p90 / raster thread p90, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 7.4 / 1.5 | 8.8 / 1.8 | 5.3 / 0.6 | 5.6 / 0.6 | 1.7 / 0.5 | 39.0 / 26.8 |
| zoom · warm | 5.1 / 1.5 | 7.6 / 1.7 | 3.0 / 0.6 | 4.7 / 0.6 | 2.1 / 0.6 | 38.9 / 26.4 |
| pan · cold | 4.1 / 1.0 | 7.4 / 1.0 | 4.4 / 0.6 | 4.4 / 0.6 | 1.9 / 0.5 | 1.2 / 11.5 |
| pan · warm | 2.8 / 0.9 | 4.2 / 1.0 | 1.7 / 0.6 | 1.7 / 0.7 | 1.9 / 0.5 | 1.1 / 11.5 |
| rotate · cold | 4.9 / 3.1 | 14.9 / 5.0 | 2.2 / 0.7 | 2.2 / 0.7 | 2.4 / 0.6 | 55.6 / 31.9 |
| rotate · warm | 3.1 / 2.9 | 7.5 / 5.0 | 1.9 / 0.7 | 1.9 / 0.7 | 2.1 / 0.6 | 59.3 / 30.9 |
| fling · cold | 8.3 / 2.8 | 11.6 / 3.1 | 4.5 / 0.6 | 4.4 / 0.6 | 1.5 / 0.4 | 139.5 / 693.8 |
| fling · warm | 7.4 / 2.7 | 9.8 / 2.8 | 1.8 / 0.6 | 1.7 / 0.6 | 1.9 / 0.6 | 137.6 / 716.5 |

**Settle: time from the camera stopping to the last repaint, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 191 | 231 | 83 | 154 | 0 | 3517 |
| zoom · warm | 224 | 220 | 74 | 157 | 0 | 3163 |
| pan · cold | 265 | 275 | 269 | 285 | 482 | 518 |
| pan · warm | 200 | 166 | 0 | 0 | 161 | 522 |
| rotate · cold | 217 | 259 | 0 | 0 | 0 | 1766 |
| rotate · warm | 192 | 211 | 0 | 0 | 0 | 1421 |
| fling · cold | 268 | 249 | 0 | 0 | 8 | 1464 |
| fling · warm | 258 | 174 | 0 | 0 | 16 | 1602 |

**Opening the map, network and memory**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| time to first complete map, ms | 1220 | 1272 | 1252 | 1309 | 2591 | 1931 |
| tile requests per run | 33 | 21 | 33 | 21 | 21 | 14 |
| MB downloaded per run | 11.6 | 8.2 | 11.6 | 8.2 | 8.2 | 5.8 |

**Screenshots** (fixed Munich cameras after round 0, MapLibre GL JS
first; click for full size)

| camera | MapLibre GL JS (reference) | flutter_map_vector_tiles | flutter_map_vector_tiles · LabelMode.tile | vector_map_tiles · raster | vector_map_tiles · vector | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `munich-z14` | [![MapLibre GL JS (reference), munich-z14](results/shots/2026-10-12-c1dc45c-web/munich-z14-maplibre.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z14-maplibre.webp) | [![flutter_map_vector_tiles, munich-z14](results/shots/2026-10-12-c1dc45c-web/munich-z14-fmvt.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z14-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z14](results/shots/2026-10-12-c1dc45c-web/munich-z14-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z14-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z14](results/shots/2026-10-12-c1dc45c-web/munich-z14-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z14-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z14](results/shots/2026-10-12-c1dc45c-web/munich-z14-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z14-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z14](results/shots/2026-10-12-c1dc45c-web/munich-z14-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z14-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z14](results/shots/2026-10-12-c1dc45c-web/munich-z14-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z14-fmvt-raster-none.webp) |
| `munich-z16` | [![MapLibre GL JS (reference), munich-z16](results/shots/2026-10-12-c1dc45c-web/munich-z16-maplibre.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-maplibre.webp) | [![flutter_map_vector_tiles, munich-z16](results/shots/2026-10-12-c1dc45c-web/munich-z16-fmvt.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16](results/shots/2026-10-12-c1dc45c-web/munich-z16-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16](results/shots/2026-10-12-c1dc45c-web/munich-z16-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16](results/shots/2026-10-12-c1dc45c-web/munich-z16-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16](results/shots/2026-10-12-c1dc45c-web/munich-z16-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16](results/shots/2026-10-12-c1dc45c-web/munich-z16-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-fmvt-raster-none.webp) |
| `munich-z16-rot45` | [![MapLibre GL JS (reference), munich-z16-rot45](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-maplibre.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-maplibre.webp) | [![flutter_map_vector_tiles, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-fmvt.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16-rot45](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z16-rot45-fmvt-raster-none.webp) |
| `munich-z17.5` | [![MapLibre GL JS (reference), munich-z17.5](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-maplibre.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-maplibre.webp) | [![flutter_map_vector_tiles, munich-z17.5](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-fmvt.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z17.5](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z17.5](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z17.5](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z17.5](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z17.5](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z17.5-fmvt-raster-none.webp) |
| `munich-z18` | [![MapLibre GL JS (reference), munich-z18](results/shots/2026-10-12-c1dc45c-web/munich-z18-maplibre.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z18-maplibre.webp) | [![flutter_map_vector_tiles, munich-z18](results/shots/2026-10-12-c1dc45c-web/munich-z18-fmvt.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z18-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z18](results/shots/2026-10-12-c1dc45c-web/munich-z18-fmvt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z18-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z18](results/shots/2026-10-12-c1dc45c-web/munich-z18-vmt-raster.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z18-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z18](results/shots/2026-10-12-c1dc45c-web/munich-z18-vmt-vector.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z18-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z18](results/shots/2026-10-12-c1dc45c-web/munich-z18-fmvt-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z18-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z18](results/shots/2026-10-12-c1dc45c-web/munich-z18-fmvt-raster-none.webp)](results/shots/2026-10-12-c1dc45c-web/munich-z18-fmvt-raster-none.webp) |

Raw data: [results/raw/2026-10-12-c1dc45c-web/results.jsonl](results/raw/2026-10-12-c1dc45c-web/results.jsonl).

## Earlier sessions

Kept as raw data under `results/raw/`, with their screenshots, where
they have any, in `results/shots/`. None of them is comparable with the
sessions above:

| session | arms | why it is superseded |
|---|---|---|
| `2026-10-12-android` | all six | built from 31e7d17, before 3408659 (`fill-extrusion-opacity` per layer, which changes how Liberty's buildings are drawn) and PR #9 (layer filters once per data tile, cheaper frames between placement passes), which made every `fmvt*` arm faster; this page quoted it until 2026-10-13 |
| `2026-10-12-fades-android` | `fmvt`, fades on and off | built from 3408659 and fc9dd4c, before PR #9; repeated in `2026-10-12-c1dc45c-fades-android` |
| `2026-10-12-web-nostore` | all six, Chrome | the lab server answered with `Cache-Control: no-store`, which turned off the browser's HTTP cache, and on the web this package has no disk cache: evicted tiles came back from the network (fixed in fc9dd4c); on battery, other apps open |
| `2026-10-12-macos-battery` | all six, macOS | on battery in macOS's "Automatic" power mode, other apps open |
| `2026-10-11-split-android` | `fmvt`, `fmvt-raster`, `vmt-raster` | 1.5 s settle window (below) |
| `2026-10-11-labelmode-android` | all six | 1.5 s settle window; before tile recording was spread over frames (31c3af2) and before the text-cache fix (4cffd9b), which made `fmvt-none` keep repainting for 4–5 s after a fling |
| `2026-10-11-android` | `fmvt`, `fmvt-none`, `vmt-raster`, `vmt-vector` | 1.5 s settle window; before 31c3af2, 4cffd9b and `LabelMode.tile`; landscape |
| `2026-10-09-android` | four arms, 9 of 12 runs | incomplete |

The 1.5 s settle window. "Settled" means no frame for a quiet window,
and `vector_map_tiles` renders, rasterizes and PNG-encodes tiles between
frames: on this phone it went up to 1.75 s without a frame while still
filling a fresh screen, and kept drawing for up to 5.8 s after a camera
jump. A 1.5 s window therefore called it settled mid-render. In the
portrait sessions its `munich-z14` screenshot is missing most tiles, and
a cold pass could start with the previous view still rendering. Its
numbers barely moved once the window was fixed: `vmt-raster`'s first
complete map took 2.9 s in `2026-10-11-split-android` and 2.8 s in
`2026-10-12-android`, its settle times are the same, and its cold zoom
went from 75.0 % to 76.3 %. This package never went more than 55 ms
without a frame after a camera jump, so its numbers were not affected.
The window has been 4 s since 31e7d17.
