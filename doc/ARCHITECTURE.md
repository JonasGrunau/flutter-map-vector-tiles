# Architecture

`flutter_map_vector_tiles` is a clean-room rewrite of the ideas behind
`vector_map_tiles`, designed for flutter_map ≥ 8 and modern Flutter
(Impeller). It is a single self-contained package: MVT decoding, the
MapLibre style engine, the tile pipeline and rendering all live here.

## Data flow

```
style.json ──► StyleReader ──► Theme (compiled layers + expressions)
                                  │
camera ──► TileGrid (visible display tiles at floor(zoom))
                                  │
display tile (z,x,y) ─► data tile key (clamped to source maxZoom)
     │
     ├─ TileStore (memory LRU of PreparedTile)
     │      └─ miss: bytes ◄─ DiskCache ◄─ VectorTileProvider (network…)
     │                 (providers backed by local storage skip DiskCache)
     │              └─ IsolatePool: decode MVT, trim to what the theme reads,
     │                             resolve the zoom-free layer filters
     │                             └─ PreparedTile (compact, transferable)
     │
     ├─ RasterTileStore (raster + raster-dem sources): bytes ─► image codec
     │       └─ raster-dem: the data tile's 8 neighbours too, for the border
     │
     ├─ TileRasterizer: PreparedTile ─► ui.Picture ─► toImageSync (GPU)
     │       one raster per *display* tile at tileSize·dpr, evaluated at
     │       the display zoom (crisp overzoom via subdivision, not scaling);
     │       features are culled — and at deep overzoom clipped — to the
     │       tile's window of the data tile; hillshade: DEM + border ─►
     │       slopes (shader, snapshot) ─► shaded per pixel (shader)
     │
     ├─ symbols: SymbolLayouter collects label/icon anchors per tile
     │       │  text shaped from the style's glyph PBFs (pure Dart) where
     │       │  the script allows, else by the platform (Paragraph)
     │       ├─ LabelPainter: per-frame screen-space pass, global collision
     │       │  grid across all tiles, upright text under rotation
     │       └─ or, LabelMode.tile: LabelPainter.paintTile places them once
     │          per tile and draws them into the tile's own image
     │
     └─ heatmap points: HeatmapLayouter, per tile, when its image publishes
             └─ HeatmapPainter: a throttled density pass over every tile's
                points — summed and coloured on a worker isolate — into
                one screen-space image, drawn over the tiles each frame
```

Rasterization and symbol extraction are two separate jobs in a budgeted
per-frame render pump (rasters for every pending tile first, symbols
after — in `LabelMode.tile`, one tile at a time, since a tile shows only
once both are done). Both are resumable — a recording stops between
style layers, shaping between labels — so a dense tile is spread over
several frames. What is never split can still fill a frame on its own:
one style layer's recording, and in `LabelMode.tile` one tile's label
placement, drawing and snapshot (see below). A finished tile — image
plus symbols — enters the shared result cache, so re-crossing a zoom
level skips the pipeline entirely. The pump's stages emit DevTools
timeline events (`VT render pump`, `VT rasterize`, `VT symbols`,
`VT labels`, and in `LabelMode.tile` `VT rasterize with labels` and
`VT tile labels`).

## Rendering model

Geometry (background/fill/line) is rasterized **once** per display tile
into a GPU-resident `ui.Image` via `Picture.toImageSync`; the per-frame
cost of pan/zoom/rotate is just textured quads, like a raster tile layer.
Between integer zooms the images scale (max 2×) exactly as raster maps
do; on crossing a zoom level, new display tiles are rasterized from the
already-decoded data tile, while the previous zoom's images are retained
and drawn underneath until replacements are ready (no white flicker).
The retained level is released the moment every current tile is
rendered and faded in — checked from the publish jobs and the fade
ticker, not only from rebuilds, because a crossing whose gesture has
ended produces no further builds and would otherwise keep the outgoing
level in memory (and painted beneath the map) until the next one. A
tile's fade-in itself runs only where it can cross-fade: a tile served
from the finished-result cache with retained imagery beneath it fades
over that imagery, while one with nothing beneath — the ring a zoom-out
exposes — appears at full opacity at once, because a fade there runs
over the bare background and reads as a background-coloured shimmer on
every crossing. Freshly rasterized tiles always fade; their fade is
what masks staggered pop-in.

Recording that geometry into a `Picture` is the expensive half of the
raster phase, and it is all UI-thread work: on a Nothing Phone (1), a
display tile of central Berlin at z16 took 16–28 ms to record, up to
49 ms, against a 16.7 ms frame — buildings and dashed footpaths about
half of it. So the raster phase is resumable, like the symbol phase:
`TileRasterizer.recordSlice` records layers until the pump's budget is
spent and returns where to resume, the job keeps the slices it has
(`_RenderJob.geometryParts`) and is requeued with its priority, ahead
of the jobs it ties with — otherwise tiles of one priority, such as
every tile a refresh re-renders, would take turns a slice each and none
would finish until all had started — and once the last layer is in, `compose` stacks the slices into exactly the
picture a single recording would have made. A layer is the smallest
unit — each is drawn whole, in order, with its own paints, which is
what keeps the slices stackable — so one frame can still carry the most
expensive layer of a tile: 5–9 ms on those Berlin tiles, 22 ms for the
buildings of the densest one. Nothing is published before the last
slice: a tile halfway through its recording counts as loading, and
whatever covered it keeps covering it. A slice taken at a different
pixel ratio than the ones before it starts the recording over, since
it would not stack onto them; the other inputs cannot change under a
job — a theme change empties the queue, and a change that re-renders
the live tiles (sprites, `showLabels`, the label mode, the resume
recovery) retires the outgoing level's queued jobs too. The symbol phase inherits
the ratio the geometry was recorded at — `LabelMode.tile` draws the
labels over that geometry at it — and a tile finished at a ratio the
screen has since left is published but not cached, so the next visit
renders it afresh.

The budget depends on motion: 4 ms per frame while the camera moves,
12 ms once it has stood still for 150 ms. While the map moves, every
late frame is a visible stutter; while it stands still, a late frame
only puts a fade-in one frame behind, and slicing at 4 ms then left
most of each frame idle — the first complete map came 3 s later than
before slicing. The one casualty of the still budget is an animation
the app runs over a still map that is still loading: 12 ms is most of
a 60 Hz frame and more than a 120 Hz one, so that animation can drop
frames until the tiles are in.

Measured with `compare/` on that phone at 60 Hz, two runs each, panning
and zooming over the same tiles: with `LabelMode.tile` the map got a
frame on 95–98% of display refreshes while panning (84–89% before) and
94–96% while zooming (85–93%), the first complete map came after 1.0 s
instead of 3.8 s, and the tiles came out pixel-identical. The default
`LabelMode.screen` delivered the same share of frames as before — its
per-frame label pass, not recording, is what makes those frames late —
but its first complete map also came after 1.1–1.2 s instead of
3.0–3.1 s. The price is the backlog a moving camera leaves: in tile mode
the last tiles land up to 0.2 s after a pan stops, 0.9 s after a long zoom,
where before the screen was complete the moment the camera stopped —
because every frame of the motion had waited for whole tiles.

A move is picked up from flutter_map's map events (`MapEventWithMove`,
size changes excepted, since the first layout fires one too), not only
in `build`. Tickers run before the build phase, so `build` sees a move
only after that frame's pump has already run on the still budget; the
event arrives before the frame starts, so the first frame of a drag or
zoom over a still, loading map already gets 4 ms.

A display tile whose data has not arrived does not wait blank. While
the load is pending, the layer renders a *provisional* image from
whatever the decoded-tile cache can offer: the nearest in-memory
ancestor (up to five levels up — a fast zoom-in instantly shows a
window of the parent it just left), or, when there is no cached
ancestor because the camera zoomed *out* — the level just left lies
below the pending key — its cached descendants, up to two levels down,
each shrunk into its sub-square of the display tile and clipped to its
own extent so buffer geometry cannot spill into a sub-square whose
descendant is missing. The descendant cover may be partial; partially
sharp pixels still beat the background. Descendants contribute
geometry only — symbols are never laid out from them, so labels arrive
with the tile's real data. Provisional results never enter the result
cache, and a provisional tile still counts as loading for retention.

At overzoom — display zoom past the source's maxzoom — each display tile
shows only a small window of its data tile. Features are rejected
against that window (expanded by a 64-logical-px buffer) using bounds
computed once at decode time, *before* any paint expression or
per-tile filter runs; from two levels of overzoom the surviving geometry is additionally
clipped to the window, with dash and line-pattern phase measured from
the original run start so patterns stay aligned across clip boundaries
and display-tile seams. Rasterization cost per display tile is therefore
bounded by what is visible, not by the density of the data tile — the
difference between ~1 ms and ~85 ms per tile for a dense city tile
viewed at z20 over z14 data.

Layer filters are resolved once per data tile, not once per display
tile. A style runs many layers over one source layer — a MapTiler
theme has 60+ line layers over `transportation` alone — and every one
of them used to test every feature again on each display tile cut from
the data tile: 45 filter tests per match, measured on a phone. The
expression parser records whether a filter can read the zoom
(`["zoom"]` anywhere in it, or a zoom-keyed legacy function inside
it). One that cannot selects the same features at every zoom, so the
rasterizer and the symbol layouter take its matches from a list
attached to the `PreparedSourceLayer` (`render/matched_features.dart`):
it lives exactly as long as the prepared tile, and a swapped theme's
layers simply miss. Both levels of that cache are weak — an `Expando`
per source layer, holding an `Expando` per style layer — so a theme
that has been swapped out, a light and a dark style taking turns say,
is not kept alive by the decoded tiles it was drawn from, and neither
are its match lists. Only zoom-reading filters are still evaluated per
display tile; the type filter and the bounds cull above still run per
display tile, over the matches. That cut rasterization time per tile by
a third to almost half on a phone in the z15.5–17.5 band, where one z14
data tile serves up to 64 display tiles.

The scan itself — every feature against every zoom-free filter, once
per data tile — happens on the worker isolate that decodes the tile
(see Concurrency), so on native platforms the UI isolate's first use
of a tile only gathers the features at the indices the worker found.
Where no worker resolved a filter, the UI isolate scans on first use:
on web, for a hand-built layer, for a filter that is not plain JSON,
for one that reads `global-state` (compiled into the filter as
constants, so one JSON is a different filter under every state) or the
feature's geometry (`within`, `distance`; the worker builds none), and
for a layer that draws the tile only as a stand-in for another zoom (a
provisional ancestor or descendant).

