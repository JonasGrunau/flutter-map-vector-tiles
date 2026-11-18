# flutter_map_vector_tiles and vector_map_tiles, side by side

This is the short version of [RESULTS.md](RESULTS.md). Both packages
drew the same OpenFreeMap style from the same recorded tiles, along the
same scripted camera paths (zoom, pan, rotate, fling), with a fresh app
process for every run. `vector_map_tiles` is version 9.0.0-beta.13, the
newest one that runs flutter_map 8 on stable Flutter. The runs covered
four platforms: a Nothing Phone (1), a mid-range Android phone at 60 Hz;
an iPhone 15 Pro Max at 120 Hz; a MacBook Pro with an M4 Pro at 120 Hz;
and Chrome on that Mac. This package was measured once more with its
3D buildings switched on.

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
| Frames delivered while zooming | **94–95%** / 75–88% | **99.8–100%** / 97–99.6% | 98–99.6% / 99–100% | **96–98%** / 57–88% |
| … while panning | **95–97%** / 80–98% | 99.6–99.7% / 99.7–100% | 99.7–99.9% / 100% | **97–99%** / 77–100% |
| … while rotating | **96–98%** / 89–98% | 99.6–100% / 99.7–100% | 100% / 99.9–100% | **98–99.9%** / 87–99.9% |
| … while flinging | **95–98%** / 75–76% | **99.8–100%** / 98–99.5% | 99.6–99.9% / 99–99.9% | **98–99%** / 41–78% |
| Longest pause between two frames | **117** / 251 ms | **18** / 38 ms | **25** / 42 ms | **117** / 158 ms |
| First complete map | **0.68** / 2.75 s | **0.35** / 1.74 s | **0.28** / 0.93 s | **1.12** / 2.49 s |
| Peak memory (RSS) | **318** / 377 MB | **265** / 374 MB | **413** / 611 MB | not measured |
| Peak GPU memory | **277** / 297 MB | not measured | not measured | not measured |
| **Labels drawn every frame** (default / vector mode) |  |  |  |  |
| Frames delivered while zooming | **96%** / 34–35% | **99.9–100%** / 72% | **97–99%** / 67% | **95–97.5%** / 19% |
| … while panning | **92.5–93%** / 40% | 99.7–99.8% / 99.6–99.8% | 99.4–99.6% / 99.9% | **96–100%** / 75–76% |
| … while rotating | **91–96%** / 20–21% | **99.5–100%** / 90–92% | **100%** / 64–65% | **97–99.9%** / 14–15% |
| … while flinging | **92.5–95%** / 21–22% | **99.9–100%** / 67% | **99–100%** / 66–67% | **95–96%** / 3% |
| Longest pause between two frames | **100** / 1304 ms | **17** / 133 ms | **33** / 183 ms | **42** / 833 ms |
| Longest wait for the map to go still after moving | **0.35** / 5.0 s | **0.3** / 1.1 s | **0.3** / 1.3 s | **0.3** / 3.3 s |
| First complete map | **0.81** / 1.87 s | **0.49** / 1.21 s | **0.30** / 0.95 s | **1.14** / 1.74 s |
| Peak memory (RSS) | **347** / 873 MB | **277** / 841 MB | **409** / 1001 MB | not measured |
| Peak GPU memory | 376 / 374 MB | not measured | not measured | not measured |
| **Network** (this package / raster mode) |  |  |  |  |
| Downloaded per run | **27.3** / 53.1 MB | **27.3** / 53.2 MB | **27.2** / 51.3 MB | **29.9** / 32.6 MB¹ |

The longest pause is the longest gap between two frames in any of the
movements; at 60 Hz a frame is due every 17 ms, at 120 Hz every 8 ms.
The wait to go still is how long tiles and labels kept changing after
the camera stopped. With baked labels both packages went still within
half a second everywhere.

¹ Chrome's HTTP cache answers a repeated request, so this counts each
address once.

## What 3D buildings cost

`ExtrusionMode.perspective` draws Liberty's 3D buildings the way
MapLibre GL draws them when the camera looks straight down, every frame
(the cells read 3D buildings / this package's default, both with labels
drawn every frame). `vector_map_tiles` has no 3D buildings.

| | Android phone | iPhone | Mac | Chrome |
|---|---:|---:|---:|---:|
| Frames delivered while moving | 84–92% / 91–96% | 99.5–100% / 99.5–100% | 98–100% / 97–100% | 89–100% / 95–100% |
| Longest pause between two frames | 84 / 100 ms | 20 / 17 ms | 33 / 33 ms | 75 / 42 ms |
| First complete map | 0.89 / 0.81 s | 0.47 / 0.49 s | 0.39 / 0.30 s | 1.06 / 1.14 s |
| Peak memory (RSS) | 436 / 347 MB | 337 / 277 MB | 426 / 409 MB | not measured |
| Peak GPU memory | 406 / 376 MB | not measured | not measured | not measured |

