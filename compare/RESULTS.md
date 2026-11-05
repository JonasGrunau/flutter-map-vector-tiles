# Results

How `flutter_map_vector_tiles` and `vector_map_tiles` 9.0.0-beta.13 compare,
measured with this directory's harness (method and arms: [README.md](README.md)).

**Status, 2026-11-04:** complete sessions on Android, iOS, macOS and
Chrome, all built from 7dd024a (2.11.0 with 3D buildings) and measured
on 2026-11-03 and -04, each with the six arms of October plus a
seventh, `fmvt-3d` (`ExtrusionMode.perspective`), and with MapLibre GL
JS rendering the same cameras next to the Chrome screenshots. Every
run replayed the tiles the October sessions replayed. Those sessions
(2.9.1), and the first macOS and Chrome attempts before them, are
listed under [Earlier sessions](#earlier-sessions).

**Correction, 2026-10-13:** the request and download figures this page
gave "per run" counted only the opening and the measured passes, not the
jump to each scenario's start; on macOS and in Chrome whole runs fetched
2.1 to 4.4 times as much. They are relabelled below, next to the lab
server's whole-run counts for macOS and Chrome; Android's were not kept.

The two packages draw labels in different ways, so the arms pair up by
strategy, not by default. Labels baked into the tile images:
`fmvt-raster` (this package with `LabelMode.tile`) against `vmt-raster`
(`vector_map_tiles`' default). Labels drawn every frame: `fmvt` (this
package's default) against `vmt-vector`.

## What the Android session shows

- **Labels baked into the tiles.** This package got a frame on 94.1–98.3 %
  of display refreshes in every scenario, `vector_map_tiles` on
  74.8–98.3 %. It is 15–22 points ahead on the first pass (cold) of zoom
  and pan and on both passes of fling, 7 points ahead on the second pass
  of zoom and the first of rotate, and level, within 1 point, on the
  second pass of pan and rotate, where `vector_map_tiles` shows tiles it
  has already drawn. It stalls 1–8 times per pass against 2–46, with a
  worst stall of 50–117 ms against 67–251 ms. Both UI threads need about
  the same time per frame (p90 3.6–9.2 ms against 5.0–10.8 ms).
- **Labels drawn every frame.** This package got 91.2–96.1 % of frames
  against vector mode's 19.5–40.2 %, 2.3 to 4.7 times as many. Its worst
  stall is 100 ms, on the first rotation, where vector mode's runs to
  1.3 s, and vector mode keeps repainting for 1.2–5.0 s after a zoom,
  rotation or fling stops. Against October's 2.9.1 this package gained
  6–15 points here, while the unchanged `vector_map_tiles` arms moved
  by at most 2.3; the CHANGELOG lists what changed in between.
- **What live labels cost this package:** 2–4.5 points of frames while
  panning, rotating and flinging, the difference between its two label
  modes, and none while zooming, where the default is about 1 point
  ahead; its UI-thread p90 is 10.5–12.8 ms instead of 3.6–9.2 ms. That
  buys text that stays upright under rotation, is sized for the exact
  zoom, is collision-checked across tile edges and fades per label
  (root README, "Choosing a label mode").
- **The content controls** (`TileOffset.none`: this package evaluating
  the style one level deeper, as `vector_map_tiles` does, so it draws the
  same extra label layers). With baked labels the extra labels cost
  nothing measurable: `fmvt-raster-none` is within 1.6 points of
  `fmvt-raster` everywhere, so against `vmt-raster` on equal content the
  picture is the same. With live labels they cost 3.5–7.5 points
  (`fmvt-none` 84.6–91.8 %), most while rotating and on the second
  fling, because every label is drawn every frame; that is 2.2 to 4.4
  times vector mode. In October rotating cost 29–30 points.
- **3D buildings** (`fmvt-3d`, `ExtrusionMode.perspective`: the default
  with Liberty's `building-3d` layer drawn as MapLibre draws it from
  straight above, a mesh per frame instead of flat in the tiles). It got
  83.8–92.4 %: 3–4.5 points under the default while zooming and
  rotating, 7–9 while panning and flinging, where every frame moves more
  walls across the screen. Its worst stall is 67–84 ms, its UI-thread
  p90 12.9–18.3 ms against the default's 10.5–12.8 ms. It is still
  ahead of `vector_map_tiles`' raster mode on both zoom passes, the
  first pan and both flings (by 4–16 points), and behind it on the
  second pan and on rotation (by 1–14), where raster mode shows tiles
  it has already drawn. Against vector mode, which draws the buildings
  flat, it gets 2.1 to 4.5 times as many frames.
- **Opening the map:** the first complete map took 0.68 s with baked
  labels, 0.81 s by default and 0.89 s with 3D buildings, against 2.75 s
  (raster mode) and 1.87 s (vector mode). A whole run sent 76 requests
  for 27.3 MB with this package, 105 for 53.1 MB in raster mode and 71
  for 40.1 MB in vector mode.
- **Settling:** with baked labels this package stops repainting 16–17 ms
  after the camera stops. Raster mode takes 16–18 ms, and 149–185 ms
  after the first pan and after a fling. With live labels this package
  takes 0.27–0.35 s: the 150 ms label fade plus the placement interval.
- **Memory:** with baked labels this package uses less: peak RSS 318
  against 377 MB, and a peak GPU allocation of 277 against 297 MB (RSS
  on this phone does not include GPU memory, so it is sampled
  separately, below the tables). By default it needs 347 MB of RSS
  against vector mode's 873 MB and about as much GPU memory (376 against
  374 MB); with 3D buildings 436 MB and 406 MB, with the buildings'
  meshes. With `TileOffset.none` peak RSS is 359 MB, where
  October's 2.9.1 climbed to 488–516 MB: its label text cache holds up
  to 8000 shaped labels, and since 2.10.0 most of Liberty's are runs of
  the style's glyphs rather than platform paragraphs. Much of the
  default's extra GPU memory goes to its label fades, which draw fading
  labels through translucent layers: in an October A/B (2.9.1,
  `results/raw/2026-10-12-c1dc45c-fades-android`),
  `labelFadeDuration: Duration.zero` took the peak from 391–409 to
  317–320 MB, but frames fell from 75.8–88.1 % to 56.5–85.2 %, because
  the collision pass then runs every frame instead of every 150 ms.
  `VectorTileLayer.clearMemoryCache()` trims the text cache; RSS fell
  23–43 MB within 3 s (`results/raw/2026-10-20-trim-android`, 2.9.1).

## What the macOS session shows

- **Labels baked into the tiles.** Both packages get nearly every frame:
  this package 98.4–100 %, `vector_map_tiles` 99.1–100 %. They are
  level, within 1 point, everywhere; `vector_map_tiles` is 0.8 points
  ahead on the first zoom. Neither stalls; the worst gap is 25 ms
  against 42 ms.
- **Labels drawn every frame.** This package got 97.4–100 %, vector mode
  64.0–99.9 %: vector mode keeps up while panning, but gets 64–67 %
  while zooming, rotating and flinging, with gaps of up to 183 ms,
  against this package's 33 ms. Vector mode's raster thread needs
  15.9–20.4 ms per frame there (p90) against a budget of 8.3 ms at
  120 Hz; this package's needs 1.3–1.6 ms, and its UI thread 2.3–3.0 ms.
  With the denser `TileOffset.none` content this package gets
  96.4–100 %.
- **On this machine the label strategy hardly matters for this package:**
  its two label modes are within 1 point of each other everywhere.
- **3D buildings** (`fmvt-3d`) cost nothing measurable here: 98.2–100 %,
  within 1 point of the default, with a UI-thread p90 of 2.4–2.8 ms.
- **Opening the map:** 0.28 s with baked labels, 0.30 s by default and
  0.39 s with 3D buildings, against 0.93 s (raster mode) and 0.95 s
  (vector mode). A whole run downloaded 27.2 MB in 77 requests for this
  package, 51.3 MB in 111 for raster mode and 51.4 MB in 92 for vector
  mode.
- **Settling:** one frame (8 ms) with baked labels, for both packages.
  With live labels this package takes 223–284 ms, the label fade plus
  the placement interval, and vector mode 91–99 ms after a pan and
  0.54–1.27 s after a zoom, rotation or fling.
- **Memory:** peak RSS 413 MB with baked labels against raster mode's
  611 MB, and 409 MB by default against vector mode's 1001 MB; 425 and
  445 MB with `TileOffset.none`, 426 MB with 3D buildings. GPU memory
  was not sampled on macOS.

## What the Chrome session shows

- **Labels baked into the tiles.** This package got 95.5–99.9 % of
  frames, `vector_map_tiles` 40.8–100 %. They are level on the second
  pass of pan and rotate, where `vector_map_tiles` shows tiles it has
  already drawn (99.9–100 % against 98.8–99.9 %); everywhere else this
  package is 10–57 points ahead, most on the first pass of zoom
  (39 points) and fling (57). `vector_map_tiles` stalls 15–45 times on
  those passes, with gaps of up to 158 ms, though its frames themselves
  are short (UI p90 1.6–2.4 ms): the stalls are work between frames,
  which `FrameTiming` does not see (README.md, Method). This package
  stalls once, on the second pan (117 ms); its other worst gaps are
  13–41 ms.
- **Labels drawn every frame.** This package got 95.1–100 %, vector mode
  3.1–75.6 %. Flinging, vector mode gets 3.1–3.2 % of frames, with a
  raster-thread p90 of 697–703 ms. The worst gap is 42 ms against 833 ms.
- **`TileOffset.none` is no longer a weak spot:** with the extra label
  layers this package gets 90.8–100 %, and 97.1–100 % while rotating,
  where 2.9.1 got 69–75 % in October.
- **3D buildings** (`fmvt-3d`) got 89.3–100 %: within 2.3 points of the
  default, except on the first fling, 5.8 points under. It stalls 1–4
  times on the first zoom, rotation and fling, where the default does
  not; its worst gap is 75 ms, on the first rotation, and its UI-thread
  p90 reaches 12.6 ms against the default's 9.7 ms.
- **Opening the map:** 1.12 s with baked labels, 1.14 s by default and
  1.06 s with 3D buildings, against 2.49 s (raster mode) and 1.74 s
  (vector mode).
- **Requests:** in the browser the HTTP cache answers a repeated request,
  so the lab server sees each URL once per run. A whole run sent 88
  requests (29.9 MB) for this package, 90 (32.6 MB) for raster mode and
  45 (18.8 MB) for vector mode. On macOS, in a smaller window and with
  no HTTP cache, `vector_map_tiles` sent 111 and 92: more than the
  distinct URLs it needed for the larger browser window, so there it
  fetched some tiles again. This package sent 77.
- **Settling:** with baked labels this package's last repaint comes
  0–49 ms after the camera stops, and 249 ms after the first pan, while
  the last tiles arrive; raster mode's 0–16 ms, and 170–366 ms after a
  pan. With live labels this package takes 192–299 ms, vector mode
  0.5–3.3 s. There is no memory figure: the browser does not give a
  page its process's RSS.

## What the iOS session shows

- **Labels baked into the tiles.** Both packages get nearly every frame:
  this package 99.6–100 %, `vector_map_tiles` 97.3–100 %. They are within
  0.5 points of each other everywhere except the first pass of zoom and
  fling, where this package is 2.5 and 1.5 points ahead. Neither stalls;
  the worst gaps are 18 ms against 38 ms.
- **Labels drawn every frame.** This package got 99.5–100 %, vector mode
  66.7–99.8 %: vector mode keeps up while panning, but gets 67–72 % while
  zooming and flinging and 89.5–92 % while rotating, with gaps of up to
  133 ms against this package's 17 ms. Its raster thread needs
  9.3–11.2 ms per frame there (p90), over the budget of 8.3 ms at 120 Hz,
  and its UI thread up to 14.1 ms; this package's need 0.7–0.8 ms and
  2.3–2.8 ms. With the denser `TileOffset.none` content this package
  gets 99.1–100 % (94.1–99.2 % in October, with 2.9.1).
- **The label strategy hardly matters for this package here:** its two
  label modes are within 0.1 points of each other everywhere.
- **3D buildings** (`fmvt-3d`) cost nothing measurable here: 99.5–100 %,
  within 0.4 points of the default, with a UI-thread p90 of 2.4–3.1 ms
  against 2.3–2.8 ms.
- **Opening the map:** 0.35 s with baked labels, 0.49 s by default and
  0.47 s with 3D buildings, against 1.74 s (raster mode) and 1.21 s
  (vector mode). A whole run downloaded 27.3 MB in 76 requests for this
  package, 53.2 MB in 109 for raster mode and 44.5 MB in 80 for vector
  mode.
- **Settling:** with baked labels, one frame (8 ms) after a pan, a
  rotation and a fling for this package, 120–124 ms after a zoom; raster
  mode one frame after a pan and a rotation, 108–116 ms after a zoom and
  58–71 ms after a fling. With live labels this package takes
  175–304 ms, vector mode 16 ms after a pan and 0.9–1.15 s after a zoom,
  rotation or fling.
- **Memory:** peak RSS 265 MB with baked labels against raster mode's
  374 MB, and 277 MB by default against vector mode's 841 MB; 287 and
  309 MB with `TileOffset.none`, 337 MB with 3D buildings. GPU memory
  was not sampled on iOS.

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
- The October build (2.9.1) drew road-number shields on road pieces
  too short to hold them, around Karlsplatz in `munich-z16`, and broke a
  word wider than `text-max-width` (`munich-z14` read LUDWIGSVORST /
  ADT). Both were fixed in 2.10.0 and are gone from these screenshots.
  This package still shows fewer POI names than MapLibre in
  `munich-z16`, among them Nationaltheater and Lenbachplatz.
- MapLibre draws Liberty's `building-3d` layer as extrusions, so even
  looking straight down the walls show around the edge of the screen.
  `vector_map_tiles` draws buildings flat, and so does this package by
  default; since 3D buildings (CHANGELOG, Unreleased) it draws them as
  MapLibre does when asked to (`ExtrusionMode.perspective`, the
  `fmvt-3d` column) — see *3D buildings* below.

### 3D buildings

Session `2026-11-03-3d-buildings-web`: Chrome on the M4 Pro, the web
runs' 1000×800 viewport at dpr 2, Liberty through the lab, compared with
MapLibre GL JS at the same cameras (`tool/reference_shots.mjs`), the 3D
columns from the `fmvt-3d` arm (`ExtrusionMode.perspective`; at the time
the default, so the session's files were taken as `fmvt`). Each
cell is the mean absolute difference per colour channel against MapLibre
over the whole 2000×1600 screenshot (labels included, so never zero),
then how well the wall pixels agree (grey pixels of 100–185, intersection
over union). `munich-z14` is style zoom 13, under `building-3d`'s
minzoom, where all three draw the same.

| camera | flat (2.11.0) | 3D, first build (83951ca) | 3D (6435766) | 3D (7dd024a) |
|---|---|---|---|---|
| `munich-z16` | 12.9 · 0.10 | 4.9 · 0.73 | 4.5 · 0.77 | 4.6 · 0.76 |
| `munich-z16-rot45` | 12.5 · 0.10 | 4.6 · 0.74 | 4.1 · 0.79 | 4.4 · 0.77 |
| `munich-z17.5` | 15.0 · 0.03 | 4.3 · 0.81 | 3.1 · 0.90 | 3.2 · 0.89 |
| `munich-z18` | 16.6 · 0.07 | 6.6 · 0.75 | 5.8 · 0.80 | 5.5 · 0.81 |

The second build hides the stretch of a wall that stands inside another
building — a taller building part rising out of its outline, both
starting on the ground — which the first drew over the lower roof. The
last column is the build the comparison measured, from its Chrome
session (`2026-11-03-7dd024a-web`, the screenshots below): the layers
above Liberty's first 3D layer, labels among them, now draw over the
buildings, as MapLibre draws them, and 3D buildings are opt-in.

| camera | MapLibre GL JS (reference) | flutter_map_vector_tiles · ExtrusionMode.perspective |
|---|:---:|:---:|
| `munich-z16` | [![MapLibre GL JS (reference), munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-maplibre.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-maplibre.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-3d.webp) |
| `munich-z16-rot45` | [![MapLibre GL JS (reference), munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-maplibre.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-maplibre.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-3d.webp) |
| `munich-z17.5` | [![MapLibre GL JS (reference), munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-maplibre.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-maplibre.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-3d.webp) |
| `munich-z18` | [![MapLibre GL JS (reference), munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-maplibre.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-maplibre.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-3d.webp) |


## Android · Nothing Phone (1)

Nothing A063 · Android 15 · portrait, on USB power, session
`2026-11-03-7dd024a-android`.

Flutter 3.44.5 · flutter_map_vector_tiles 2.11.0 (7dd024a) · vector_map_tiles 9.0.0-beta.13 · 411×914 logical px at dpr 2.625 · display 60 Hz · median of 3 runs per arm

**Frames delivered while the camera moves (higher is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 95.6 % <sub>94.4–95.7</sub> · 3 stalls | 90.9 % <sub>90.5–91.4</sub> · 10 stalls | 94.1 % <sub>93.5–94.2</sub> · 8 stalls | 94.2 % <sub>93.6–94.4</sub> · 5 stalls | 91.2 % <sub>88.4–91.3</sub> · 7 stalls | 75.0 % <sub>74.3–75.6</sub> · 46 stalls | 34.1 % <sub>33.3–34.9</sub> · 80 stalls |
| zoom · warm | 96.1 % <sub>95.1–96.1</sub> · 4 stalls | 91.7 % <sub>90.0–91.8</sub> · 7 stalls | 95.2 % <sub>94.7–95.9</sub> · 7 stalls | 94.6 % <sub>93.1–94.7</sub> · 8 stalls | 92.4 % <sub>91.3–93.0</sub> · 9 stalls | 88.4 % <sub>87.9–88.8</sub> · 24 stalls | 34.8 % <sub>34.7–34.9</sub> · 77 stalls |
| pan · cold | 92.5 % <sub>90.3–92.7</sub> · 4 stalls | 87.8 % <sub>87.3–89.8</sub> · 9 stalls | 94.8 % <sub>94.8–96.3</sub> · 6 stalls | 95.7 % <sub>95.2–95.8</sub> · 7 stalls | 83.8 % <sub>83.1–84.0</sub> · 5 stalls | 79.6 % <sub>79.1–80.6</sub> · 29 stalls | 40.2 % <sub>39.7–41.9</sub> · 95 stalls |
| pan · warm | 93.2 % <sub>91.3–94.7</sub> · 3 stalls | 89.7 % <sub>87.3–91.0</sub> · 4 stalls | 97.2 % <sub>96.7–97.7</sub> · 3 stalls | 97.5 % <sub>97.2–97.8</sub> · 3 stalls | 84.6 % <sub>84.0–85.5</sub> · 7 stalls | 98.2 % <sub>97.8–99.3</sub> · 2 stalls | 40.1 % <sub>39.9–40.2</sub> · 97 stalls |
| rotate · cold | 91.2 % <sub>90.0–93.0</sub> · 6 stalls | 84.6 % <sub>83.6–86.5</sub> · 12 stalls | 95.7 % <sub>95.0–95.8</sub> · 4 stalls | 94.3 % <sub>94.3–95.2</sub> · 7 stalls | 88.0 % <sub>87.2–89.0</sub> · 13 stalls | 88.7 % <sub>88.3–89.7</sub> · 16 stalls | 19.5 % <sub>19.5–19.8</sub> · 111 stalls |
| rotate · warm | 96.0 % <sub>95.8–96.5</sub> · 1 stall | 91.8 % <sub>91.2–92.0</sub> · 3 stalls | 98.3 % <sub>98.3–98.8</sub> · 1 stall | 97.7 % <sub>96.7–98.5</sub> · 2 stalls | 92.3 % <sub>92.2–92.8</sub> · 5 stalls | 98.3 % <sub>98.2–98.8</sub> · 2 stalls | 20.7 % <sub>20.7–20.9</sub> · 120 stalls |
| fling · cold | 92.5 % <sub>92.3–94.2</sub> · 3 stalls | 88.9 % <sub>85.8–89.1</sub> · 6 stalls | 94.6 % <sub>92.7–95.8</sub> · 2 stalls | 96.2 % <sub>94.8–96.3</sub> · 2 stalls | 84.3 % <sub>84.0–89.1</sub> · 7 stalls | 74.8 % <sub>73.3–76.4</sub> · 23 stalls | 20.5 % <sub>20.1–21.2</sub> · 64 stalls |
| fling · warm | 95.2 % <sub>94.6–95.6</sub> · 2 stalls | 87.7 % <sub>87.0–91.0</sub> · 8 stalls | 97.7 % <sub>97.1–98.3</sub> · 1 stall | 97.1 % <sub>95.4–97.7</sub> · 3 stalls | 88.1 % <sub>86.8–91.0</sub> · 7 stalls | 76.2 % <sub>73.7–77.5</sub> · 25 stalls | 21.8 % <sub>21.1–23.6</sub> · 60 stalls |

**Worst frame gap, ms (lower is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 83 | 67 | 117 | 67 | 84 | 251 | 1304 |
| zoom · warm | 67 | 67 | 67 | 67 | 67 | 167 | 1300 |
| pan · cold | 84 | 84 | 67 | 67 | 67 | 100 | 101 |
| pan · warm | 67 | 67 | 67 | 67 | 67 | 67 | 100 |
| rotate · cold | 100 | 100 | 67 | 83 | 84 | 134 | 417 |
| rotate · warm | 50 | 50 | 50 | 67 | 67 | 67 | 134 |
| fling · cold | 53 | 50 | 50 | 67 | 67 | 134 | 251 |
| fling · warm | 67 | 50 | 67 | 67 | 67 | 201 | 250 |

**UI thread p90 / raster thread p90, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 11.1 / 16.6 | 12.2 / 17.4 | 9.2 / 11.7 | 8.0 / 16.6 | 12.9 / 16.4 | 8.1 / 5.8 | 40.4 / 47.6 |
| zoom · warm | 11.1 / 16.5 | 12.0 / 17.5 | 8.0 / 4.7 | 8.0 / 12.4 | 12.9 / 16.7 | 5.4 / 16.1 | 39.2 / 53.3 |
| pan · cold | 12.6 / 5.4 | 14.1 / 10.1 | 8.5 / 4.2 | 8.0 / 4.3 | 18.3 / 11.4 | 7.8 / 9.7 | 7.5 / 55.3 |
| pan · warm | 12.8 / 5.8 | 14.1 / 7.8 | 8.3 / 3.9 | 8.6 / 3.9 | 17.7 / 14.5 | 5.0 / 3.0 | 6.8 / 60.0 |
| rotate · cold | 11.1 / 11.9 | 14.7 / 17.5 | 4.4 / 4.5 | 4.8 / 4.6 | 14.1 / 15.7 | 5.9 / 16.4 | 52.8 / 98.5 |
| rotate · warm | 10.5 / 15.2 | 13.5 / 17.1 | 3.7 / 3.7 | 3.7 / 3.7 | 13.5 / 16.1 | 5.9 / 3.1 | 43.1 / 96.6 |
| fling · cold | 12.5 / 17.7 | 14.6 / 16.7 | 7.9 / 4.8 | 7.8 / 4.8 | 15.4 / 16.8 | 10.8 / 5.5 | 87.4 / 124.1 |
| fling · warm | 11.3 / 18.1 | 14.3 / 17.7 | 3.6 / 3.9 | 3.8 / 4.8 | 13.9 / 17.6 | 9.8 / 6.4 | 92.2 / 117.7 |

**Settle: time from the camera stopping to the last repaint, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 266 | 332 | 16 | 512 | 317 | 17 | 3883 |
| zoom · warm | 269 | 400 | 16 | 396 | 255 | 16 | 5042 |
| pan · cold | 283 | 325 | 16 | 17 | 253 | 185 | 147 |
| pan · warm | 346 | 247 | 17 | 16 | 264 | 18 | 134 |
| rotate · cold | 285 | 238 | 16 | 17 | 208 | 16 | 1215 |
| rotate · warm | 270 | 319 | 17 | 16 | 225 | 17 | 1189 |
| fling · cold | 298 | 270 | 17 | 16 | 248 | 150 | 1374 |
| fling · warm | 268 | 268 | 16 | 16 | 282 | 149 | 1425 |

**Opening the map, network and memory**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| time to first complete map, ms | 808 | 860 | 676 | 670 | 885 | 2745 | 1872 |
| requests per run | 76 | 77 | 75 | 77 | 76 | 105 | 71 |
| MB downloaded per run | 27.3 | 28.5 | 27.2 | 28.5 | 27.3 | 53.1 | 40.1 |
| peak RSS, MB | 347 | 359 | 318 | 329 | 436 | 377 | 873 |

Requests and downloads count whole runs, as the lab server saw them
(the October session counted only the opening and the measured passes).

**GPU memory, MB** (peak per run, median of 3 <sub>range</sub>; not part of
`results.jsonl`, see below)

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| peak GPU allocation | 376 <sub>367–430</sub> | 404 <sub>403–415</sub> | 277 <sub>269–301</sub> | 273 <sub>269–273</sub> | 406 <sub>406–434</sub> | 297 <sub>268–311</sub> | 374 <sub>372–390</sub> |

Android's RSS does not include GPU memory on this phone, and tile images
live there. These figures come from `adb shell dumpsys gpu --gpumem`
(the `Proc <pid> total:` line for the app), sampled from the Mac every
~3 s for the whole of each run; spikes shorter than that can be missed.
Samples: [results/raw/2026-11-03-7dd024a-android/gpu-memory.txt](results/raw/2026-11-03-7dd024a-android/gpu-memory.txt).

**Screenshots** (fixed Munich cameras after round 0; click for full size)

| camera | flutter_map_vector_tiles | flutter_map_vector_tiles · LabelMode.tile | vector_map_tiles · raster | vector_map_tiles · vector | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `munich-z14` | [![flutter_map_vector_tiles, munich-z14](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt.webp)](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z14](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z14](results/shots/2026-11-03-7dd024a-android/munich-z14-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z14-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z14](results/shots/2026-11-03-7dd024a-android/munich-z14-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-android/munich-z14-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z14](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z14](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z14](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-android/munich-z14-fmvt-3d.webp) |
| `munich-z16` | [![flutter_map_vector_tiles, munich-z16](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16](results/shots/2026-11-03-7dd024a-android/munich-z16-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16](results/shots/2026-11-03-7dd024a-android/munich-z16-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-fmvt-3d.webp) |
| `munich-z16-rot45` | [![flutter_map_vector_tiles, munich-z16-rot45](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16-rot45](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16-rot45](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16-rot45](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16-rot45](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16-rot45](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16-rot45](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-android/munich-z16-rot45-fmvt-3d.webp) |
| `munich-z17.5` | [![flutter_map_vector_tiles, munich-z17.5](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt.webp)](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z17.5](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z17.5](results/shots/2026-11-03-7dd024a-android/munich-z17.5-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z17.5-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z17.5](results/shots/2026-11-03-7dd024a-android/munich-z17.5-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-android/munich-z17.5-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z17.5](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z17.5](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z17.5](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-android/munich-z17.5-fmvt-3d.webp) |
| `munich-z18` | [![flutter_map_vector_tiles, munich-z18](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt.webp)](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z18](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z18](results/shots/2026-11-03-7dd024a-android/munich-z18-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-android/munich-z18-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z18](results/shots/2026-11-03-7dd024a-android/munich-z18-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-android/munich-z18-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z18](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z18](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z18](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-android/munich-z18-fmvt-3d.webp) |

Raw data: [results/raw/2026-11-03-7dd024a-android/results.jsonl](results/raw/2026-11-03-7dd024a-android/results.jsonl),
notes in [notes.md](results/raw/2026-11-03-7dd024a-android/notes.md).

## macOS · MacBook Pro (M4 Pro)

Mac16,7 · Apple M4 Pro · macOS 27.0.1 · on AC power, the app's window in
front on the built-in display, session `2026-11-03-7dd024a-macos`.

Flutter 3.44.5 · flutter_map_vector_tiles 2.11.0 (7dd024a) · vector_map_tiles 9.0.0-beta.13 · 800×600 logical px at dpr 2.0 · display 120 Hz · median of 3 runs per arm

**Frames delivered while the camera moves (higher is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 97.4 % <sub>96.9–98.1</sub> | 96.4 % <sub>96.3–96.5</sub> | 98.4 % <sub>98.3–98.4</sub> | 96.8 % <sub>96.8–96.9</sub> | 98.2 % <sub>98.1–98.2</sub> | 99.2 % <sub>99.2–99.3</sub> | 66.7 % <sub>66.4–67.0</sub> · 27 stalls |
| zoom · warm | 99.4 % <sub>99.3–99.6</sub> | 97.9 % <sub>97.8–98.0</sub> | 99.6 % <sub>99.5–99.6</sub> | 98.2 % <sub>98.2–98.2</sub> | 99.5 % <sub>99.5–99.5</sub> | 100.0 % <sub>99.8–100.0</sub> | 66.6 % <sub>66.4–66.7</sub> · 28 stalls |
| pan · cold | 99.4 % <sub>99.4–99.6</sub> | 99.6 % <sub>99.3–99.6</sub> | 99.7 % <sub>99.7–99.8</sub> | 99.8 % <sub>99.5–99.9</sub> | 99.3 % <sub>99.2–99.3</sub> | 100.0 % <sub>99.8–100.0</sub> | 99.9 % <sub>99.8–100.0</sub> |
| pan · warm | 99.6 % <sub>99.5–99.8</sub> | 99.8 % <sub>99.6–99.9</sub> | 99.9 % <sub>99.8–100.0</sub> | 99.8 % <sub>99.7–99.9</sub> | 99.8 % <sub>99.8–99.9</sub> | 100.0 % <sub>100.0–100.0</sub> | 99.9 % <sub>99.9–100.0</sub> |
| rotate · cold | 100.0 % <sub>100.0–100.0</sub> | 99.7 % <sub>99.6–99.9</sub> | 100.0 % <sub>99.7–100.0</sub> | 100.0 % <sub>99.9–100.0</sub> | 99.8 % <sub>99.7–100.0</sub> | 99.9 % <sub>99.6–99.9</sub> | 64.0 % <sub>60.9–64.1</sub> |
| rotate · warm | 100.0 % <sub>99.9–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 99.9 % <sub>99.8–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>99.9–100.0</sub> | 64.8 % <sub>64.5–65.0</sub> |
| fling · cold | 99.3 % <sub>99.1–99.4</sub> | 99.3 % <sub>99.1–99.4</sub> | 99.6 % <sub>99.4–99.6</sub> | 99.7 % <sub>99.7–99.8</sub> | 99.2 % <sub>99.2–99.6</sub> | 99.1 % <sub>98.1–99.4</sub> | 66.4 % <sub>66.2–66.9</sub> · 3 stalls |
| fling · warm | 100.0 % <sub>99.9–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 99.9 % <sub>99.8–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 99.9 % <sub>99.7–100.0</sub> | 99.9 % <sub>99.7–100.0</sub> | 67.4 % <sub>67.0–67.5</sub> · 1 stall |

**Worst frame gap, ms (lower is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 33 | 50 | 25 | 42 | 33 | 42 | 183 |
| zoom · warm | 25 | 42 | 17 | 33 | 25 | 12 | 142 |
| pan · cold | 17 | 17 | 17 | 17 | 19 | 8 | 16 |
| pan · warm | 19 | 17 | 17 | 17 | 17 | 8 | 14 |
| rotate · cold | 8 | 17 | 8 | 9 | 17 | 17 | 50 |
| rotate · warm | 8 | 12 | 9 | 17 | 8 | 9 | 33 |
| fling · cold | 17 | 25 | 17 | 17 | 17 | 25 | 67 |
| fling · warm | 10 | 12 | 14 | 8 | 14 | 14 | 58 |

**UI thread p90 / raster thread p90, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 2.3 / 1.6 | 2.8 / 1.3 | 0.6 / 0.9 | 0.6 / 0.9 | 2.5 / 1.5 | 1.0 / 1.0 | 8.8 / 17.4 |
| zoom · warm | 2.3 / 1.6 | 2.6 / 1.2 | 0.6 / 0.9 | 0.6 / 0.9 | 2.4 / 1.4 | 1.0 / 1.0 | 9.2 / 17.1 |
| pan · cold | 2.6 / 1.5 | 2.7 / 1.1 | 0.7 / 1.0 | 0.7 / 1.0 | 2.8 / 1.4 | 1.0 / 0.9 | 0.8 / 3.0 |
| pan · warm | 2.6 / 1.6 | 2.8 / 1.1 | 0.7 / 1.0 | 0.7 / 1.0 | 2.6 / 1.3 | 1.0 / 1.0 | 0.8 / 2.9 |
| rotate · cold | 3.0 / 1.3 | 2.6 / 1.0 | 0.7 / 0.9 | 0.7 / 1.0 | 2.5 / 1.3 | 1.1 / 1.0 | 4.8 / 16.0 |
| rotate · warm | 3.0 / 1.3 | 2.5 / 1.1 | 0.7 / 0.9 | 0.7 / 1.0 | 2.4 / 1.3 | 1.1 / 1.0 | 4.8 / 15.9 |
| fling · cold | 2.6 / 1.5 | 2.6 / 1.3 | 0.6 / 0.9 | 0.6 / 0.9 | 2.6 / 1.5 | 1.1 / 0.9 | 10.4 / 20.4 |
| fling · warm | 2.5 / 1.5 | 2.7 / 1.2 | 0.6 / 0.9 | 0.6 / 0.9 | 2.6 / 1.4 | 0.9 / 1.0 | 10.2 / 20.4 |

**Settle: time from the camera stopping to the last repaint, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 284 | 266 | 8 | 8 | 265 | 8 | 553 |
| zoom · warm | 234 | 275 | 8 | 8 | 267 | 8 | 535 |
| pan · cold | 223 | 249 | 8 | 8 | 240 | 8 | 99 |
| pan · warm | 223 | 266 | 8 | 8 | 241 | 8 | 91 |
| rotate · cold | 251 | 250 | 8 | 8 | 249 | 8 | 1273 |
| rotate · warm | 258 | 226 | 8 | 8 | 232 | 8 | 1266 |
| fling · cold | 224 | 241 | 8 | 8 | 216 | 8 | 646 |
| fling · warm | 249 | 208 | 8 | 8 | 222 | 8 | 620 |

**Opening the map, network and memory**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| time to first complete map, ms | 299 | 378 | 276 | 320 | 390 | 930 | 945 |
| requests per run | 77 | 86 | 76 | 86 | 77 | 111 | 92 |
| MB downloaded per run | 27.2 | 29.9 | 27.2 | 29.9 | 27.2 | 51.3 | 51.4 |
| peak RSS, MB | 409 | 445 | 413 | 425 | 426 | 611 | 1001 |

**Screenshots** (fixed Munich cameras after round 0; click for full size)

| camera | flutter_map_vector_tiles | flutter_map_vector_tiles · LabelMode.tile | vector_map_tiles · raster | vector_map_tiles · vector | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `munich-z14` | [![flutter_map_vector_tiles, munich-z14](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z14](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z14](results/shots/2026-11-03-7dd024a-macos/munich-z14-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z14-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z14](results/shots/2026-11-03-7dd024a-macos/munich-z14-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z14-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z14](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z14](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z14](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z14-fmvt-3d.webp) |
| `munich-z16` | [![flutter_map_vector_tiles, munich-z16](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16](results/shots/2026-11-03-7dd024a-macos/munich-z16-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16](results/shots/2026-11-03-7dd024a-macos/munich-z16-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-fmvt-3d.webp) |
| `munich-z16-rot45` | [![flutter_map_vector_tiles, munich-z16-rot45](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16-rot45](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16-rot45](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16-rot45](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16-rot45](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16-rot45](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16-rot45](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z16-rot45-fmvt-3d.webp) |
| `munich-z17.5` | [![flutter_map_vector_tiles, munich-z17.5](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z17.5](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z17.5](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z17.5](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z17.5](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z17.5](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z17.5](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z17.5-fmvt-3d.webp) |
| `munich-z18` | [![flutter_map_vector_tiles, munich-z18](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z18](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z18](results/shots/2026-11-03-7dd024a-macos/munich-z18-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z18-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z18](results/shots/2026-11-03-7dd024a-macos/munich-z18-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z18-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z18](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z18](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z18](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-macos/munich-z18-fmvt-3d.webp) |

Raw data: [results/raw/2026-11-03-7dd024a-macos/results.jsonl](results/raw/2026-11-03-7dd024a-macos/results.jsonl),
notes in [notes.md](results/raw/2026-11-03-7dd024a-macos/notes.md).

## Chrome · on the same Mac

Chrome 156 · headed, driven by Playwright, each window moved onto the
Mac's built-in 120 Hz display · the app built with
`flutter build web --profile` (dart2js), session
`2026-11-03-7dd024a-web`. MapLibre GL JS 4.7.1 rendered the reference
column in the same browser, from the same recorded tiles.

Flutter 3.44.5 · flutter_map_vector_tiles 2.11.0 (7dd024a) · vector_map_tiles 9.0.0-beta.13 · 1000×800 logical px at dpr 2 · display 120 Hz · median of 3 runs per arm

**Frames delivered while the camera moves (higher is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 95.1 % <sub>95.0–95.3</sub> | 90.8 % <sub>90.6–90.9</sub> | 95.5 % <sub>95.3–95.7</sub> | 91.9 % <sub>91.9–92.5</sub> | 93.7 % <sub>93.3–94.1</sub> · 1 stall | 56.7 % <sub>55.2–57.8</sub> · 25 stalls | 18.6 % <sub>18.5–19.1</sub> · 53 stalls |
| zoom · warm | 97.5 % <sub>97.2–97.5</sub> | 93.0 % <sub>93.0–93.2</sub> | 98.0 % <sub>97.7–98.0</sub> | 93.4 % <sub>91.2–93.7</sub> | 96.6 % <sub>96.4–96.6</sub> | 88.4 % <sub>87.8–88.8</sub> · 15 stalls | 18.8 % <sub>18.1–19.1</sub> · 54 stalls |
| pan · cold | 96.1 % <sub>95.2–96.3</sub> | 95.4 % <sub>95.3–95.5</sub> | 96.6 % <sub>96.5–96.6</sub> | 96.1 % <sub>95.8–96.3</sub> | 96.0 % <sub>95.9–96.0</sub> | 76.5 % <sub>76.4–76.5</sub> · 18 stalls | 75.1 % <sub>75.1–75.2</sub> · 9 stalls |
| pan · warm | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>99.7–100.0</sub> | 98.8 % <sub>95.7–100.0</sub> · 1 stall | 100.0 % <sub>99.6–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>99.3–100.0</sub> | 75.6 % <sub>74.7–77.8</sub> · 12 stalls |
| rotate · cold | 97.3 % <sub>97.3–97.5</sub> | 97.1 % <sub>96.9–97.2</sub> | 98.1 % <sub>98.0–98.2</sub> | 98.1 % <sub>98.0–98.1</sub> | 95.0 % <sub>94.9–95.1</sub> · 4 stalls | 86.5 % <sub>86.4–86.6</sub> · 17 stalls | 13.5 % <sub>13.4–13.6</sub> · 91 stalls |
| rotate · warm | 99.9 % <sub>98.9–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 99.9 % <sub>99.4–100.0</sub> | 100.0 % <sub>99.9–100.0</sub> | 100.0 % <sub>95.7–100.0</sub> | 99.9 % <sub>99.5–100.0</sub> | 14.5 % <sub>14.4–14.6</sub> · 96 stalls |
| fling · cold | 95.1 % <sub>94.5–95.1</sub> | 94.5 % <sub>94.4–94.7</sub> | 97.6 % <sub>97.2–97.7</sub> | 97.4 % <sub>97.0–97.6</sub> | 89.3 % <sub>89.2–89.6</sub> · 1 stall | 40.8 % <sub>39.7–41.0</sub> · 45 stalls | 3.2 % <sub>3.2–3.8</sub> · 28 stalls |
| fling · warm | 96.0 % <sub>95.1–96.3</sub> | 95.5 % <sub>95.5–95.7</sub> | 99.4 % <sub>99.3–100.0</sub> | 99.9 % <sub>99.9–100.0</sub> | 96.0 % <sub>90.7–98.2</sub> | 77.5 % <sub>76.5–81.3</sub> · 16 stalls | 3.1 % <sub>3.1–3.5</sub> · 30 stalls |

**Worst frame gap, ms (lower is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 42 | 43 | 41 | 42 | 50 | 150 | 684 |
| zoom · warm | 27 | 48 | 26 | 42 | 42 | 150 | 700 |
| pan · cold | 33 | 33 | 33 | 33 | 42 | 142 | 100 |
| pan · warm | 10 | 10 | 117 | 10 | 10 | 11 | 108 |
| rotate · cold | 33 | 33 | 41 | 33 | 75 | 158 | 391 |
| rotate · warm | 15 | 10 | 13 | 12 | 10 | 14 | 116 |
| fling · cold | 25 | 25 | 33 | 26 | 58 | 158 | 825 |
| fling · warm | 25 | 25 | 29 | 14 | 25 | 158 | 833 |

**UI thread p90 / raster thread p90, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 6.2 / 0.7 | 7.2 / 0.8 | 5.0 / 0.7 | 5.4 / 0.7 | 6.7 / 0.7 | 1.8 / 0.6 | 35.1 / 24.7 |
| zoom · warm | 3.8 / 0.7 | 5.5 / 0.8 | 2.2 / 0.6 | 4.5 / 0.7 | 4.1 / 0.7 | 2.2 / 0.6 | 35.8 / 24.8 |
| pan · cold | 3.6 / 0.7 | 4.2 / 0.8 | 2.2 / 0.7 | 2.2 / 0.7 | 3.2 / 0.7 | 2.1 / 0.6 | 0.9 / 10.3 |
| pan · warm | 2.4 / 0.7 | 2.9 / 0.8 | 1.8 / 0.7 | 1.8 / 0.7 | 2.7 / 0.7 | 2.2 / 0.7 | 0.8 / 10.3 |
| rotate · cold | 3.4 / 0.7 | 4.4 / 0.8 | 2.1 / 0.7 | 2.1 / 0.7 | 4.9 / 0.9 | 2.4 / 0.7 | 53.5 / 30.0 |
| rotate · warm | 2.6 / 0.7 | 3.5 / 0.8 | 2.0 / 0.7 | 1.9 / 0.7 | 4.7 / 0.9 | 2.3 / 0.7 | 55.8 / 29.5 |
| fling · cold | 9.7 / 0.8 | 9.6 / 0.9 | 2.6 / 0.6 | 2.4 / 0.6 | 12.6 / 1.0 | 1.6 / 0.5 | 127.2 / 697.4 |
| fling · warm | 7.5 / 0.8 | 8.0 / 0.9 | 1.9 / 0.6 | 1.8 / 0.7 | 5.0 / 1.0 | 1.9 / 0.6 | 127.3 / 703.2 |

**Settle: time from the camera stopping to the last repaint, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 192 | 281 | 33 | 152 | 183 | 0 | 3348 |
| zoom · warm | 275 | 186 | 49 | 155 | 231 | 0 | 3049 |
| pan · cold | 288 | 251 | 249 | 248 | 231 | 366 | 509 |
| pan · warm | 199 | 191 | 0 | 0 | 243 | 170 | 513 |
| rotate · cold | 225 | 200 | 0 | 0 | 190 | 0 | 1730 |
| rotate · warm | 299 | 215 | 0 | 0 | 184 | 0 | 1747 |
| fling · cold | 266 | 273 | 0 | 0 | 222 | 16 | 1408 |
| fling · warm | 273 | 266 | 0 | 0 | 263 | 16 | 1503 |

**Opening the map, network and memory**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| time to first complete map, ms | 1142 | 1150 | 1119 | 1136 | 1064 | 2492 | 1735 |
| requests per run | 88 | 99 | 87 | 99 | 88 | 90 | 45 |
| MB downloaded per run | 29.9 | 33.3 | 29.9 | 33.3 | 29.9 | 32.6 | 18.8 |

**Screenshots** (fixed Munich cameras after round 0, MapLibre GL JS
first; click for full size)

| camera | MapLibre GL JS (reference) | flutter_map_vector_tiles | flutter_map_vector_tiles · LabelMode.tile | vector_map_tiles · raster | vector_map_tiles · vector | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `munich-z14` | [![MapLibre GL JS (reference), munich-z14](results/shots/2026-11-03-7dd024a-web/munich-z14-maplibre.webp)](results/shots/2026-11-03-7dd024a-web/munich-z14-maplibre.webp) | [![flutter_map_vector_tiles, munich-z14](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt.webp)](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z14](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z14](results/shots/2026-11-03-7dd024a-web/munich-z14-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z14-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z14](results/shots/2026-11-03-7dd024a-web/munich-z14-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-web/munich-z14-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z14](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z14](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z14](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-web/munich-z14-fmvt-3d.webp) |
| `munich-z16` | [![MapLibre GL JS (reference), munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-maplibre.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-maplibre.webp) | [![flutter_map_vector_tiles, munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-fmvt-3d.webp) |
| `munich-z16-rot45` | [![MapLibre GL JS (reference), munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-maplibre.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-maplibre.webp) | [![flutter_map_vector_tiles, munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16-rot45](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-web/munich-z16-rot45-fmvt-3d.webp) |
| `munich-z17.5` | [![MapLibre GL JS (reference), munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-maplibre.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-maplibre.webp) | [![flutter_map_vector_tiles, munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z17.5](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-web/munich-z17.5-fmvt-3d.webp) |
| `munich-z18` | [![MapLibre GL JS (reference), munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-maplibre.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-maplibre.webp) | [![flutter_map_vector_tiles, munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z18](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-web/munich-z18-fmvt-3d.webp) |

Raw data: [results/raw/2026-11-03-7dd024a-web/results.jsonl](results/raw/2026-11-03-7dd024a-web/results.jsonl),
notes in [notes.md](results/raw/2026-11-03-7dd024a-web/notes.md).

## iOS · iPhone 15 Pro Max

iOS 27.0.1 · 120 Hz · wired to the Mac and charging, nobody touching it;
the app reached the lab server over the USB link · session
`2026-11-03-7dd024a-ios`, 4 rounds.

Flutter 3.44.5 · flutter_map_vector_tiles 2.11.0 (7dd024a) · vector_map_tiles 9.0.0-beta.13 · 430×932 logical px at dpr 3.0 · display 120 Hz · median of 4 runs per arm

**Frames delivered while the camera moves (higher is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 99.9 % <sub>99.7–100.0</sub> | 99.4 % <sub>99.2–99.6</sub> | 99.8 % <sub>99.7–99.8</sub> | 99.5 % <sub>99.4–99.5</sub> | 99.5 % <sub>99.2–99.7</sub> | 97.3 % <sub>96.0–98.1</sub> | 72.2 % <sub>71.6–72.2</sub> · 34 stalls |
| zoom · warm | 100.0 % <sub>100.0–100.0</sub> | 99.3 % <sub>98.8–99.4</sub> | 100.0 % <sub>99.9–100.0</sub> | 99.3 % <sub>99.2–99.5</sub> | 99.7 % <sub>99.7–99.8</sub> | 99.6 % <sub>99.4–99.7</sub> | 72.1 % <sub>68.4–72.3</sub> · 33 stalls |
| pan · cold | 99.7 % <sub>99.6–99.8</sub> | 99.5 % <sub>99.2–99.5</sub> | 99.6 % <sub>99.5–99.7</sub> | 99.4 % <sub>99.3–99.6</sub> | 99.8 % <sub>99.8–99.8</sub> | 99.7 % <sub>99.4–99.8</sub> | 99.6 % <sub>99.5–99.8</sub> |
| pan · warm | 99.8 % <sub>99.7–99.9</sub> | 99.5 % <sub>99.4–99.7</sub> | 99.7 % <sub>99.7–99.8</sub> | 99.5 % <sub>99.4–99.8</sub> | 99.5 % <sub>99.4–99.5</sub> | 100.0 % <sub>100.0–100.0</sub> | 99.8 % <sub>99.8–99.8</sub> |
| rotate · cold | 99.5 % <sub>99.3–99.8</sub> | 99.1 % <sub>98.7–99.3</sub> | 99.6 % <sub>99.6–99.8</sub> | 99.3 % <sub>99.3–99.4</sub> | 99.5 % <sub>99.2–99.6</sub> | 99.7 % <sub>99.7–99.9</sub> | 89.5 % <sub>88.8–91.6</sub> · 2 stalls |
| rotate · warm | 100.0 % <sub>99.9–100.0</sub> | 100.0 % <sub>99.9–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 92.3 % <sub>85.8–93.2</sub> · 1 stall |
| fling · cold | 99.9 % <sub>99.8–100.0</sub> | 99.7 % <sub>99.6–99.8</sub> | 99.8 % <sub>99.8–99.9</sub> | 99.9 % <sub>99.7–100.0</sub> | 99.5 % <sub>99.2–99.7</sub> | 98.3 % <sub>97.4–99.3</sub> | 66.7 % <sub>53.8–67.2</sub> · 1 stalls |
| fling · warm | 100.0 % <sub>100.0–100.0</sub> | 99.9 % <sub>99.8–99.9</sub> | 100.0 % <sub>100.0–100.0</sub> | 100.0 % <sub>100.0–100.0</sub> | 99.9 % <sub>99.9–99.9</sub> | 99.5 % <sub>99.3–99.7</sub> | 67.1 % <sub>57.9–67.7</sub> · 1 stalls |

**Worst frame gap, ms (lower is better)**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 17 | 17 | 17 | 25 | 17 | 38 | 122 |
| zoom · warm | 13 | 17 | 17 | 19 | 17 | 29 | 133 |
| pan · cold | 17 | 17 | 18 | 25 | 17 | 17 | 17 |
| pan · warm | 17 | 17 | 17 | 17 | 17 | 8 | 17 |
| rotate · cold | 17 | 25 | 18 | 20 | 20 | 17 | 92 |
| rotate · warm | 8 | 8 | 8 | 8 | 8 | 8 | 96 |
| fling · cold | 17 | 17 | 17 | 16 | 17 | 26 | 48 |
| fling · warm | 8 | 17 | 8 | 8 | 17 | 21 | 48 |

**UI thread p90 / raster thread p90, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 2.4 / 0.8 | 3.2 / 0.6 | 0.6 / 0.4 | 0.5 / 0.4 | 2.8 / 0.9 | 1.2 / 0.4 | 10.6 / 9.7 |
| zoom · warm | 2.3 / 0.8 | 3.1 / 0.6 | 0.5 / 0.4 | 0.5 / 0.4 | 2.7 / 0.9 | 0.8 / 0.4 | 10.5 / 9.7 |
| pan · cold | 2.6 / 0.7 | 3.2 / 0.6 | 0.5 / 0.4 | 0.5 / 0.4 | 2.8 / 0.8 | 0.8 / 0.4 | 0.5 / 4.0 |
| pan · warm | 2.6 / 0.7 | 3.2 / 0.6 | 0.5 / 0.4 | 0.5 / 0.4 | 3.0 / 0.8 | 0.8 / 0.4 | 0.4 / 4.0 |
| rotate · cold | 2.7 / 0.8 | 3.0 / 0.5 | 0.5 / 0.4 | 0.5 / 0.4 | 2.5 / 0.9 | 1.0 / 0.4 | 5.5 / 11.2 |
| rotate · warm | 2.7 / 0.8 | 2.6 / 0.5 | 0.5 / 0.5 | 0.5 / 0.5 | 2.4 / 0.9 | 1.0 / 0.4 | 4.8 / 11.1 |
| fling · cold | 2.8 / 0.7 | 3.6 / 0.6 | 0.5 / 0.4 | 0.5 / 0.5 | 3.1 / 0.9 | 2.8 / 0.4 | 13.9 / 9.6 |
| fling · warm | 2.6 / 0.7 | 3.4 / 0.6 | 0.5 / 0.4 | 0.5 / 0.4 | 3.0 / 0.9 | 0.8 / 0.4 | 14.1 / 9.3 |

**Settle: time from the camera stopping to the last repaint, ms**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| zoom · cold | 279 | 259 | 124 | 179 | 299 | 108 | 916 |
| zoom · warm | 175 | 294 | 120 | 179 | 229 | 116 | 944 |
| pan · cold | 304 | 226 | 8 | 8 | 216 | 8 | 16 |
| pan · warm | 304 | 197 | 8 | 8 | 208 | 8 | 16 |
| rotate · cold | 212 | 258 | 8 | 8 | 209 | 8 | 1149 |
| rotate · warm | 221 | 274 | 8 | 8 | 212 | 8 | 1148 |
| fling · cold | 208 | 242 | 8 | 8 | 249 | 58 | 1043 |
| fling · warm | 237 | 217 | 8 | 8 | 236 | 71 | 1007 |

**Opening the map, network and memory**

| | flutter_map_vector_tiles | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective | vector_map_tiles · raster | vector_map_tiles · vector |
|---|---:|---:|---:|---:|---:|---:|---:|
| time to first complete map, ms | 492 | 510 | 346 | 341 | 473 | 1744 | 1209 |
| requests per run | 76 | 83 | 75 | 83 | 76 | 109 | 80 |
| MB downloaded per run | 27.3 | 29.8 | 27.2 | 29.8 | 27.3 | 53.2 | 44.5 |
| peak RSS, MB | 277 | 309 | 265 | 287 | 337 | 374 | 841 |

No measurement is left out. Across rounds, frames delivered moved by at
most 13.4 points (vector mode, first fling), this package's arms by at
most 0.6.

**Screenshots** (fixed Munich cameras after round 0; click for full size)

| camera | flutter_map_vector_tiles | flutter_map_vector_tiles · LabelMode.tile | vector_map_tiles · raster | vector_map_tiles · vector | flutter_map_vector_tiles · TileOffset.none | flutter_map_vector_tiles · LabelMode.tile · TileOffset.none | flutter_map_vector_tiles · ExtrusionMode.perspective |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| `munich-z14` | [![flutter_map_vector_tiles, munich-z14](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z14](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z14](results/shots/2026-11-03-7dd024a-ios/munich-z14-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z14-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z14](results/shots/2026-11-03-7dd024a-ios/munich-z14-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z14-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z14](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z14](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z14](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z14-fmvt-3d.webp) |
| `munich-z16` | [![flutter_map_vector_tiles, munich-z16](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16](results/shots/2026-11-03-7dd024a-ios/munich-z16-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16](results/shots/2026-11-03-7dd024a-ios/munich-z16-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-fmvt-3d.webp) |
| `munich-z16-rot45` | [![flutter_map_vector_tiles, munich-z16-rot45](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z16-rot45](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z16-rot45](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z16-rot45](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z16-rot45](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z16-rot45](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z16-rot45](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z16-rot45-fmvt-3d.webp) |
| `munich-z17.5` | [![flutter_map_vector_tiles, munich-z17.5](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z17.5](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z17.5](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z17.5](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z17.5](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z17.5](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z17.5](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z17.5-fmvt-3d.webp) |
| `munich-z18` | [![flutter_map_vector_tiles, munich-z18](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt.webp) | [![flutter_map_vector_tiles · LabelMode.tile, munich-z18](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt-raster.webp) | [![vector_map_tiles · raster, munich-z18](results/shots/2026-11-03-7dd024a-ios/munich-z18-vmt-raster.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z18-vmt-raster.webp) | [![vector_map_tiles · vector, munich-z18](results/shots/2026-11-03-7dd024a-ios/munich-z18-vmt-vector.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z18-vmt-vector.webp) | [![flutter_map_vector_tiles · TileOffset.none, munich-z18](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt-none.webp) | [![flutter_map_vector_tiles · LabelMode.tile · TileOffset.none, munich-z18](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt-raster-none.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt-raster-none.webp) | [![flutter_map_vector_tiles · ExtrusionMode.perspective, munich-z18](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt-3d.webp)](results/shots/2026-11-03-7dd024a-ios/munich-z18-fmvt-3d.webp) |

Raw data: [results/raw/2026-11-03-7dd024a-ios/results.jsonl](results/raw/2026-11-03-7dd024a-ios/results.jsonl),
notes in [notes.md](results/raw/2026-11-03-7dd024a-ios/notes.md).

## Earlier sessions

Kept as raw data under `results/raw/`, with their screenshots, where
they have any, in `results/shots/`. None of them is comparable with the
sessions above:

| session | arms | why it is superseded |
|---|---|---|
| `2026-10-12-c1dc45c-android` | all six | built from c1dc45c (2.9.1): before the strict expression typing, the style's glyphs and the curved street names; its `vmt-*` arms match `2026-11-03-7dd024a-android` within 2.3 points |
| `2026-10-20-ios` | all six | built from d8c2e86 (2.9.1 with two label fixes); repeated in `2026-11-03-7dd024a-ios` |
| `2026-10-12-c1dc45c-macos` | all six, macOS | built from c1dc45c (2.9.1); repeated in `2026-11-03-7dd024a-macos`, whose `vmt-raster` arm matches it within 0.2 points |
| `2026-10-12-c1dc45c-web` | all six, Chrome | built from c1dc45c (2.9.1); repeated in `2026-11-03-7dd024a-web`, whose `vmt-raster` arm matches it within 2.4 points |
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
