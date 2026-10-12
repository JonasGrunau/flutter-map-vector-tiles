# Results

How `flutter_map_vector_tiles` and `vector_map_tiles` 9.0.0-beta.13 compare,
measured with this directory's harness (method and arms: [README.md](README.md)).

**Status, 2026-10-12:** one complete session, on Android, with all six
arms. Still to come: macOS, Chrome, iOS, and MapLibre GL JS reference
renders next to the screenshots. The first macOS and Chrome sessions ran
under the wrong conditions ([Earlier sessions](#earlier-sessions)).

The two packages draw labels in different ways, so the arms pair up by
strategy, not by default. Labels baked into the tile images:
`fmvt-raster` (this package with `LabelMode.tile`) against `vmt-raster`
(`vector_map_tiles`' default). Labels drawn every frame: `fmvt` (this
package's default) against `vmt-vector`.

## What the Android session shows

- **Labels baked into the tiles.** This package got a frame on 94.5–97.8 %
  of display refreshes in every scenario, `vector_map_tiles` on
  76.3–98.7 %. It is 15–21 points ahead on the first pass (cold) of zoom
  and pan and on both passes of fling, 4–6 points ahead on the second
  pass of zoom and the first of rotate, and level, within 1.5 points, on
  the second pass of pan and rotate, where `vector_map_tiles` shows tiles
  it has already drawn. Its worst stall is 50–100 ms against 67–267 ms,
  and it stalls 2–7 times per pass against 3–45. Both UI threads need
  about the same time per frame (p90 3.6–10.3 ms against 4.9–10.4 ms).
- **Labels drawn every frame.** This package got 73.1–88.1 % of frames
  against vector mode's 20.1–40.1 %, 1.8 to 4 times as many. Its worst
  stall stays at 100 ms or less, where vector mode's runs to 1.4 s, and
  vector mode keeps repainting for 1.2–5 s after a zoom, rotation or
  fling stops.
- **What live labels cost this package:** 6.5–23 points of frames, the
  difference between its two label modes, and a UI-thread p90 of
  14.5–23.3 ms instead of 3.6–10.3 ms. That buys text that stays upright
  under rotation, is sized for the exact zoom, is collision-checked across
  tile edges and fades per label (root README, "Choosing a label mode").
- **The content controls** (`TileOffset.none`: this package evaluating
  the style one level deeper, as `vector_map_tiles` does, so it draws the
  same extra label layers). With baked labels the extra labels cost
  nothing measurable: `fmvt-raster-none` is within 1.6 points of
  `fmvt-raster` everywhere, so against `vmt-raster` on equal content the
  picture is the same. With live labels they cost 9–37 points
  (`fmvt-none` 38.6–79.2 %), because every label is drawn every frame;
  that is still 1.4 to 3.3 times vector mode.
- **Opening the map:** the first complete map took 1.05 s with baked
  labels and 1.25 s by default, against 2.8 s (raster mode) and 2.0 s
  (vector mode). This package downloaded 31 tiles, 12.8 MB, per run;
  raster mode 42 tiles, 21.7 MB; vector mode 30 tiles, 12.9 MB.
- **Settling:** with baked labels this package stops repainting ~16 ms
  after the camera stops, except after the long warm-zoom path (712 ms:
  the last tiles' recording is spread over frames, see the CHANGELOG).
  Raster mode takes 15–16 ms, and 150–240 ms after the first pan and after
  a fling. With live labels this package takes 214–301 ms: the 150 ms
  label fade plus the placement interval.
- **Memory:** with baked labels both packages use about the same: peak
  RSS 386 against 380 MB, and a peak GPU allocation of 273 against
  266 MB (RSS on this phone does not include GPU memory, so it is
  sampled separately, below the tables). This package's default needs
  more GPU memory, 372 MB, and vector mode 385 MB; vector mode's RSS is
  925 MB against this package's 400 MB. Most of the default's extra GPU
  memory goes to its label fades, which draw fading labels through
  translucent layers: with `labelFadeDuration: Duration.zero`, the peak
  fell from 350–385 to 272–311 MB over two runs each
  (`results/raw/2026-10-12-fades-android`). Turning the fades off costs
  frames, though: the collision pass then runs every frame instead of
  every 150 ms, and frames fell from 68.7–90.7 % to 59.4–79.5 %. With
  `TileOffset.none` this package's RSS climbs to 480–500 MB over a run,
  because its label text cache holds up to 8000 shaped labels and keeps
  every city's. In a
  same-build A/B over two runs per arm
  (`results/raw/2026-10-12-textcache-android`), that cache size cost
  107–111 MB at the peak (491–495 against 384 MB with 2500 entries) and
  held 117–119 MB more at the end; with the default offset, 22–29 MB at
  the peak and 37–49 MB at the end. It buys an end to seconds of
  re-shaping after returning to a zoom level: fling settle 0.3–0.4 s
  against 1.6–1.8 s with `TileOffset.none`, zoom warm 0.16–0.2 s against
  0.7–0.9 s with the default offset. `VectorTileLayer.clearMemoryCache()`
  now trims it; RSS fell 25–48 MB within 3 s.

## Android · Nothing Phone (1)

Nothing A063 · Android 15 · portrait, session `2026-10-12-android`.

Flutter 3.44.5 · flutter_map_vector_tiles 2.9.1 (31e7d17) · vector_map_tiles 9.0.0-beta.13 · 411×914 logical px at dpr 2.625 · display 60 Hz · median of 3 runs per arm

**Frames delivered while the camera moves (higher is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 88.1 % <sub>84.5–89.9</sub> · 12 stalls | 79.2 % <sub>76.3–79.7</sub> · 15 stalls | 94.6 % <sub>94.2–94.8</sub> · 7 stalls | 96.0 % <sub>95.4–96.5</sub> · 5 stalls | 76.3 % <sub>75.8–76.4</sub> · 45 stalls | 35.2 % <sub>34.8–35.3</sub> · 73 stalls |
| zoom · warm | 85.3 % <sub>82.3–85.9</sub> · 9 stalls | 70.0 % <sub>66.3–70.3</sub> · 28 stalls | 95.5 % <sub>95.3–95.8</sub> · 5 stalls | 94.5 % <sub>94.3–95.0</sub> · 6 stalls | 89.6 % <sub>87.9–90.1</sub> · 17 stalls | 35.2 % <sub>34.7–35.5</sub> · 72 stalls |
| pan · cold | 80.3 % <sub>75.1–80.6</sub> · 12 stalls | 58.8 % <sub>58.0–66.6</sub> · 35 stalls | 95.8 % <sub>94.2–95.8</sub> · 5 stalls | 96.0 % <sub>95.3–96.8</sub> · 4 stalls | 80.3 % <sub>79.3–81.0</sub> · 31 stalls | 40.1 % <sub>39.8–40.5</sub> · 95 stalls |
| pan · warm | 73.5 % <sub>72.1–80.1</sub> · 8 stalls | 55.9 % <sub>54.3–60.0</sub> · 45 stalls | 96.8 % <sub>96.3–97.0</sub> · 3 stalls | 98.0 % <sub>97.7–98.3</sub> · 3 stalls | 98.3 % <sub>98.2–99.0</sub> · 3 stalls | 40.0 % <sub>40.0–40.1</sub> · 99 stalls |
| rotate · cold | 73.1 % <sub>70.1–77.1</sub> · 16 stalls | 40.9 % <sub>39.8–41.3</sub> · 83 stalls | 94.5 % <sub>93.5–94.8</sub> · 6 stalls | 93.3 % <sub>92.7–94.2</sub> · 5 stalls | 90.2 % <sub>90.1–91.2</sub> · 14 stalls | 20.1 % <sub>19.1–20.1</sub> · 115 stalls |
| rotate · warm | 75.1 % <sub>74.3–81.6</sub> · 15 stalls | 38.6 % <sub>37.5–40.5</sub> · 82 stalls | 97.8 % <sub>97.5–98.0</sub> · 3 stalls | 98.3 % <sub>97.3–98.8</sub> · 2 stalls | 98.7 % <sub>98.7–99.0</sub> · 3 stalls | 20.8 % <sub>20.8–20.9</sub> · 119 stalls |
| fling · cold | 84.6 % <sub>81.2–84.8</sub> · 4 stalls | 68.6 % <sub>66.6–69.0</sub> · 21 stalls | 96.2 % <sub>94.6–97.1</sub> · 2 stalls | 94.6 % <sub>93.3–95.8</sub> · 2 stalls | 77.9 % <sub>76.2–81.8</sub> · 19 stalls | 20.9 % <sub>20.7–21.0</sub> · 62 stalls |
| fling · warm | 74.7 % <sub>71.0–83.5</sub> · 13 stalls | 59.9 % <sub>56.6–61.6</sub> · 34 stalls | 96.2 % <sub>96.0–97.1</sub> · 3 stalls | 97.3 % <sub>95.6–97.7</sub> · 2 stalls | 75.6 % <sub>71.4–77.9</sub> · 27 stalls | 21.4 % <sub>19.8–21.5</sub> · 60 stalls |

**Worst frame gap, ms (lower is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 67 | 84 | 67 | 67 | 267 | 1339 |
| zoom · warm | 67 | 84 | 67 | 67 | 201 | 1372 |
| pan · cold | 84 | 117 | 67 | 67 | 134 | 100 |
| pan · warm | 50 | 84 | 67 | 67 | 67 | 100 |
| rotate · cold | 100 | 184 | 100 | 84 | 84 | 301 |
| rotate · warm | 67 | 133 | 67 | 67 | 67 | 134 |
| fling · cold | 67 | 117 | 50 | 67 | 167 | 284 |
| fling · warm | 70 | 117 | 67 | 50 | 167 | 286 |

**UI thread p90 / raster thread p90, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 14.5 / 15.4 | 19.5 / 15.5 | 9.6 / 15.3 | 8.3 / 16.3 | 7.6 / 7.7 | 40.6 / 43.9 |
| zoom · warm | 16.5 / 15.8 | 23.2 / 15.3 | 9.2 / 15.7 | 9.3 / 12.5 | 5.3 / 3.8 | 41.2 / 42.9 |
| pan · cold | 19.5 / 11.4 | 29.1 / 10.2 | 10.3 / 9.8 | 9.7 / 8.9 | 7.3 / 11.5 | 7.1 / 58.0 |
| pan · warm | 23.3 / 7.5 | 33.8 / 10.8 | 9.3 / 3.5 | 10.3 / 3.4 | 4.9 / 3.0 | 8.0 / 60.3 |
| rotate · cold | 22.4 / 14.4 | 51.4 / 11.9 | 7.3 / 4.9 | 8.3 / 16.5 | 5.8 / 4.3 | 60.9 / 98.6 |
| rotate · warm | 21.3 / 14.7 | 59.1 / 10.3 | 3.6 / 15.1 | 3.7 / 3.1 | 5.9 / 3.0 | 43.1 / 97.3 |
| fling · cold | 16.6 / 16.0 | 26.4 / 15.4 | 8.4 / 4.3 | 9.4 / 15.9 | 10.4 / 5.9 | 90.6 / 146.0 |
| fling · warm | 21.1 / 16.9 | 32.6 / 14.8 | 8.3 / 4.9 | 8.2 / 16.3 | 8.3 / 7.3 | 88.4 / 122.1 |

**Settle: time from the camera stopping to the last repaint, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| zoom · cold | 265 | 267 | 16 | 16 | 16 | 4977 |
| zoom · warm | 301 | 468 | 712 | 378 | 16 | 3738 |
| pan · cold | 290 | 338 | 16 | 564 | 236 | 117 |
| pan · warm | 282 | 300 | 17 | 280 | 16 | 130 |
| rotate · cold | 214 | 331 | 16 | 16 | 15 | 1234 |
| rotate · warm | 257 | 357 | 16 | 17 | 16 | 1202 |
| fling · cold | 293 | 321 | 16 | 17 | 152 | 1232 |
| fling · warm | 262 | 329 | 16 | 17 | 153 | 1209 |

**Opening the map, network and memory**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| time to first complete map, ms | 1250 | 1748 | 1050 | 1217 | 2835 | 2007 |
| tile requests per run | 31 | 23 | 31 | 23 | 42 | 30 |
| MB downloaded per run | 12.8 | 10.3 | 12.8 | 10.3 | 21.7 | 12.9 |
| peak RSS, MB | 400 | 500 | 386 | 480 | 380 | 925 |

**GPU memory, MB** (peak per run, median of 3 <sub>range</sub>; not part of
`results.jsonl`, see below)

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|
| peak GPU allocation | 372 <sub>341–415</sub> | 424 <sub>381–466</sub> | 273 <sub>265–285</sub> | 263 <sub>263–285</sub> | 266 <sub>263–285</sub> | 385 <sub>383–420</sub> |

Android's RSS does not include GPU memory on this phone, and tile images
live there. These figures come from `adb shell dumpsys gpu --gpumem`
(the `Proc <pid> total:` line for the app), sampled from the Mac every
~3.5 s for the whole of each run; spikes shorter than that can be missed.
Samples: [results/raw/2026-10-12-android/gpu-memory.txt](results/raw/2026-10-12-android/gpu-memory.txt).

**Screenshots** (fixed Munich cameras after round 0; click for full size)

| camera | flutter_map_vector_tiles | flutter_map_vector_tiles · LabelMode.tile | vector_map_tiles · raster | vector_map_tiles · vector | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `munich-z14` | [![flutter_map_vector_tiles, munich-z14](results/shots/2026-10-12-android/munich-z14-fmvt.webp)](results/shots/2026-10-12-android/munich-z14-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z14](results/shots/2026-10-12-android/munich-z14-fmvt-raster.webp)](results/shots/2026-10-12-android/munich-z14-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z14](results/shots/2026-10-12-android/munich-z14-vmt-raster.webp)](results/shots/2026-10-12-android/munich-z14-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z14](results/shots/2026-10-12-android/munich-z14-vmt-vector.webp)](results/shots/2026-10-12-android/munich-z14-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z14](results/shots/2026-10-12-android/munich-z14-fmvt-none.webp)](results/shots/2026-10-12-android/munich-z14-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z14](results/shots/2026-10-12-android/munich-z14-fmvt-raster-none.webp)](results/shots/2026-10-12-android/munich-z14-fmvt-raster-none.webp) |
| `munich-z16` | [![flutter_map_vector_tiles, munich-z16](results/shots/2026-10-12-android/munich-z16-fmvt.webp)](results/shots/2026-10-12-android/munich-z16-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16](results/shots/2026-10-12-android/munich-z16-fmvt-raster.webp)](results/shots/2026-10-12-android/munich-z16-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16](results/shots/2026-10-12-android/munich-z16-vmt-raster.webp)](results/shots/2026-10-12-android/munich-z16-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16](results/shots/2026-10-12-android/munich-z16-vmt-vector.webp)](results/shots/2026-10-12-android/munich-z16-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16](results/shots/2026-10-12-android/munich-z16-fmvt-none.webp)](results/shots/2026-10-12-android/munich-z16-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16](results/shots/2026-10-12-android/munich-z16-fmvt-raster-none.webp)](results/shots/2026-10-12-android/munich-z16-fmvt-raster-none.webp) |
| `munich-z16-rot45` | [![flutter_map_vector_tiles, munich-z16-rot45](results/shots/2026-10-12-android/munich-z16-rot45-fmvt.webp)](results/shots/2026-10-12-android/munich-z16-rot45-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16-rot45](results/shots/2026-10-12-android/munich-z16-rot45-fmvt-raster.webp)](results/shots/2026-10-12-android/munich-z16-rot45-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16-rot45](results/shots/2026-10-12-android/munich-z16-rot45-vmt-raster.webp)](results/shots/2026-10-12-android/munich-z16-rot45-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16-rot45](results/shots/2026-10-12-android/munich-z16-rot45-vmt-vector.webp)](results/shots/2026-10-12-android/munich-z16-rot45-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16-rot45](results/shots/2026-10-12-android/munich-z16-rot45-fmvt-none.webp)](results/shots/2026-10-12-android/munich-z16-rot45-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16-rot45](results/shots/2026-10-12-android/munich-z16-rot45-fmvt-raster-none.webp)](results/shots/2026-10-12-android/munich-z16-rot45-fmvt-raster-none.webp) |
| `munich-z17.5` | [![flutter_map_vector_tiles, munich-z17.5](results/shots/2026-10-12-android/munich-z17.5-fmvt.webp)](results/shots/2026-10-12-android/munich-z17.5-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z17.5](results/shots/2026-10-12-android/munich-z17.5-fmvt-raster.webp)](results/shots/2026-10-12-android/munich-z17.5-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z17.5](results/shots/2026-10-12-android/munich-z17.5-vmt-raster.webp)](results/shots/2026-10-12-android/munich-z17.5-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z17.5](results/shots/2026-10-12-android/munich-z17.5-vmt-vector.webp)](results/shots/2026-10-12-android/munich-z17.5-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z17.5](results/shots/2026-10-12-android/munich-z17.5-fmvt-none.webp)](results/shots/2026-10-12-android/munich-z17.5-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z17.5](results/shots/2026-10-12-android/munich-z17.5-fmvt-raster-none.webp)](results/shots/2026-10-12-android/munich-z17.5-fmvt-raster-none.webp) |
| `munich-z18` | [![flutter_map_vector_tiles, munich-z18](results/shots/2026-10-12-android/munich-z18-fmvt.webp)](results/shots/2026-10-12-android/munich-z18-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z18](results/shots/2026-10-12-android/munich-z18-fmvt-raster.webp)](results/shots/2026-10-12-android/munich-z18-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z18](results/shots/2026-10-12-android/munich-z18-vmt-raster.webp)](results/shots/2026-10-12-android/munich-z18-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z18](results/shots/2026-10-12-android/munich-z18-vmt-vector.webp)](results/shots/2026-10-12-android/munich-z18-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z18](results/shots/2026-10-12-android/munich-z18-fmvt-none.webp)](results/shots/2026-10-12-android/munich-z18-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z18](results/shots/2026-10-12-android/munich-z18-fmvt-raster-none.webp)](results/shots/2026-10-12-android/munich-z18-fmvt-raster-none.webp) |

Raw data: [results/raw/2026-10-12-android/results.jsonl](results/raw/2026-10-12-android/results.jsonl).

What the screenshots show, beyond frame counts:

- `vector_map_tiles` draws more labels at the same camera (compare the
  `munich-z16` row): it evaluates the style one level deeper than
  MapLibre does. The `TileOffset.none` columns show this package drawing
  that denser set.
- Baked labels, in both packages, turn with the map (`munich-z16-rot45`)
  and are dropped where they would cross a tile edge. This package's
  default keeps text upright and collides across tile edges.
- `vector_map_tiles` 9 draws Liberty's dashed paths solid and leaves out
  one-way arrows and road shields; this package draws all three as the
  style defines them.

## Earlier sessions

Kept as raw data under `results/raw/`, with their screenshots, where
they have any, in `results/shots/`. None of them is comparable with the
session above:

| session | arms | why it is superseded |
|---|---|---|
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
complete map took 2.9 s in `2026-10-11-split-android` and 2.8 s here,
its settle times are the same, and its cold zoom went from 75.0 % to
76.3 %. This package never went more than 55 ms without a frame after a
camera jump, so its numbers were not affected. The window has been 4 s
since 31e7d17.
