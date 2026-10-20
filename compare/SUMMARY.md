# flutter_map_vector_tiles and vector_map_tiles, side by side

This is the short version of [RESULTS.md](RESULTS.md). Both packages
drew the same OpenFreeMap style from the same recorded tiles, along the
same scripted camera paths (zoom, pan, rotate, fling), with a fresh app
process for every run. `vector_map_tiles` is version 9.0.0-beta.13, the
newest one that runs flutter_map 8 on stable Flutter. The runs covered
four platforms: a Nothing Phone (1), a mid-range Android phone at 60 Hz;
an iPhone 15 Pro Max at 120 Hz; a MacBook Pro with an M4 Pro at 120 Hz;
and Chrome on that Mac.

## How to read the numbers

The main number is frames delivered: of all the times the screen
refreshed while the map was moving, how often there was a new frame to
show. 100% is perfectly smooth. At 60 Hz, 80% means about 12 skipped
frames every second, which you see as stutter.

Both packages can draw labels in two ways, and each comparison below
pairs like with like.

- Labels baked into the tiles: each label is drawn once, into its
  tile's image, so moving the map costs almost nothing. The labels turn
  with the map, and they avoid each other only within one tile. This is
  `vector_map_tiles`' default, which it calls raster mode, and
  `LabelMode.tile` in this package.
- Labels drawn every frame: this is this package's default, and here
  its labels stay upright, are sized for the exact zoom and avoid each
  other across the whole screen, at the price of work on every frame.
  `vector_map_tiles` calls its version vector mode, and redraws the
  roads and buildings every frame as well.

## Results

Each cell reads this package / `vector_map_tiles`. A range covers the
first and the second pass over the same ground; each number is the
median over the runs. Bold marks the better of the two: at least 1
point more frames, or at least 5% less time, memory or download.
Anything closer counts as a tie, and neither is bold.

| | Android phone | iPhone | Mac | Chrome |
|---|---:|---:|---:|---:|
| **Labels baked into the tiles** (`LabelMode.tile` / raster mode) |  |  |  |  |
| Frames delivered while zooming | **94–95%** / 75–91% | 99.7–99.8% / 98–99.6% | 97–99% / **99–100%** | **94–96%** / 54–88% |
| … while panning | **95–98%** / 79–99% | 99–99.9% / 99.7–100% | 99.7–99.8% / 99.8–100% | **97–100%** / 75–100% |
| … while rotating | **94–98%** / 90–99% | 99–100% / 99.7–100% | 99.8–100% / 99.9–100% | **98–100%** / 86–100% |
| … while flinging | **94–96%** / 74% | **99.6–100%** / 98–99% | 100% / 99–100% | **96–99.9%** / 39–75% |
| Longest pause between two frames | **84** / 251 ms | **29** / 45 ms | 50 / **33** ms | **34** / 159 ms |
| First complete map | **0.95** / 2.99 s | **0.36** / 1.74 s | **0.34** / 0.98 s | **1.25** / 2.59 s |
| Peak memory (RSS) | 391 / 401 MB | **336** / 387 MB | **495** / 577 MB | not measured |
| Peak GPU memory | **264** / 313 MB | not measured | not measured | not measured |
| **Labels drawn every frame** (default / vector mode) |  |  |  |  |
| Frames delivered while zooming | **85%** / 35% | **99.8–99.9%** / 69–71% | **97–98%** / 65% | **91–94%** / 17% |
| … while panning | **79%** / 40% | 99.6–100% / 99.7–99.8% | 99–99.7% / 100% | **95–100%** / 67–68% |
| … while rotating | **78–81%** / 20–21% | **99–100%** / 84–90% | **99.8–100%** / 57–58% | **95–99.8%** / 12–14% |
| … while flinging | **82–86%** / 21–22% | **99.7–99.8%** / 66–67% | **99–100%** / 63–64% | **93–95%** / 3% |
| Longest pause between two frames | **134** / 1373 ms | **18** / 182 ms | **42** / 167 ms | **42** / 858 ms |
| Longest wait for the map to go still after moving | **0.3** / 4.4 s | **0.3** / 1.1 s | **0.3** / 1.3 s | **0.3** / 3.5 s |
| First complete map | **1.05** / 1.89 s | **0.50** / 1.19 s | **0.47** / 0.96 s | **1.22** / 1.93 s |
| Peak memory (RSS) | **393** / 892 MB | **335** / 836 MB | **527** / 948 MB | not measured |
| Peak GPU memory | 365 / 376 MB | not measured | not measured | not measured |
| **Network** (this package / raster mode) |  |  |  |  |
| Downloaded per run | **12.8** / 20.4 MB¹ | **26.7** / 50.3–55.0 MB | **26.6** / 51.2–51.6 MB | **29.3** / 32.6 MB² |