On the iPhone and the Mac they cost no frames. On the Android phone they
cost 3 to 4.5 points while zooming and rotating and 7 to 9 while panning
and flinging, and in Chrome 6 points on the first fling and up to
2.3 elsewhere.

## What this means

With labels baked into the tiles, both packages are smooth on the
iPhone and the Mac. The difference shows on the Android phone and in
Chrome. On the phone this package got 15 to 22 points more frames on the
first zoom, the first pan and while flinging. In Chrome it was 39 points
ahead on the first zoom and 57 on the first fling, passes on which
`vector_map_tiles` stalled 25 and 45 times.

With labels drawn every frame, the gap is wide everywhere except panning
on the Mac and the iPhone. `vector_map_tiles`' vector mode got 20 to 40%
of frames on the Android phone and 3% when flinging in Chrome. On the
Mac and the iPhone it got 66 to 72% while zooming or flinging, and 64 to
65% while rotating on the Mac. This package got 91 to 96% on the phone
and 95% or more everywhere else.

The first complete map appeared 2 to 5 times sooner with this package
with baked labels, and 1.5 to 3 times sooner with labels drawn every
frame, on every platform.

In raster mode, `vector_map_tiles` downloaded about twice as much per run
on the phones and the Mac (51 to 53 MB against 27 MB). It also used more
memory throughout: in vector mode 2.4 to 3 times as much (841 against
277 MB on the iPhone, 873 against 347 MB on the Android phone, 1001
against 409 MB on the Mac), and with baked labels 19 to 48% more (377
against 318 MB on the Android phone, 611 against 413 MB on the Mac).

Against the October sessions, with 2.9.1, this package's default got 6
to 15 points more frames on the Android phone, and its `TileOffset.none`
setting, which draws as many labels as `vector_map_tiles` does, 25 to 39
points more while rotating there and in Chrome. `vector_map_tiles`, the
same version both times, moved by at most 2.4 points with baked labels.

## Where vector_map_tiles is ahead

- It saves every tile it has drawn as a PNG on disk, so going back over
  the same area, even after a restart, shows finished tiles. On a
  repeated pan with baked labels it got 98.2% of frames on the Android
  phone and 100% in Chrome, this package 97.2% and 98.8%.
- On the Mac, with baked labels, it was 0.4 to 0.8 points ahead while
  zooming: within the tie margin, but on both passes.

This package's weakest setting is 3D buildings on the Android phone:
84 to 92% of frames, 3 to 9 points under its default. That is still
ahead of raster mode on both zoom passes, the first pan and while
flinging, and 2 to 4.5 times vector mode, which draws the buildings
flat.

## What the maps look like

At the same zoom, `vector_map_tiles` draws more labels, because it reads
the style one zoom level deeper than MapLibre does. This package matches
MapLibre by default, and `TileOffset.none` makes it read the style as
`vector_map_tiles` does. Next to MapLibre GL JS rendering the same
style, this package draws Liberty's dashed lines, road shields and
one-way arrows. `vector_map_tiles` 9 draws dashed lines solid, leaves out
shields and arrows, and checks labels for collisions only within each
tile. With `ExtrusionMode.perspective` this package also draws Liberty's
3D buildings as MapLibre does from straight above; `vector_map_tiles`
draws them flat. The screenshots are in [RESULTS.md](RESULTS.md).

## Limits

- There is one device per platform.
- All four sessions were built from one commit (7dd024a, 2.11.0 with 3D
  buildings) and measured on the same night, 3 November 2026, the two
  phones side by side.
- The `vector_map_tiles` 10.0.0 betas
  ([`10.0.0-beta.1` and `-beta.2`](https://pub.dev/packages/vector_map_tiles/versions),
  October 2025) are not included, because
  [their README](https://github.com/greensopinion/flutter-vector-map-tiles#version-1000-beta)
  says they need `flutter_gpu` from Flutter's main channel.

## Check it yourself

The [web demo](https://jonasgrunau.github.io/flutter-map-vector-tiles/)
switches between the packages and runs a short version of the benchmark
in your browser, with no setup. To repeat the full sessions on your own
devices, follow [Reproducing the results](README.md#reproducing-the-results).
Every session's raw data is in [results/raw/](results/raw/).