The geometry paint properties beyond colour, width and opacity follow
the same two rules: work that is the same for every display tile of a
data tile is done once for it, and nothing per feature is paid by a
layer that does not set the property. A `*-translate` is folded into
the tile-to-pixel transform, so the cull and clip windows, which are
derived from it, move with the geometry, and patterns are shifted with
it. A `*-sort-key` that reads the feature reorders the layer's
features once per data tile and zoom, held weakly against the feature
list as the filter matches are; one that is constant or reads only the
zoom cannot tell features apart and leaves source order alone.
`line-offset` shifts each run in logical pixels after clipping, every
vertex to where its two shifted segments meet, beveled on the outside
of a sharp turn and split where the inner meeting point lies beyond a
segment — MapLibre leaves gaps and crossings at such turns.
`line-blur` is MapLibre's linear alpha ramp drawn as a stroke narrowed
by the blur under a Gaussian mask filter whose variance, with
anti-aliasing's own, adds up to the ramp's: within about 0.05 alpha of
MapLibre's profile for blurs of 2 px and more, with a steeper edge but
the same ink, to 10 %, for narrower ones. A mask filter costs a
render pass per path on the GPU: blurring each road of Liberty by
0.5 px, as Americana does, cut the Nothing Phone from 56 to 20 frames a
second while tiles were rasterized, and drawing each layer as one path
still left 49 of 58. So a blur under three quarters of a device pixel of
σ (about 0.6 px at a pixel ratio of 3) keeps just the narrowing, its
edges about a device pixel sharper than MapLibre's, and costs nothing;
above it, a layer whose blurred stroke is the same for every feature and
opaque draws all its features as one path, a pass per layer and tile.
Impeller, the renderer on iOS and Android, has two faults here that
Skia does not: it erases a whole layer for a mask-blurred clear stroke
on a bent path, and draws nothing for a mask-blurred path of several
contours along one axis. So a casing's inner edge stays sharp, and such
a path is drawn narrowed without the blur. Circle strokes lie outside the radius, as
the spec says, and `circle-blur` draws the circle as one disc whose
radial gradient samples MapLibre's circle shader. Several properties
are deliberately not drawn: `line-gradient` needs a GeoJSON source with
`lineMetrics` (MapLibre rejects it on a vector source), `line-round-limit`
changes nothing visible at its default, and a `*-translate-anchor` of
`viewport` is drawn as `map`, since a tile is rasterized once and then
rotated with the map.

By default (`LabelMode.screen`) labels and icons are **not** baked into
the tile images. They are drawn each frame in screen space:

* text stays crisp at fractional zoom and upright under map rotation;
* collision detection runs globally across tile borders, so labels never
  duplicate or clip at tile seams;
* fade transitions don't require re-rasterizing geometry;
* a symbol layer's `minzoom`/`maxzoom` is enforced per frame at the
  fractional style zoom (per-tile layout only prefilters by the integer
  zoom band), so labels appear and disappear exactly at the style's
  thresholds — including labels still painted from retained
  previous-level tiles during a zoom crossing.

Text is shaped **once per unique label at a 16 px reference size** and
drawn through the canvas transform at the evaluated `text-size` — valid
because every layout input is em-proportional, and crisp because glyphs
rasterize at device scale under the transform. The drawn scale is
snapped down so the device font size lands on a whole pixel (down, so
drawn text never outgrows the box collision placed): Impeller keys
its glyph atlas by the device text scale rounded to 1/200, so an
unsnapped `text-size` ramp would hand it a new size at every eval-zoom
step and re-rasterize every visible glyph and halo stroke on the raster
thread. The shape-cache key
therefore contains no font size; `text-opacity` (1/32 steps) and
`text-halo-width` and `text-halo-blur` (1/128-em ratio steps) enter it
quantized, so style
ramps re-shape a label a bounded number of times ever rather than per
zoom step. Never put a font size — or an unquantized opacity or halo
width — back into that key: it re-creates the full-screen re-shape per
pinch that this design removed. Collision boxes and curved-text cluster
metrics are the reference-size measurements multiplied by the scale.
`text-line-height` and `text-justify` are layout inputs and part of the
key too; a box is as wide as its longest line, as MapLibre's is. The
leading is distributed evenly (`TextLeadingDistribution.even`): in
proportion to each font's ascent and descent, a line mixing fonts takes
its baseline from whichever font gains most, by a share that grows with
the line height, so an Arabic word next to Latin digits sat 1.5 px
lower than alone at 1.2 em. MapLibre keeps every line on one pitch
whatever its fonts.
`text-justify: auto` follows the anchor a label is placed at: the text
is shaped centred, and multi-line text is laid out once more per side
its anchors can ask for, inside `prewarm` and kept with the shaped text
under the same key. Single-line text looks the same aligned anywhere
and is never laid out twice.

Where the style's glyphs do not draw a label (below), shaping is
Flutter's — HarfBuzz through `TextPainter`, with the platform's fonts —
so joining, reordering and stacking come right in every script, and the label code adds only what MapLibre does that a
`TextPainter` does not: words kept whole at `text-max-width` (Chinese
and Japanese still breaking between characters, which Skia's intrinsic
widths hide), and a direction per line taken from its first letter,
set with Unicode isolates because a label is laid out left to right —
only on the lines that would read differently without one, such as an
Arabic name holding a Latin word.
Only scripts whose glyphs keep their shape alone are curved glyph by
glyph; the rest are drawn straight along the line. `test/scripts/`
draws all of it in 23 scripts with bundled fonts and asserts on the
pixels.

**Text from the style's glyphs.** Given the style's `glyphs`
(`VectorTileLayer.glyphs`, a `GlyphSource`), a label whose text needs
no complex shaping is not handed to the platform at all. Platform
shaping — a `TextPainter` for the fill and one for the halo, per label —
was the largest UI-thread cost of a dense tile: 35–41 ms for the 222
labels of one Munich z14 tile on a Nothing Phone (1), against 14–28 ms
to record its geometry. Glyph PBFs carry every metric MapLibre lays text
out with, at a 24 px em: advance, bitmap size and offsets. So
`text/glyph_shaper.dart` lays the label out in pure Dart, as MapLibre
does — glyph by glyph by advance plus `text-letter-spacing`, lines
`text-line-height` apart and aligned by `text-justify` (for `auto`,
`ShapedGlyphs.justified` shifts each line once the anchor is known,
without shaping again), the bitmap placed so a line's
capitals centre on its middle — at a few microseconds per label. Lines
break at every `\n`, and at `text-max-width` where the text allows it
(after spaces, hyphens and dashes, slashes, `&`, `+`, parentheses, a
middle dot, soft hyphens, zero-width spaces), balanced the way MapLibre
balances them: the breaks are chosen so every line comes out close to
the text's whole width over the fewest lines the limit allows, a short
last line preferred to a long one and a parenthesis left at a line's
edge avoided, rather than greedily filled. As in MapLibre a line is
judged by its letters without its spaces, and the `\n`s are forced
breaks inside one balanced run rather than separate paragraphs. The
script suite's glyph run (`test/scripts/script_glyphs_test.dart`)
checks the result against MapLibre GL JS on the same text and glyphs. The shaped
text is a `Float32List` of pen positions and the glyphs they draw —
around a hundred bytes per label where two `TextPainter`s held about
20 KB, which the text cache multiplies by up to 8000 entries.

Which text takes this path is decided per label by
`text/glyph_script.dart`, conservatively — a code point is accepted
only when it is known to need nothing from a shaper: Latin
(precomposed, as names in tiles are), Greek, Cyrillic, Armenian,
Georgian, digits, punctuation and the common symbols. One character
outside that set sends the whole label to the platform: right-to-left
scripts and bidi controls, every script with conjuncts, reordering or
stacking marks (Indic, Sinhala, Thai, Lao, Tibetan, Myanmar, Khmer,
Mongolian), combining marks, emoji and joiners, anything outside the
Basic Multilingual Plane, and CJK, kana and Hangul. CJK is a choice, not
a limitation: MapLibre itself draws ideographs from a local font by
default rather than fetch them, because a Han range of 256 code points
is 150–190 KB and a screen of place names touches dozens. A label
whose glyph the font lacks, or whose range failed to load, also goes to
the platform, so a server missing a range costs fonts, never text.

Glyphs are drawn through the same glyph atlas as curved text (see
below), but from distance fields rather than paragraphs. A range is
decoded once, its distance fields packed onto one texture
(`decodeImageFromPixels`, asynchronous, about 1 ms of UI time per range
on a phone), and the atlas cell of a glyph at a device size is drawn
from it with a colour matrix that thresholds the field after bilinear
sampling — the technique SDF icons already use — at MapLibre's edge
(192/255), with MapLibre's 1.68-device-pixel edge ramp and its halo
offset (`text-halo-width` moves the cut outward, 1/8 of the field per
glyph pixel). The cells are white coverage; each frame draws a label's
halos and fills in one `drawRawAtlas` call with per-sprite colours
(`BlendMode.modulate`), so one cell serves every colour, and the
upright text lands on the device pixel grid so its cells are drawn 1:1
rather than resampled. A label resolves its cells once per device size
and atlas generation (`GlyphAtlas.generation` changes when a page is
evicted), not once per glyph per frame.

A tile's labels wait for the glyph ranges they need: the render pump's
symbol phase asks the label painter which ranges its candidates want
(`LabelPainter.glyphsPending`) before shaping any, and a job whose
ranges are still loading leaves the queue until they have loaded or
failed, then resumes where it stopped — unless its tile was disposed,
reloaded or re-rendered meanwhile, when it is dropped like any
superseded job. Shaping such labels by the platform in the meantime
would show them in a system font and switch them to the style's a
moment later. The wait is capped at 5 s: a range normally arrives in a
fraction of a second or fails at once offline, but a request hanging
on a bad connection would otherwise keep the tile's labels off the map
for as long as it hangs. Past the cap they are shaped by the platform,
and when the range does arrive one repaint switches them to the style's
font (in `LabelMode.tile` the baked labels stay as they are). `StyleReader` asks for the first range (Basic Latin and
Latin-1) of every constant `text-font` stack while the style loads, so
on a first map the wait is usually over before the first tile is
decoded; ranges go through the style cache, stale-while-revalidate,
like the rest of the bundle, so they are there offline wherever the
map has been. Text the label pass shapes while its ranges are still
loading (a paint-time cache miss, which the pump normally prevents) is
shaped by the platform, remembered as such, and shaped from the glyphs
on its first lookup after they have arrived.

Symbol layout applies the same decode-time bounds culling before
evaluating any expressions, and along-line anchors keep their full-line
spacing parametrization — an anchor lands at the same world position no
matter which display tile lays it out — while being *enumerated* only
inside the tile's window. The parametrization is `mid + k·spacing` from
the line's midpoint, for every integer k. `symbol-spacing` is in display
pixels, so one level deeper it spans half the world distance and the
anchor set contains every anchor of the level above: over the same data
(overzoom, and the provisional layout while a level loads) a street name
keeps its exact world position across a crossing — for a
`symbol-spacing` that does not change between the two levels, which is
how styles almost always declare it (a zoom-dependent spacing re-spaces
the line, and its anchors move with it). MapLibre's
`spacing/2 + k·spacing` from the line start shares no anchor between two
levels and moved every name by a quarter spacing at each crossing — the
same nesting Google's "label crawling" patent (US8237745) reaches by
bisecting from the midpoint. When the next level brings its own data
tiles the clipped parts differ, the midpoint moves with them, and the
fade tracker cross-fades the name as below. It runs as its own budgeted job after the
tile's raster (skipped entirely when no symbol layer intersects the
tile's zoom band),
and the tile's label text is shaped into the caches before the first
frame that can draw it, never during paint.