The longest pause is the longest gap between two frames in any of the
movements; at 60 Hz a frame is due every 17 ms, at 120 Hz every 8 ms.
The wait to go still is how long tiles and labels kept changing after
the camera stopped. With baked labels both packages went still within
half a second everywhere.

¹ Android counts only opening the map and the measured movements, not
the jumps between them. The other platforms count whole runs.

² Chrome's HTTP cache answers a repeated request, so this counts each
address once.

## What this means

With labels baked into the tiles, both packages are smooth on the
iPhone and the Mac. The difference shows on the Android phone and in
Chrome. On the phone this package got 16 to 22 points more frames on the
first zoom, the first pan and while flinging. In Chrome it was 39 points
ahead on the first zoom and 58 on the first fling, passes on which
`vector_map_tiles` stalled 15 to 47 times.

With labels drawn every frame, the gap is wide everywhere except panning
on the Mac and the iPhone. `vector_map_tiles`' vector mode got 20 to 40%
of frames on the Android phone and about 3% when flinging in Chrome. On
the Mac and the iPhone it got 63 to 71% while zooming or flinging, and
57 to 58% while rotating on the Mac. This package got 78 to 86% on the
phone and above 90% everywhere else.

The first complete map appeared 2 to 5 times sooner with this package
with baked labels, and 1.6 to 2.4 times sooner with labels drawn every
frame, on every platform.

In raster mode, `vector_map_tiles` downloaded about twice as much per run
on the iPhone and the Mac (50 to 55 MB against 27 MB). It also used more
memory throughout: in vector mode more than twice as much (836 against
335 MB on the iPhone, 892 against 393 MB on the Android phone), and with
baked labels a little more (387 against 336 MB on the iPhone).

## Where vector_map_tiles is ahead

- It saves every tile it has drawn as a PNG on disk, so going back over
  the same area, even after a restart, shows finished tiles. On a
  repeated pan on the Android phone with baked labels it got 98.7% of
  frames, this package 97.7%.
- On the Mac, with baked labels, it was 1.4 to 1.7 points ahead while
  zooming.

This package's weak spot is rotating with labels drawn every frame and
`TileOffset.none`, the setting that makes it draw as many labels as
`vector_map_tiles` does. It got 69 to 75% of frames that way in Chrome,
and on the Android phone 29 to 30 points less than with its default
setting, though still more than vector mode.

## What the maps look like

At the same zoom, `vector_map_tiles` draws more labels, because it reads
the style one zoom level deeper than MapLibre does. This package matches
MapLibre by default, and `TileOffset.none` makes it read the style as
`vector_map_tiles` does. Next to MapLibre GL JS rendering the same
style, this package draws Liberty's dashed lines, road shields and
one-way arrows. `vector_map_tiles` 9 draws dashed lines solid, leaves out
shields and arrows, and checks labels for collisions only within each
tile. The screenshots are in [RESULTS.md](RESULTS.md).

## Limits

- There is one device per platform.
- The Android, Mac and Chrome sessions were built from one commit
  (c1dc45c). The iPhone session ran a week later on a newer build, with
  two label fixes and a change to how fill outlines are drawn.
- The `vector_map_tiles` 10.0.0 betas are not included, because they
  need Flutter's main channel.

## Check it yourself

The [web demo](https://jonasgrunau.github.io/flutter-map-vector-tiles/)
switches between the packages and runs a short version of the benchmark
in your browser, with no setup. To repeat the full sessions on your own
devices, follow [Reproducing the results](README.md#reproducing-the-results).
Every session's raw data is in [results/raw/](results/raw/).
