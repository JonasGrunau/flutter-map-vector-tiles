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

Frames delivered while the map moves, this package / `vector_map_tiles`:

| | Android phone | iPhone | Mac | Chrome |
|---|---:|---:|---:|---:|
| Labels baked into the tiles | 94–98% / 74–99% | 99–100% / 96.8–100% | 97.5–100% / 99–100% | 94–100% / 39–100% |
| Labels drawn every frame | 78–86% / 20–40% | 99–100% / 65–99.8% | 97–100% / 57–100% | 91–100% / 3–68% |
| First complete map, baked labels | 0.95 / 3.0 s | 0.36 / 1.74 s | 0.34 / 0.98 s | 1.25 / 2.6 s |

## What this means

With labels baked into the tiles, both packages are smooth on the
iPhone and the Mac. The difference shows on the Android phone and in
Chrome. On the phone this package got 16 to 22 points more frames on the
first zoom, the first pan and while flinging. In Chrome it was 39 points
ahead on the first zoom and 58 on the first fling, passes on which
`vector_map_tiles` stalled 15 to 47 times.

With labels drawn every frame, the gap is wide everywhere except panning
on the Mac and the iPhone. `vector_map_tiles`' vector mode got 20 to 40%
of frames on the Android phone, about 3% when flinging in Chrome, and 57
to 71% while zooming or flinging on the Mac and the iPhone. This package
got 78 to 86% on the phone and above 90% everywhere else.

With baked labels, the first complete map appeared 2 to 5 times sooner
with this package, on every platform.

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