Repeated line text is intentionally retained through tile layout and
prewarming. MapLibre joins same-text lines end to end inside a tile before
spacing them; doing that here would re-parametrize every street per data
level and move its anchors at each crossing, so the duplicates are removed
in the final screen-space placement pass instead. That pass, which already
visits topmost layers first, applies a `symbol-spacing / 2` exclusion zone
across style layers reading the same source layer — but only between
anchors on the *same road*: the displacement between them must run along
either one's line direction (its across-line component within one text
height), so the split ways of one street suppress each other while a
motorway's two carriageways, a street's neighbouring switchbacks and
parallel same-named roads keep their labels. Anchors of one feature never
suppress each other (the layouter already spaced them along the path), and
retained previous-level candidates take no part in it — their spacing is the
old level's, and suppressing the arriving level's copies would only hand
them back as pop-ins when the level is released. Deferring the decision
until placement means an exact-zoom-gated, transparent or
collision-rejected candidate cannot erase a lower-priority fallback, and the
screen-space index also spans tile boundaries. Point and `line-center`
placement bypass the repeat index.

Icons are likewise resolved in that screen-space pass. Map-aligned point
icons include camera bearing; line-aligned icons add the projected line
bearing. Rotation is about the symbol anchor, so `icon-anchor` and
`icon-offset` rotate with the sprite, and the rotated extent is used for both
collision and bounded fade layers.

A symbol's text and icon are placed by MapLibre's rule (`_place` in
`label_painter.dart`). Each is tested against the boxes placed so far
with its own overlap mode — `text-overlap` / `icon-overlap`, else
`*-allow-overlap` as `always`/`never` — and the collision index keeps
`never` boxes apart from the rest, because a `cooperative` symbol
collides only with the former. Then `text-optional` / `icon-optional`
decide whether one half may show without the other, and whatever shows
reserves its space unless `*-ignore-placement` says otherwise. A symbol
allowed to overlap still reserves its space: it may be drawn over
others, but a later symbol that may not overlap keeps clear of it. A
half dropped by a pass is remembered with the sitting
(`SittingPlacement.textDropped` / `iconDropped`), since replay frames
decide no space and would otherwise draw it again. Copies of one label
share a sitting (a zoom crossing's two levels, a seam's two tiles), so
only the first one placed at a sitting in a pass writes it, and a later
copy with variable anchors may only take the anchor the first took —
never draw the label again at another. `icon-padding`
widens the icon's box, `symbol-avoid-edges` confines every box to the
screen bounds of the display tile the symbol was laid out in (every
`PlacedSymbol` carries its tile's transform for this), and
`symbol-z-order` orders a layer's symbols when drawn — by sort key,
screen y or source order, as MapLibre resolves it.

`icon-text-fit` sizes the icon once the text's box is known, wherever
the variable anchors put it: the fitted axes span the text plus
`icon-text-fit-padding`, and a sprite that declares `stretchX` /
`stretchY` is cut into slices, the stretch zones sharing whatever its
fixed pixels leave of the span and its `content` box landing on the
text. The slices are drawn as one textured mesh (`drawVertices`), so
neighbouring slices share their edges: drawn one by one, each slice's
antialiased edge showed the background along the seams. Text with a fitted icon is never curved; a shield stays a box.
`text-rotate` turns point-placed text (and its collision box, as an
axis-aligned bound) about its anchor, `text-rotation-alignment: map`
turns it with the map, and `*-translate` moves text and icon apart —
their boxes with them.

Halo blur is a Gaussian mask filter on the halo's stroke paint, with a
sigma matching the edge MapLibre's shader fades over ±1.19 × blur px.
Painted as a paragraph, every blurred halo would cost Impeller an
offscreen blur pass per label per frame: it reuses a blurred text draw
across frames only for the very same text object, and a paragraph
paint makes a new one each time. So a blurred halo is recorded into a
`Picture` once per shaped text, and replaying that picture hands
Impeller the same object every frame; it re-blurs only when the drawn
scale changes. Curved glyphs take their blur into the glyph atlas,
whose cells grow by three sigma. An SDF icon's halo blur needs no such
care: it only widens the ramp of the colour matrix that thresholds the
distance field. Text drawn from the style's glyphs is blurred the same
way: its halo is a threshold on the glyph's distance field, so a blur
widens that threshold's ramp by 2 × 1.19 × the blur, as MapLibre's
shader does, in the halo's atlas cell, which is rasterized once per
glyph, size, halo width and blur. Only platform-shaped text replays a
blurred picture.

That shaping is the expensive half — several times a frame's whole
render budget on a dense city tile, against sub-millisecond extraction —
so the symbol phase is **resumable**: it extracts the candidates once,
then shapes them in slices, checking the tick's budget between labels
and requeueing itself with a cursor when the budget runs out. The pump's
budget is therefore honoured *within* a job, not merely between jobs;
before this, one dense tile could overrun the whole tick several times
over, and there are a dozen such tiles in a crossing. A tile publishes
nothing until its whole batch is shaped — the label pass shapes on a
text-cache miss, so offering it a half-shaped tile would move the
remaining cost straight into paint, which has no budget at all. A tile
whose symbols are still pending counts as loading for the retention
rules, so the previous level's labels cover the gap; newly appearing
labels then fade in over `labelFadeDuration`, drawn in a few quantized
opacity buckets (one translucent layer each, bounded to what that
bucket paints) while reserving full-size collision space.

Everything the label pass remembers about a label is keyed on a
**label id** from `render/label_identity.dart` — the package's
counterpart of MapLibre's `CrossTileSymbolIndex`. A `SymbolInstance` is
built per display-tile layout, so a provisional→final republish, a
refresh, a zoom crossing or a cache hit hands the painter a brand-new
object for a label that never left the screen; the id is what that
object shares with the one it replaces. When a tile publishes its
symbols, `LabelIdentityIndex.assign` matches each one against the
labels already on offer — current tiles, the retained level, parked
ghost cohorts — by its position-free continuity key `(layer, text,
icon)` and its anchor in world space, within 32 logical pixels of the
finer of the two levels. A match inherits the label's id; anything else
gets a fresh one. The tolerance absorbs what differs between two
layouts of one label — a coarser level simplifies differently, an
ancestor-data layout clips differently — and stays well inside the
default `symbol-spacing`, so the repeats of a name along its street
keep ids of their own. Two rules keep distinct labels apart: matching
is one-to-one per publish (two labels of one tile never share an id),
and within one zoom level a tile may share an id with a *different*
tile only when its anchor coincides (1 px) with the copy that tile
holds — the one feature on a seam that both neighbours lay out. Each
label keeps one position per tile holding it for that reason. Within a
name the closest pairs match first, and a republishing tile's own
previous ids ahead of anyone else's, so whatever was on screen from it
stays the label it was. Most names are rare and are simply scanned;
icon-only labels all share an empty text, though, so a city centre
offers hundreds of one-way arrows under one key, and scanning them for
every symbol made a publish cost milliseconds on a phone. A name with
more than 16 labels is therefore also filed in a per-level grid of
32 px cells, and only the labels with a copy in the cells around a
symbol are compared.
The holder that took ids hands them back when it stops offering them —
replaced symbols, the retention pin, disposal, ghost expiry — so a
label stays known exactly as long as something can draw it. The ids
live in an `Int32List` per holder, not on the instances: the
finished-tile cache shares instances between layers with the same
style, and each layer has its own index.

Matching once per publish, in world space, replaced a design that
matched every frame in screen space: the fade tracker, the placement
memory and the ghost lookup each searched the label's key for the
nearest state within a radius and refreshed its position, and the
winner set was kept by instance identity, so a republish emptied it
until the next pass. With ids, the winner set, incumbency, fades and
placement memory all survive instance replacement as they are — which
is also what a placement pass that spans several frames, or runs on
another isolate, needs before it can commit winners that tile churn has
replaced in the meantime.

Which labels fade — in *and* out — is decided per frame, per label, by
`render/label_continuity.dart`. A `LabelFadeTracker` inside the label
painter holds one opacity per label id and integrates it toward "placed
this frame ? 1 : 0", a wall-clock fraction of the fade per frame.
Anything that appears eases in and anything that disappears eases out,
whatever the cause: a tile arriving, a zoom crossing handing over to new
tiles, a collision won or lost mid-gesture, a layer cut at its zoom
threshold. There is no per-cause bookkeeping, no publish-time diff, and
no moment at which the tile grid must be complete.

The identity's shape carries the anti-blink guarantees. The arriving
level's copy of a label lands a fraction of a pixel from the outgoing
one's, inside the match radius, so both carry one id: one copy draws,
at the id's opacity, and the swap is invisible — a label can never
cross-fade against itself; an exact positional key would miss on that
same noise and re-fade a label that never left. And what position
genuinely separates gets separate ids: two POIs sharing a name, the
housenumber "12" down a whole street, every parking icon on a layer,
and the re-spaced repeats of an along-line name (whose anchors move
when the next level brings differently clipped data, and which gain
in-between repeats one level deeper) each fade on their own. With one
state per name, a name still placed *anywhere* held every other copy at
its opacity — so those copies appeared and vanished as hard pops, never
fading at all, and a re-spaced street name teleported at full opacity
instead of cross-fading. Direction changes resume rather than restart:
a label re-placed mid-fade-out rises from where it is, so a label
briefly unplaced (a lost frame of collision) dips at most one opacity
step instead of blinking to zero. One copy per id draws in a frame,
the rest skipped before any layout, so seam twins no longer rely on
colliding with each other to draw once (in a layer that allows overlap,
they used to draw twice). Which copy is part of the decision, because
copies of one label can sit up to the match radius apart with geometry
of their own: the painter remembers the copy each label was drawn from,
replay frames draw that copy, a pass tries it ahead of the label's other
copies, and a fading label's ghost is drawn from it — another copy takes
over only once it is gone.

A third property joined them when placement became purely
interval-paced: **only a placement pass may start a fade-out**. Between
passes the winner set is frozen. A republished winner's successor
carries its id and is drawn as the winner it is, but a winner can still
be missing for a while — its tile gone before the successor published,
or a successor whose anchor moved past the match radius. Its ghost holds
at its current opacity, drawn from any copy still on offer, until the
next due pass either places it again or confirms the loss and starts the
fade. Decaying through that window instead made every label dim and
re-brighten at every crossing — fading into itself. A fade a pass has
started advances every frame, held or not.

Every label fades on **its own clock**, from the frame it is placed. The
invariant that makes this safe is that a placed label always paints
something: a key on its first frame has no elapsed fade time, so the
painter floors it at one opacity step rather than letting it draw at
zero. A no-fade paint clears the tracker immediately: when
`labelFadeDuration` changes to zero during a fade, no stale active state
remains to keep the widget's fade ticker scheduling frames indefinitely.

That is worth stating as an invariant because 2.7.0 broke it and had to
be reverted in 2.7.1. The reasoning then was that the pump publishes
roughly one tile per frame, so a crossing hands the painter a screen's
labels over tens of frames at as many different opacities — and each
distinct opacity costs a `saveLayer` whose bounds are the union of its
members', which for screen-scattered POI labels is the whole screen.
Grouping arrivals into waves that shared one opacity took the peak from
seven such passes per frame to two. But the raster thread it was meant
to relieve had already measured clear on the device in question. A
back-to-back A/B settled it: removing the waves *improved* UI-thread
frame time (p99 6.67 ms → 4.93 ms) and moved the raster thread from
1.63 ms to 1.93 ms at p99, against an 8.3 ms budget neither arm ever
exceeded. There was nothing on the other side of the trade, while the
cost was severe:

* A label queued behind a wave sat at exactly zero, where one frame of
  lost placement took `opacity -= step` below zero and dropped the key
  entirely. It then re-arrived as brand new and queued again — during a
  gesture, potentially forever. Measured over 120 frames, a label placed
  on 80 of them painted on 2.
* Because a label could only become visible when a wave *started*, a
  steady stream of arrivals appeared in bursts one fade duration apart
  rather than fading in continuously. That is what a zoom sweep
  produces, and it read as flashing.
* A queued label kept the collision space it had won while painting
  nothing, so for up to a fade duration there was a hole in the map that
  nothing else was permitted to fill.

The frame-time win at a crossing came from the pump slicing and the
cache sizing, both of which stand. The lesson to keep: a label that
holds a spot must paint, and zero is not a safe resting opacity in a
tracker whose sweep drops anything at or below zero.

Fade-outs draw as **ghosts**. A label that stops being placed keeps
being drawn for the length of its fade — from a copy of its own id still
on offer, laid out past the zoom gate that may just have cut its layer —
but claims no collision space. Whatever replaces the label therefore
places (and fades in) immediately, over the ghost, instead of waiting
for the fade to end and popping into the freed space. Because the ghost
is drawn from its own id, never from the name's priority-first
candidate, a street with several repeats or a name several POIs share
cannot teleport the ghost to a different label. When a retained tile is
disposed while labels from it may still be fading, its symbols — and
its label ids — are parked for one fade duration as ghost-only
fallbacks (plain Dart objects — no tile texture is pinned by a fade).

Retention feeds the tracker; it no longer decides fades. Retained
previous-level tiles keep offering their labels as ordinary candidates
while an overlapping current tile still lacks final label data (a tile
whose symbols are pending counts as loading, and provisional
ancestor-data cohorts do not count as coverage), and as ghost-only
fallbacks afterwards. One rule of the retention window remains, the
**pin**: the crossing that moves a level into retention cuts its
cohorts to what the last frame actually drew (`drawnLabels` against
`_drawnLastFrame` — candidates that were losing collision are dropped
for good, by label id, so a label the arriving level drew still counts
as visible in the outgoing cohort). An outgoing level exists to keep
what was visible, never to introduce labels: a crossing typically cuts whole symbol layers at
their `minzoom` — POIs, say — and without the pin the freed space would
go, mid-transition, to labels never before on screen, purely for the
arriving level to fade them back out.

**Placement itself is throttled.** The collision pass does not run every
frame: it runs once per `labelFadeDuration` (capped at 300 ms), and the
frames in between replay its decision — layout still follows the camera,
only *who is shown* is frozen, and the replay claims no collision space
at all. Deciding afresh every frame samples every transient a gesture
produces: label boxes scale with the zoom and swing with the rotation,
so neighbours drift through each other constantly, and a label that lost
its spot for three frames disappears and comes straight back. Fading
those changes makes them smoother but not fewer — the fix is to observe
the decision less often than the camera changes it, which is what
MapLibre does, at the price of a little transient overlap between
passes. Camera motion and changed candidates (tiles published or
expired) advance a placement generation; if the interval has not
elapsed, that generation waits for the next due pass — at most one fade
duration, the time a new label's fade-in takes anyway. A crossing churns
the candidate set every few frames, so placing on each churn would be a
10 ms+ collision pass several times a second on a symbol-heavy style.
Only a viewport resize places at once; replaying a decision taken for
another screen misplaces everything. A replay frame sorts only the last
pass's winners — on a dense screen about a hundred of a few thousand
candidates; the rest go straight to the fade-out fallbacks. The
priority order is total (insertion order breaks every tie), so the
winners come out exactly as a full sort would order them; sorting
everything cost 2.7 ms per frame on a phone during fast sweeps.

Curved text draws from a glyph atlas (`glyph_atlas.dart`). Each
grapheme is rasterized once per style and snapped device size onto a
1024² page, and a curved label then draws in one `drawRawAtlas` call
for its halos and fills — one per page when they straddle two, halos
first. Text from the style's glyphs (above) uses the same pages for
every label, curved or straight. Drawn as paragraphs, every glyph cost a
save, translate, rotate, scale, paint and restore, twice, which was most
of the label draw time on the UI thread and one text entity per glyph
on the raster thread. New glyphs are batched into one snapshot per page
per frame. When all pages are full, the least recently used page that
the current frame has not drawn from is emptied and reused. Atlas pages
are `toImageSync` rasters, so the layer stops new glyphs from being
rasterized while the app is away and clears the atlas in its resume
recovery. A paragraph label with a glyph missing from the atlas draws
glyph by glyph as before; a label drawn from the style's glyphs has no
paragraphs to fall back on and sits that frame out — which only
happens while the app is away, or when every page holds a glyph the
same frame draws.

The per-frame label pass looks a great deal up — every curved glyph in
the glyph cache and the atlas, every candidate's key in the fade
tracker and the placement memory — so those lookups are kept free of
string building and repeated hashing. A shaped text's grapheme clusters
remember their glyph-cache entry: within a placement pass a glyph is
taken from its cluster directly, across passes it is looked up by the
key string the cache already holds, never by a `styleKey#grapheme`
string built per glyph per frame (6.8 % of the UI thread's samples in
an Oct 2026 phone profile of the 150 ms sweep). The glyph cache's LRU
order is therefore by placement pass rather than by frame; an evicted
glyph is flagged, and a cluster holding one looks it up again. The
continuity key and the atlas key are small classes that compare their
fields like the records they replaced but compute their hash once.

A replay must not overturn the pass through the back door either.
Curved text is rejected when the line bends past `text-max-angle` under
it or when the text no longer fits along its line, and both depend on
the zoom, which a replay frame and a fade-out ghost see changing every
frame. So on the permissive index they never drop a label: the bend
check is skipped, and text that outgrew its line is drawn straight at
its anchor until the next pass decides. Re-judged per frame, a winner
whose bend or length sat near the limit vanished for a frame or two —
and its ghost with it, since the ghost runs the same check — and on
every zoom-out, street names whose text outgrew their stretch of road
popped out at full opacity. On a pass, a label already on screen keeps
its seat up to a quarter more bend than a newcomer may take, so a
sitting near the limit does not toggle as the zoom drifts across it.

`text-max-angle` limits the turn between neighbouring glyphs, and the
reading direction (`text-keep-upright`) is chosen once per label from
the chord between its ends, as in MapLibre. A road that turns back on
itself, such as Petersplatz in Munich looping round its church, can pass
the first at every step and still leave the glyphs past the turn upside
down. So a kept-upright curved label also has no glyph more than 30°
past vertical on screen (`_uprightSlack`): a pass rejects one that
would, and a replay or ghost draws it straight at its anchor, the same
as text that outgrew its line. The painter reports a pending pass
only while the latest generation differs from the one it placed, and the
fade ticker paints until that pass runs. The final settling repaint sees
the same generation and creates no new debt, allowing the ticker to stop
on an unchanged map.

**Placement passes prefer incumbents.** Candidate priority is topmost
style layer, then incumbency, then `symbol-sort-key`, then the current
level ahead of a retained one, then MapLibre's own order — data tiles
deepest first, then by x and y, and in each tile the features in the
order the tile lists them, each one's anchors from the start of its
line — and last insertion order. Nothing in it reads the camera, so a
pan or a rotation never reorders two labels, and a pair that collides
resolves as in MapLibre. An incumbent is a candidate whose label is
steadily visible right now: one of the last pass's winners, by label id,
which carries incumbency across the instance replacement every
republish and level swap performs, with or without fades. A same-layer arrival therefore never evicts a
visible label — it waits for space to be genuinely free — while a
higher style layer still wins, keeping the style author's hierarchy.
Without this, every crossing let the arriving level's re-ranked
candidates evict visible labels and hand the space back half a level
later: the visible→hidden→visible twitch. MapLibre has no equivalent —
its passes re-elect winners from scratch in deterministic order, and
fades only smooth the churn — so this is a deliberate divergence, and
`bench/`'s stability mode exists to measure it (`blink` counts).

Three placement choices are remembered so that a pass reproduces the
last one rather than re-deriving it from scratch — each is a spot where
an arbitrary tie-break used to move a label that had no reason to move:

* **Which carriageway draws a name.** A street name reaches the pass
  more than once — on both carriageways of one road — and which one
  sorts first depended on their screen y, so a slow pan walked the name
  across the street. The sort no longer reads the screen, but a zoom
  crossing still swaps the tiles and features it ranks the two by. They
  are different labels (different ids), and only the one on screen is
  an incumbent, so it keeps being tried first. The outgoing and
  arriving copy of *one* label at a zoom crossing share an id; the copy
  already drawn is tried first, so the arriving copy, which the sort
  puts ahead, does not take the label over from it.
* **Which `text-variable-anchor` it sits at.** Anchors are tried in
  style order, except the one the label is already at, which is tried
  first: a neighbour brushing past no longer pushes a label to its
  second choice and back.
* **Which way an along-line label reads.** The bare test — is the
  label's end left of its start — has its threshold exactly where a road
  runs vertical on screen, where the answer is a pixel of camera noise;
  a road near vertical flipped its label on alternate frames, and since
  a perpendicular `text-offset` is measured in the label's own frame,
  each flip also mirrored the label to the other side of the street. The
  decision now holds until the line is clearly (≈4.6°) past vertical.

The last two live in a **placement memory** on the painter, keyed by
label id, rather than on the `SymbolInstance`. Instances are built per
display-tile layout, so a zoom crossing, a provisional→final swap or any
re-layout hands the painter a brand-new object for a street that never
left the screen; state kept on the instance dies exactly there, and
since the label's fade carries over at full opacity the arriving copy's
cold decision would land with no crossfade to cover it. The id is shared
by exactly the copies of one label, so every same-named street keeps its
own side of the road while the arriving copy inherits the one it
replaces.

Symbols also ramp out over the last quarter zoom level before their
layer's declared `maxzoom`, so zooming past a threshold dissolves a label
instead of snapping it away. The ramp is a function of zoom alone — no
per-symbol history, and exactly reversible — and lives *inside* the
range, reaching zero at the threshold where the hard cut takes over.
Only `maxzoom` ramps: `minzoom` is inclusive, so a symmetric ramp would
leave a `minzoom: 14` layer invisible on a map resting at exactly zoom
14. The ramp may dim a symbol the style is about to remove, never one
the style says is fully visible. The per-frame
label pass evaluates at a zoom quantized to 1/8-level steps, so the
per-instance style memos — which compare evaluated primitives, not
strings — keep hitting on every frame of a pinch gesture instead of
missing on every fractional zoom change. Layer visibility is gated on
the *exact* fractional zoom rather than that quantized value: rounding a
size costs a fraction of a pixel, while rounding a discrete cut moves it
by up to 1/16 of a level, so labels would appear and vanish away from
the thresholds the style declares.

The whole layer is one `CustomPaint` — no per-tile widget churn, one
repaint boundary. The painter applies the camera transform (translate ·
rotate about the screen centre) itself; `MobileLayerTransformer` is not
used.

### Hillshade

A `hillshade` layer is a raster layer that is computed rather than
fetched. Its `raster-dem` source travels the raster-source pipeline
unchanged — bytes through the disk cache into `RasterTileStore`, decoded
by the platform's image codec off the UI thread, shared as ref-counted
`ui.Image` clones — and only the drawing differs
(`render/hillshade_renderer.dart`). It is MapLibre's two steps, both
on the GPU, through two fragment shaders the package ships
(`shaders/`, declared under `flutter: shaders:` in `pubspec.yaml` and
loaded once per process by `HillshadePrograms`):

1. **Prepare**, per DEM tile: a copy of its elevations with a
   two-texel border is drawn and snapshotted — the tile in the middle,
   the nearest two rows or columns of each neighbour around it, and the
   tile's own edge repeated where a neighbour is missing, as MapLibre
   leaves it until the neighbour arrives. `hillshade_prepare.frag` runs
   a Sobel kernel over that, on the raw 0–255 channel values — decoding
   is linear, so the sums are small integers, exact at any float
   precision, and only their result is decoded — and writes the
   west-east and north-south slopes, eight bits each, one texel per DEM
   texel plus a one-texel border.
2. **Shade**: `hillshade.frag` colours the display tile's part of the
   DEM tile per device pixel, from slopes interpolated between texel
   centres by hand (the sampler's own filter differs between backends),
   with the layer's method, lights and colours. It is recorded into the
   tile's picture like any other layer, so it runs once per
   rasterization, never per frame.

The two snapshots are at the DEM's resolution (260² and 258² texels for
a 256 px source) and transient: disposed as soon as they are recorded,
the tile's picture holding the pixels until it is rasterized. There is
no new cache, and nothing for the resume recovery to clear. Both are
`toImageSync` output, which Impeller's OpenGL ES backend stored
bottom-up until a Flutter release that defines
`IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED`, so both shaders flip their
texture lookups on GLES unless that macro is defined.

The border is what makes the shading seamless, and it costs loading
the neighbours: `_loadTile` asks for the eight DEM tiles around the data
tile (at overzoom only those of the edges the display tile touches) and
awaits them with the tile's other sources. Pending neighbours alone
never cause a provisional render, which would rasterize the whole tile
twice for its border. One that failed — rather than being known absent
— counts as missing, so the tile retries, and the neighbours are part
of the set a render is identified by, so the retry re-renders once they
are in. A background refresh of a DEM tile re-renders every display
tile whose edges read it.

The rasterizer reads the shaders synchronously, so a tile with a
hillshade awaits `HillshadePrograms.load` before it renders for good: a
result rendered without the shading would be cached as final. Where
the shaders cannot load (Flutter's retired HTML web renderer), a
warning is logged once and the layer is left out.

On the web, CanvasKit records a pointer to a `FragmentShader`'s
uniforms rather than a copy, and disposing the shader frees them. A
shade draw recorded into the tile, which is rasterized only once the
tile is complete, read freed memory there — correct until something
reused it, then streaks. So on the web the shade pass is rasterized on
its own first, which `toImageSync` does at once there, and the tile
records the image. Native backends copy the uniforms when the draw is
recorded and take the direct path.

Tiles are shaded once and turn with the map, so
`hillshade-illumination-anchor: viewport` is drawn as if the map were
not rotated; following the camera would mean re-rasterizing every
visible tile while it turns.

### Heatmaps

A `heatmap` layer is a kernel density over a source layer's points:
each adds `weight · intensity · exp(−½(3d/r)²) / √(2π)` at distance
`d`, `r` being `heatmap-radius` in logical pixels, and `heatmap-color`
is read at the sum through `["heatmap-density"]` — the spec's
definition, and the density MapLibre accumulates into its offscreen
texture. A kernel near a tile seam reaches into the neighbour, so the
density cannot be drawn into the tile images the way geometry is; like
MapLibre, it is computed in screen space over every visible tile's
points.

Unlike MapLibre, it is not recomputed every frame. MapLibre splats one
textured quad per point into a half-float texture per frame on the
GPU; here the only way to colour a density through an arbitrary ramp
on every backend (Skia, Impeller, CanvasKit) without a custom shader
is on the CPU, and an 8-bit offscreen layer would quantize every
kernel's tail away. So a **pass** computes the density over the
viewport plus a 64 px margin and colours it into one image, and the
frames after it draw that image under the camera transform, exactly as
the tile images are drawn: panning and rotating are exact, and a zoom
scales the kernels with the map — as the tile rasters themselves scale
between integer zooms — until the next pass. A pass runs when the zoom,
the tile set or the screen changed and 100 ms have passed since the
last one started, at once when the viewport has left the image, and
never while one is in flight. `heatmap-opacity` and the layer's zoom
range are applied per frame, so a style fading its heatmap out over a
zoom band fades smoothly.

The pass is split by what can leave the root isolate, which is
everything per point. The points are laid out once per display tile
(`HeatmapLayouter`, run where the tile's image publishes, kept with the
finished tile in the result cache) as `Float32List`s, so the UI thread's
share of a pass is a list of tiles: each one's offset and scale on the
screen, its point and weight arrays, and — for a retained tile — a mask
of the squares the arriving level already covers. Only weights and
radii that read both the feature and the zoom are evaluated there,
once per pass zoom, since expressions are closures and cannot travel.
Placing, culling and bucketing the points, the density and its
colouring are pure arithmetic over those lists
(`render/heatmap_density.dart`), so they run on a `HeatmapWorker` — one
long-lived isolate on native platforms, the event loop on web — and
the result comes back as `rgba8888` bytes for `decodeImageFromPixels`,
which needs `dart:ui` and stays. On the Nothing Phone (1), gathering
on the UI thread cost a median 1.2 ms per pass for 2,400 points and
10.7 ms for 40,000; listing the tiles costs a few hundredths of a
millisecond, whatever the points.

The density is sampled at σ/2 (σ = r/3) and never finer than
MapLibre's quarter of the device resolution. Two ways of filling the
grid give the same sums at different costs, and each batch takes the
cheaper: every point adding its kernel to the cells it reaches
(`N·(2h+1)²` for a reach of h cells, exact), or the points splatted
bilinearly onto the grid and blurred with the kernel along x and then
along y — the Gaussian is separable — at `cells·2(2h+1)` whatever the
number of points. The density is far smoother than the ramp drawn over
it, so the output image is up to twice as fine as the grid, the
density interpolated between cell centres before the ramp is looked
up: interpolating colours instead would smear every ramp stop that
falls between two cells.

Each point counts once. Like MapLibre, a point is taken only from the
data tile whose own extent holds it, never from the buffer a
neighbouring tile also carries, and at overzoom only by the display
tile whose window holds it; during a zoom crossing the retained level's
points count only where the arriving level has none yet, or the two
levels' copies would double the density where they overlap.

The heatmap draws above every geometry layer and below the labels,
whatever its position among the style's layers: it would otherwise
have to split each tile image in two at the heatmap's position. That
is where styles put their heatmaps — under the labels, over the map —
and in `LabelMode.tile`, whose labels are part of the tile images, it
covers them. Only point features count, as for circle layers;
MapLibre takes the vertices of lines and polygons as points too.

### Labels in the tile image (`LabelMode.tile`)

Everything above about labels buys its quality with UI-thread time on
every frame the map moves: every placed label laid out and drawn
again, and a collision pass over every candidate at each placement
interval. `LabelMode.tile` is the other trade, the one
`vector_map_tiles` makes in its default raster mode. Labels and icons are
placed and drawn once per display tile, into the same image as its
geometry, and a moving map then costs what a raster tile layer costs:
no per-frame label work. A tile that arrives while the map moves still
has its labels laid out, shaped, placed and drawn — once, inside the
render pump, like its geometry.

It is the same pipeline with a different ending, not a second text
stack. The raster phase records the tile's geometry in slices as in
the default mode (`TileRasterizer.recordSlice`, stacked by `compose`)
and, instead of taking its image, hands the composed `Picture` to the
symbol job it enqueues (`_RenderJob.geometry`). That phase lays out and
shapes in budgeted slices exactly as before; once shaping completes,
`LabelPainter.paintTile` places the candidates and draws the winners
over the nested geometry picture, and a single `toImageSync` produces
the tile's image — one snapshot per tile, as in the default mode, and
the picture costs no texture while it waits. Placement, drawing and
snapshot are one unit of work, the largest a tile in this mode has,
so when shaping finishes with the frame's budget already spent, the
job is requeued and the unit runs in a later frame — as that pump's
first job, or while it still has budget, never on top of a frame that
is already full. The tile is then published
once, image only, with an empty candidate list, so the per-frame label
pass, the fade tracker, the retained-label pinning and the ghost labels
all have nothing to do and are skipped. Until that publish the tile
counts as loading, so the previous level — with its own labels in its
images — keeps covering it; and since a tile now shows only once both
of its phases are done, the pump drops its phase-major order (all
rasters first, which would hold every tile back until the last raster
had run) for a tile-major one that finishes the most central tile
first.

`paintTile` is one placing pass of the screen pass's own `_prepare`, so
curved text and the glyph atlas, variable anchors, halos, SDF icons and
repeat suppression all come along unchanged. What it carries over from
one call to the next is nothing: no fades, no throttle, no incumbents,
and a placement memory and repeat-anchor map swapped in fresh for the
call. A tile's image is therefore a pure function of its candidates —
which the finished-tile cache depends on — and the screen pass's state
is never disturbed. Its collision index is bounded by the tile, and
every box must lie inside it, `*-allow-overlap` ones included: a label
the layouter anchored in this tile but which runs over the edge would be
cut off there, and the neighbour that would have to draw its other half
never sees the candidate. Such labels are dropped, which leaves gaps
along tile seams — the same behaviour as `vector_map_tiles`. Repeat
suppression stops at the tile edge for the same reason: two ways of
one street meeting at a seam can each show its name, a few pixels
apart, where the screen pass would keep one. MapLibre
avoids it with cross-tile placement (labels placed once for the
viewport, then assigned to the tiles they overlap); that is a possible
follow-up, not something this mode attempts.

The other limits follow from the image. Text is evaluated at the tile's
integer style zoom and drawn at that size, then scales with the tile
(1× up to 2× before the next level replaces it), and turns with the map
under rotation. A symbol layer's zoom range is applied per tile zoom
level rather than at the exact fractional zoom — `minzoom: 12.2` shows
from 13, `maxzoom: 16.5` until 17, as geometry layers already do in
both modes — and the `maxzoom` ramp is evaluated at that level too. The
layouter applies the same gate in this mode (`exact`), rather than the
screen pass's band, so a layer the tile will not draw is neither laid
out nor shaped. Labels fade in with their tile over
`tileFadeDuration`; `labelFadeDuration` does nothing.

Being a `toImageSync` like any other tile raster, the labelled image is
covered by the backgrounding workaround below without further work: it
is only ever made inside the render pump, which the lifecycle gate
parks, and the glyph-atlas pages it may add to are discarded with the
rest on the way back in. Switching modes, or toggling `showLabels` in
tile mode, changes what a tile image contains, so the live tiles are
rendered again and the outgoing level's queued jobs are retired — a job
decides at run time which kind of image to make, and would otherwise
publish, and cache, the wrong one.

## Rendered-feature queries and feature state

A `VectorTileLayerController` attached to the layer answers
`queryRenderedFeatures` and holds feature state. Both are built from
what the layer already keeps for drawing, so a layer without a
controller pays nothing, and one with a controller pays only when it is
asked something.

A query has two halves, because the map is drawn in two. **Labels and
icons** come from the label pass: the painter keeps the drawables its
last frame drew (one reference per frame, nothing computed) and works
out their shapes only when queried — the icon's rectangle turned about
its pivot, the text's box turned with it, and for curved text one box
per glyph, so a diagonal street name is not hit across the whole
rectangle it spans. Those shapes read the frame's text painters, so
everything that disposes painters between frames (`trimCaches`, the
retirement `paintTile` runs, `reset`, `dispose`) drops the list first.
Fading-out ghosts and symbols the zoom ramp has retired are not on
screen as far as a query is concerned. In `LabelMode.tile` the labels
are part of the tile image and the per-frame pass has none, so
`paintTile` reports what it drew as packed quads in tile pixels, kept on
the display tile and in its finished-tile cache entry (eight floats a
quad, a few kilobytes a dense tile).

**Geometry** comes from the decoded tiles, decided exactly as the
rasterizer draws: the same layers at the tile's integer style zoom, the
same filters through the same once-per-tile match lists, line widths
(with `line-gap-width`, the outer edge of the casing) and circle radii
evaluated at that zoom in the tile's logical pixels — which is what the
tile image then scales between levels — and polygons filled by the same
non-zero rule, so a hole is not a hit. The query is mapped through the
inverse of the painter's translate · rotate into world pixels, into each
display tile's logical pixels, clipped to the tile, and then into the
data tile's extent units, rather than every candidate feature into
pixels; features are rejected on their decode-time bounds before any
expression runs, and within a feature, edges whose bounds miss the query
area (widened by the half width, for lines) are skipped before any
crossing test. That second cull is what keeps big features cheap:
OpenFreeMap's z14 tiles merge whole blocks of buildings into one feature
of up to ~1,000 rings, whose bounds pass the first test for nearly any
query on the tile. A polygon needs one non-zero winding pass after its
edges, not one per query corner: when no edge enters the area, all of it
lies on one side of the outline. Clipping to the display tile is what
makes overzoom answer for the window a tile shows and keeps a rectangle
that crosses a seam from matching one tile's buffer geometry on the
other side. Paint
opacity is not consulted, as in MapLibre. A feature with an id is
reported once per style layer across tiles; one without is reported
once per decoded feature object, which every display tile cut from one
data tile shares. A tile still loading answers from the data it is
provisionally drawn from. The query is synchronous and reads only what
is in memory: GPU picking (an id buffer rendered alongside) would need
a second render of every tile for an answer the CPU gives in about a
millisecond (1.1 ms for a point, 2.0 ms for a 48 px square, medians on
the Android phone over a dense z16 screen).

So that "in memory" holds for everything on screen, a layer with a
controller keeps, on each live display tile, the decoded data its image
was drawn from (`_DisplayTile.sources`). The decoded-tile cache is
bounded by bytes and the finished-tile cache by texture bytes, and the
two forget independently: after `clearMemoryCache()`, under a small
`memoryCacheMaxBytes`, or for a tile served from the finished-tile cache
the decoded data may be gone while the image stays — a query would find
no geometry there and a state change could not tell whether to redraw.
A tile served from the finished-tile cache therefore fetches its data
at the lowest priority. Without a controller nothing is held, so the
decoded-tile budget means what it always meant.

Decoded tiles keep only the properties the theme reads (see
Concurrency), so that is all a result carries unless the layer sets
`retainAllProperties`, which decodes with every source layer's keep-list
lifted. The keep-lists are part of the decoded-tile cache's signature,
so the two never share entries.

**Feature state** lives in the controller, keyed by source, source layer
and id. Ids are normalized the way MapLibre matches them — it
stringifies both sides; here integral numbers and canonical integer
strings become an `int` — so the lookup for an MVT id is a map probe
with no string built per feature. The parser compiles `feature-state`
into a read of the state a `FeatureEvalContext` carries (null in a
plain `EvalContext`), counts it as reading the feature (so the property
is never memoized against the zoom), and records per layer that it
reads state (`ThemeLayer.readsFeatureState`). The rasterizer fetches a
source layer's state map once per layer and only for such layers, so a
style that reads no state, or a source layer with none set, costs no
lookup per feature. Only a feature that has state, or one whose layer
reads its geometry (`within`, `distance`, below), is evaluated in that
larger subclass: a context is allocated per feature, and one field more
on every one made fresh-tile filter matching measurably slower on the
Android phone. The builder that picks between the two is forced inline
for the same reason: as a plain call it cost the screen pass dropped
frames whenever the zoom reached a level not drawn yet.

A state change redraws the least it can. Only layers reading state can
draw a feature differently, so a change on a source layer none of them
draws does nothing at all. Otherwise the display tiles that draw the
feature are found through an index of each decoded source layer by id
(built on first use, held weakly like the match lists) and the
feature's bounds against each tile's window plus the cull buffer — at
overzoom most display tiles cut from the data tile are not touched.
Those are rendered again from the data already in memory, ahead of all
queued work and without a fade, since the change is the point; a tile
showing an image whose data cannot be checked is rendered again too,
which fetches it. A symbol layout cannot read state, so in the default
label mode only the geometry is redone: the tile keeps its published
symbols, and with them the placement, instead of handing the label pass
a republish — provided the tile's sources are the ones those labels
were laid out from (a source that failed then and arrives now brings
labels of its own). Labels
whose paint reads state need no redraw of anything — their text style
memo carries the state version it was evaluated at, so the next frame
re-evaluates them.

The finished-tile cache is shared by every layer over the style, and
state belongs to one controller, so the two are kept apart: a tile drawn
with any feature's state is never cached, and a tile that may draw a
feature with state is never served from the cache — "may" because a
source whose decoded tile is no longer in memory cannot be checked, and
counts as yes. "Drawn with state" is judged when the result is cached,
which is not when it was recorded: a job carries the state version it
began under, and one that finishes under another is not cached at all.
A zoom crossing that retains a tile mid-render, followed by a cleared
selection, would otherwise cache the highlight as a stateless render.
Only layers that draw into the image count — screen-space labels follow
state every frame, so state only their paint reads blocks no caching.
Clearing the state makes the cached, stateless render valid again,
which is how a cleared selection usually comes back without drawing
anything.

A source's `promoteId` is applied on the worker at decode: the named
property's value (booleans as 1/0, anything but a number or string as
no id) replaces the tile's own id, and the property is added to the
keep-list so it can be read. It is part of the decoded-tile cache's
signature and of the render signature, since `["id"]` sees it.

## Concurrency

MVT decoding, and trimming each tile to the source layers and
properties the theme reads, run on a small isolate pool with a priority
queue (tiles closest to the camera centre first) and
*silent* cancellation — a cancelled job never surfaces an exception.
`PreparedTile` keeps geometry in `Float32List`s (tile-extent units) so
isolate transfer is cheap, and only the feature properties referenced by
the theme are retained.

The workers also resolve the theme's zoom-free layer filters while they
prepare a tile, into per-filter `Int32List`s of feature indices
(`PreparedSourceLayer.matches`). A filter is a closure and cannot cross
an isolate boundary, so it travels as its JSON: the theme reader interns
the canonical JSON of every zoom-free filter that reads neither
`global-state` nor the feature geometry into a process-wide id
(`style/filter_ids.dart`), a job names the ids its tile needs, and the
executor sends a worker the JSON of each id once, with the first job
that needs it; the worker compiles it with the theme reader's parser and
keeps it. Ids are keyed by filter content, not by theme, so the light
and dark variant of one style share them, a tile prepared for one theme
serves another over the same source for every filter they share, and a
changed filter can never be read through a stale id. A tile resolves
only the filters of layers that draw in its own zoom band
(`pipeline/tile_filters.dart`'s `TileFilterPlan`: zoom z, or everything
past the source's deepest level and before its shallowest). The match
lists count towards the tile's `byteSize`.

Requests are coalesced per key at every level (`SingleFlight`); a
coalesced load polls a token joined over *all* its waiters, so one
cancelled waiter never aborts work others still await. Transient
failures are throttled (15 s per key) and visible tiles retry a bounded
number of times just past that throttle; a worker isolate that dies is
replaced, and if isolates cannot be spawned at all the pool falls back
to the event loop permanently.

On web (no isolate support for this workload) the pool degrades to
chunked event-loop execution, and resolves no filters: on the event
loop the scan costs the UI thread the same either way, so it stays
lazy there and only runs for the layers a tile actually draws.

A style with a heatmap layer gets one more isolate, spawned on the
first density pass and kept for the layer's lifetime
(`render/heatmap_worker.dart`): a pass is a few milliseconds of
arithmetic every 100 ms at most while the map zooms, and sharing the
tile pool would queue it behind tile preparation exactly when a zoom
crossing needs both. One pass is in flight at a time; a disposed layer
completes it with null, never an error. If the isolate cannot be
spawned the passes run on the event loop, as they do on web.

## Caching

| layer | keyed by | bounded by |
| --- | --- | --- |
| memory: `PreparedTile` | data tile, per source (`provider.cacheKey`) and property keep-lists | entry count + bytes |
| memory: raster-source `ui.Image` | data tile per raster source | entry count + bytes (handed out as ref-counted clones) |
| memory: finished display tile (raster `ui.Image` + symbols + heatmap points) | display tile, per render signature (theme id, providers, dpr, sprite and glyph *content*, labels, label mode) | GPU texture bytes, plus the heatmap points' bytes (`rasterCacheMaxBytes` — by default sized from the live viewport and dpr, see below; cache owns the master image, tiles hold clones); retained signatures bounded by their combined cost |
| disk: raw tile bytes | hash of `provider.cacheKey` + z/x/y | TTL + total size sweep |

All caches are plain deterministic LRU implementations — no external
cache framework. Every `ui.Image` has exactly one owner and is disposed
on eviction or layer dispose; disposing the layer tears down isolates,
pending requests and its owned images (verified by tests). Each live
display-tile model owns exactly one `ui.Image` (a clone, when it came
from the result cache); the result cache separately owns its master
images and is shared process-wide, so revisiting a zoom level — or
reopening a map over the same style — swaps finished tiles back in
without touching the pipeline. The signature identifies the sprite sheet
by content (`SpriteAtlas.signature`, its URL when `StyleReader` loaded
it), never by object identity: re-reading a style builds a new atlas
every time, so an identity key would miss on every open and strand the
previous signature's textures. The glyphs enter it the same way
(`GlyphSource.signature`, the glyph URL template), since tiles with
their labels drawn in depend on them. Signatures are retained past their
layer for exactly that warm-open case, so the registry releases the
least recently used once their combined cost exceeds the budget —
always keeping the two most recent, so two layers over different styles
cannot evict each other.

A result-cache hit hands back a finished raster and a finished symbol
list, but not shaped text — the text caches belong to the live
`LabelPainter`, not to the cache. The hit is served synchronously inside
`build` (nothing awaits above it, and the grid update loads every tile
of the arriving level in one pass), so shaping there would put a whole
screen's paragraphs into a single frame — the very spike the pump's
budget exists to prevent, on the path that is supposed to be the fast
one. The hit therefore takes the imagery immediately and enqueues a
symbol phase that owes only the shaping, which the pump slices like any
other. Those jobs are flagged (`_RenderJob.fromCache`) so they are not
written back into the cache they came from: a second `put` under the
same key would mint a second master image and dispose the one the
display tile's clone came from.

That makes a hit only as cheap as the text cache is large:
whatever was evicted since the level was last on screen is shaped
again. So the cache is sized to hold a zoom round trip, not just one
screen: a phone-portrait fling from z15 to z17 and back over central
London shapes about 7,400 distinct texts with `TileOffset.none`. At the
2500 entries it used to hold, z15's text was gone by the time the fling
returned, and the pump re-shaped it for 4–7.5 s after the camera stopped;
at 8000 the same fling settles in 0.3 s. The price is memory once that
many labels have been drawn: after a run through four dense cities the
phone held 37–49 MB more RSS with the default offset, and 117–119 MB
more with `TileOffset.none`, whose peak rose from 384 to 491–495 MB
(`compare/results/raw/2026-10-12-textcache-android`).
The text caches belong to the live painter, so nothing but eviction at
the cap frees that while the map stays open — except
`VectorTileLayer.clearMemoryCache()`, which calls `trimCaches()` on
every mounted layer's painter. Every text and glyph lookup stamps the
entry with the current placement pass, and the trim keeps only what is
stamped with it: whatever was used since the last placing pass began.
That is every candidate on screen, collision losers included, since a
placing pass lays them all out, plus whatever the pump has shaped since
then. In `LabelMode.tile` every `paintTile` call counts as a pass.
A placing pass only looks up labels within 150 px of the screen and of
layers in zoom range, though, while the pump shaped every published
tile's, the buffer ring's included; trimmed, that text would be shaped
again in paint as soon as the map moved toward it. So the layer first
runs `prewarm` over the symbols of every tile it holds — cache hits,
which stamp them — and the trim takes only text for places the map has
left. A tile whose shaping straddles a pass loses the part shaped before it to
a trim, so the layer's trim also rewinds every queued symbol job's
shaping cursor: the pump goes over the batch again within its budget,
a cache hit for what survived and a fresh shape for what did not,
instead of publishing the tile and leaving the label pass to shape the
rest inside a frame. Placement passes
rather than frames, because a frame replaying a decision lays out only
its winners; keyed on that, the trim would drop on-screen losers, and
the next pass would shape them again inside a frame. The evicted
painters are disposed at once: memory pressure often comes in the
background, where no next pass arrives to retire them. On that phone
RSS fell 23–43 MB within 3 s of the trim, not all the way back to what
2500 entries had held (`compare/results/raw/2026-10-20-trim-android`).

In `LabelMode.tile` the cached result is the labelled image with an
empty symbol list, so a hit owes no shaping and is complete the moment
it is served. The label mode is part of the render signature because it
decides whether an image has its labels in it: served across modes, a
cached screen-mode tile would show no labels at all, and a tile-mode
one would show every label twice. The image is the same size either
way, so `rasterCacheMaxBytes` and its automatic sizing hold unchanged.

The budget for that cache is sized from the device rather than fixed.
One display tile costs `(256·dpr)²·4` GPU texture bytes and one phone
screenful is 25–35 tiles, so a *single* zoom level runs to ~80 MiB on a
large dpr-3 phone — against which the 64 MiB this used to default to
held **0.81 of a level**. The cache could not hold even the screen it
was looking at, so oscillating across a zoom threshold evicted the level
it was about to return to and re-rendered everything, every crossing.
`autoRasterCacheBytesFor` budgets 2.5 screenfuls instead (clamped to
64–256 MiB): two levels is the minimum a round trip needs, one each side
of the threshold, and the half is headroom for the buffer ring. Measured
on a dpr-3 phone crossing a POI threshold about seven times a second,
that took a crossing from ~1200 re-rasterizations and ~1200 re-layouts
per eight seconds to **zero**, and doubling the budget again changed
nothing — so it is the knee, not a guess.

Only final, fully-sourced results are cached, so a hit can never mask a
pending retry. Render jobs and loads carry the tile generation they were
built for and are dropped once it moves on, so content replaced by a
revalidation can neither be painted nor written back into the cache that
revalidation just invalidated. Beyond the cache's budget, revisiting a
zoom re-rasterizes from the `PreparedTile` LRU — cheap, since only the
visible window is processed. `VectorTileLayer.clearMemoryCache()` empties
all three memory tiers at once — the memory-pressure valve, since the
caches are process-wide and otherwise freed only by their budgets; the
disk cache is untouched. It also trims each open map's label text to the
labels on screen (see above).

### Surviving a backgrounding

**This section describes a workaround for an engine bug, not a design
commitment — see the end of it for when to delete the whole thing.**

Being GPU-resident is what makes a finished tile cheap to keep and cheap
to draw, and it is also the one thing about it that an operating system
can take away. iOS revokes GPU access for a backgrounded process, and a
`toImageSync` raster whose Metal work is rejected does not fail —
Impeller fills the texture with solid magenta. Nothing above the
rasterizer can tell such an image from a real tile, so it paints, and
caches, exactly like one; process-wide caching then makes a moment's bad
luck last the whole session.

The layer therefore tracks the app lifecycle, and the state that matters
is `inactive`, not `paused`. The scheduler keeps frames enabled through
`inactive` — that is what draws the app-switcher snapshot on the way out
and the first frames on the way back in — while the context is revoked
somewhere alongside it; from `hidden` onwards no frames are produced at
all. So on iOS the render pump refuses to run below `resumed`, parking
its queue rather than dropping it. Everywhere else it keeps running
through `inactive`, which there means a window that is visible but not
focused — a desktop window behind another app, a browser window that
lost focus, the other half of an Android split screen — and gating it
made such a window paint its background colour for every tile it had
not finished; from `hidden` on, the gate is shut on every platform. On
the return the layer discards the
finished-tile cache, the raster-source images and the pattern stamps and
re-rasterizes its live tiles. That recovery is cheap for the same reason
the pipeline is split the way it is: only the last stage was affected,
and the decoded geometry it re-renders from never left the Dart heap —
no network, no isolate, no decode. Live tiles keep their imagery until
the replacement lands, so nothing blanks.

The "has been away" mark is process-wide rather than per layer, because
what it condemns is: a map screen rebuilt during the return is a
brand-new layer that lived through no backgrounding of its own, and a
per-layer flag would leave it reading suspect textures out of a cache no
surviving observer was there to clear. A departure that only reaches
`inactive` — a permission dialog, a control-centre swipe — gates
rasterization on iOS but marks nothing, so the common case costs no
re-render.

Of the two halves, the recovery is the guarantee and the gate is only a
mitigation: `toImageSync` hands back a *deferred* image, so the raster
thread can get to it after the transition the gate was checked before.

**When this can go.** The engine already has the guard this needs and
does not apply it to the sync path. In
`engine/src/flutter/shell/common/snapshot_controller_impeller.cc` (read
against `flutter/flutter@master`, August 2026),
`MakeImpellerSnapshot` — behind `Picture.toImage` — runs under
`GetIsGpuDisabledSyncSwitch()` and parks the work via `StoreTaskForGPU`
when the GPU is disabled, while `MakeImpellerSnapshotSync` — behind
`Picture.toImageSync` — calls `DoMakeRasterSnapshot` directly, with no
switch and no deferral. The engine's shipped fixes for the same symptom
([#169378](https://github.com/flutter/flutter/pull/169378),
[#169596](https://github.com/flutter/flutter/pull/169596), cherry-picked
in [#170846](https://github.com/flutter/flutter/pull/170846), and the
follow-up [#190445](https://github.com/flutter/flutter/pull/190445)) all
harden the image *decode* path instead. The `toImageSync` variant is
tracked upstream as
[flutter#191255](https://github.com/flutter/flutter/issues/191255), filed
from this investigation — every *other* "pink images" issue is closed and
is the decode path, so finding those closed is not evidence that this is
fixed. Once the sync path defers, drop this section along with the
lifecycle members in `vector_tile_layer.dart` and
`test/app_lifecycle_raster_test.dart`, and raise the package's Flutter
constraint to the first release carrying the fix.

The disk layer is skipped entirely for providers whose bytes already
live on the device — `VectorTileProvider.cacheBytesToDisk` returns false
for the memory provider and for local-archive providers such as the
companion MBTiles package. Mirroring them would store every
tile twice and leave a zero-byte sentinel for each coordinate the source
does not cover. The opt-out covers reads as well as writes, so an entry
written before a source became local cannot shadow it; with no cache
behind it, `TileByteLoader` never reports bytes as stale and the
revalidation machinery below simply never engages. Failure throttling is
independent of the cache and stays active either way.

The disk TTL is a *revalidation* deadline, not an expiry: expired
entries — including the zero-byte "known absent" sentinels — are served
immediately and refetched in the background (stale-while-revalidate,
`TileByteLoader.refresh`). When the refetch delivers different bytes the
store re-decodes them, replaces the memory entry and notifies the layer,
which re-rasterizes the affected display tiles; the previous raster is
kept as an underlay for the duration of the fade, so the swap
cross-fades instead of dipping to the background.

Three properties keep that deadline honest:

- **Nothing serves content the check never reached.** A refresh
  reports failure distinctly from "unchanged", so an absence recorded
  from an expired sentinel is withdrawn when the source could not be
  reached — otherwise one failed request would strand the tile for the
  session, since `obtain` short-circuits on a known absence.
- **A stale entry that cannot be decoded still gets refetched.** The
  revalidation runs even when the served bytes fail to prepare, because
  it is the only thing that rewrites the disk entry; without it a torn
  write would fail identically on every retry until the size sweep.
- **A display tile served from the finished-tile cache is checked
  too** (`TileStore.revalidateIfStale`). It never reaches the stores,
  so nothing else would notice its data expiring. Data tiles still held
  in memory are skipped — loading them ran the check already — leaving
  one disk lookup for the case where a rendered result outlived its
  source data.

A failed refetch changes nothing displayed: the stale entry stays
servable and is only ever deleted by the size sweep. It does not
throttle *loads* — that would make the failure worse than the staleness
— but it does throttle further *refreshes* of that key, so browsing an
expired area offline cannot start one request per memory-cache miss.

On web the disk row is absent: the cache resolver
(`cache_resolver_stub.dart` vs `cache_resolver_io.dart`, mirroring the
executor's conditional import) resolves to no persistent cache, and
`TileStore`/`StyleReader` already tolerate a null cache — tiles degrade
to the memory LRU plus the browser's HTTP cache.

## Style engine

The style reader accepts real-world MapLibre/Mapbox GL styles and is
deliberately tolerant: unknown layer types, unknown paint properties and
unparseable expressions degrade per-layer (with a log), never failing the
whole style. Expressions are compiled once into Dart closures; both the
modern expression array syntax and the legacy filter syntax are
supported. The parser proves per property whether an expression reads
feature data — properties that depend only on the zoom (most paint
properties are pure zoom ramps) memoize their coerced result against
the zoom in the typed wrappers, so a tile pass or a label frame
evaluates each once instead of per feature. It also records whether a
layer's filter reads the zoom (`ThemeLayer.filterReadsZoom`); a filter
that does not is resolved once per prepared tile instead of per display
tile, on the worker isolate where there is one (see Rendering model and
Concurrency). Parsed CSS colours are
memoized process-wide for the same reason. Sources are resolved through TileJSON when `url` is present,
including `{key}` substitution. Whatever a source (or its TileJSON)
declares as `attribution` is collected into `Style.attributions`,
deduplicated across sources; since that value is HTML by convention it
is parsed into both flattened text and text-plus-link spans, because
Flutter has no DOM to hand it to. Relative URLs resolve against the
document that declared them — sprite, glyph and source URLs against the
style URL, tile templates against the TileJSON URL when they came from one
(ArcGIS declares `"url": "../../"` and `tile/{z}/{y}/{x}.pbf`) — and
the `{z}`/`{x}`/`{y}` braces survive resolution un-percent-encoded.

`StyleReader.language` is applied to the style document, not to the
engine. Before `ThemeReader` compiles anything, `localizeStyle`
(`style/label_language.dart`) rewrites each symbol layer's `text-field`
so that the smallest subexpression holding every name reference
(`name`, `name:*`, `name_*`) becomes
`["coalesce", ["get", "name:<lang>"], ["get", "name_<lang>"], <original>]`,
and folds `resolved-locale` to the language wherever it appears. The
smallest subexpression, not the whole field and not each reference:
wrapping the field would drop what is shown beside the name (an
elevation, a `({ref})`), and wrapping each reference would show the
translation twice where a style stacks `name:latin` over
`name:nonlatin`. Inside a `concat`, only the run of arguments spanning
the names is wrapped, for the first reason; an expression that chooses
between branches (`case`, `match`, `step`, `coalesce`, `string`) wraps
each branch showing a name on its own, for the same reason, and the
whole once only when every such branch is nothing but a name. Only references whose value
can reach the label count, so `case` conditions, `match` inputs,
comparisons and `has` are never touched. Legacy `{token}` templates and
zoom stop functions are first turned into the `concat` or `step` they
evaluate as, and only when they reference a name; with no language the
document is passed through as the same object. Because the rewrite
precedes compilation, the parser records `name:<lang>` and
`name_<lang>` like any other reference, so tile preparation keeps them
unprompted, and the property keep-lists that key the decoded-tile cache
differ per language. The finished-tile cache is keyed by the theme id,
and its tiles hold label text (baked into the raster with
`LabelMode.tile`), so a language makes the id `<id>|language=<lang>`.
The style disk cache holds the document as served; the rewrite runs on
every read.

Global state is compiled in, too. `["global-state", name]` becomes a
constant: the style's root `state` default, or the value the theme was
asked for with `Theme.withGlobalState`. A runtime lookup would have had
to version three caches that all assume a theme never changes what it
computes — the zoom memo in the typed props, the per-tile filter matches
and the finished-tile cache — so instead each state is its own `Theme`.
When any layer reads global state, `ThemeReader` keeps the style
document in a family that compiles siblings on demand and keeps the
eight most recent, so the same state is the same instance, a `build`
method asking again changes nothing, and the default state keeps the
style's plain id while others append `|state=<json>`. Siblings read the
same feature properties from the same sources, so `VectorTileLayer`
does not rebuild its stores for one: it re-renders the live tiles from
the decoded data, as for a sprites change, the old imagery holding
until each replacement lands. Recompiling Liberty takes 0.4–0.8 ms
on a Nothing Phone (1); the cost of a state change is drawing every
visible tile again.

`within` and `distance` read the feature's geometry, which nothing else
in the engine does. The parser flags them (`ThemeLayer.readsGeometry`),
and only for such layers do the filter matcher, the rasterizer and the
symbol layouter build a `FeatureGeometry` — the data tile's z/x/y and
extent plus the feature's coordinate runs — and evaluate in a
`FeatureEvalContext`, the internal subclass that also carries feature
state (above); symbol instances carry it for the per-frame label pass.
Every other layer
keeps the plain `EvalContext`: one is allocated per feature evaluated,
and a field more on every one made filter matching on a fresh tile
measurably slower on a phone. The GeoJSON
argument is parsed once. `within` runs in Web Mercator on the feature's
own grid, `distance` on a local flat approximation of the ellipsoid
around the feature's first coordinate, both following MapLibre's
definitions. The answer depends only on the feature, so it is memoized
per feature (an `Expando` on its coordinate list) and costs one
geometry test per feature, not one per display tile.

The engine is held to maplibre-style-spec's own expression fixtures
(`test/maplibre_expression_conformance_test.dart`): every fixture
MapLibre evaluates must give MapLibre's result as the renderer reads it,
or be listed with the reason it does not.

The sprite sheet is repacked once after decoding (`padSpriteSheet` in
`style/sprite_packer.dart`): every distinct sprite rectangle is copied
byte for byte into a new sheet with a 2 px transparent gutter, and the
index is rewritten to the new positions (each sprite keeps its
`stretchX`, `stretchY` and `content`, which are relative to the image
itself, for `icon-text-fit`). Published sheets pack icons
edge to edge, and an icon drawn magnified or at a fractional position
is sampled bilinearly half a texel past its rectangle, so without the
gutter it shows a hairline of its neighbour. Two pixels rather than one
because ordinary icons draw with mipmaps. The copy reads the sheet back
as premultiplied RGBA and decodes it again with `decodeImageFromPixels`,
which keeps it web-safe and off `toImageSync`; the decode runs in a
guarded zone because that API reports failure only as an uncaught
error, never through its callback. If the readback or decode fails, or
the packed sheet would exceed 4096 px on either side, the original
sheet is kept.

Sources whose `url` starts with `pmtiles://` bypass TileJSON entirely:
`PmTilesVectorTileProvider` reads the single-file archive over HTTP
range requests. Its `open()` fetches the 127-byte header plus root
directory in one 16 KiB request (the spec guarantees both fit there);
each tile then maps z/x/y onto the PMTiles Hilbert tile ID and costs at
most two more range requests — an LRU-cached leaf directory and the
tile blob. Directory gunzip runs at fetch through a conditional import
(`dart:io` zlib natively, the browser's `DecompressionStream` on web).
Tile-blob gunzip is deferred on native platforms: the provider hands
the compressed blob through (the disk cache stores that smaller form)
and `prepareTileSync` inflates it on the worker isolate — provider
loads run on the UI isolate, where a 0.5–3 ms inflate per tile would
eat into the frame budget. On web, with no worker isolate, blobs are
inflated at fetch as before. The raster store performs the same
gzip-magic sniff before image decode for the rare compressed-raster
archive.
All 64-bit offsets and tile IDs are computed with multiply/add
arithmetic (exact to 2^53) rather than bitwise ops, which dart2js
truncates to 32 bits — the same constraint the MVT decoder observes.

Local archives are the counterpart, and they are wired up in code rather
than by a URL scheme: a device-absolute path is not something a portable
style document can name. `StyleReader(resolveProvider:)` substitutes a
provider for a source id instead — consulted before any URL is read, so
it covers vector and raster sources alike, and the substituted provider
is owned by the `Style` like any other.

MBTiles specifically lives outside this package, in
`flutter_map_vector_tiles_mbtiles`. The reason is dependency shape, not
layering: MBTiles is SQLite through `dart:ffi`, which would cost the web
platform tag here — and `package:sqlite3` 3.x bundles a prebuilt SQLite
into every consumer through a build hook with no link-hook pruning, plus
requiring Flutter 3.38. Both costs are right for a package whose users
all want an archive reader, and wrong for one where most users never
open one. Three pieces of this package exist to make
that split work, and are worth treating as contract rather than
implementation detail: `VectorTileProvider.cacheBytesToDisk`,
`StyleReader.resolveProvider`, and the exported `SingleFlight`. Together
they are enough to write a fully first-class provider from outside —
which is the standard any future format adapter should be held to.

## What was deliberately changed vs. vector_map_tiles

* one package instead of three (`vector_map_tiles`, `vector_tile_renderer`,
  `executor_lib`), one rendering pipeline instead of three modes — the
  only choice left is where labels go (`LabelMode`), and both choices
  share one text engine;
* `stash` replaced by ~200 lines of deterministic cache code;
* labels moved out of tile rasters into a global screen-space pass by
  default, with the raster-mode trade (`LabelMode.tile`) as an opt-in;
* cancellation is a state, not an exception;
* tile substitution (parent/child retention) is part of the core grid
  logic instead of an afterthought;
* `Picture.toImageSync` keeps rasters on the GPU (no async readback).
