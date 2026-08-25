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
     │              └─ IsolatePool: decode MVT + filter per theme layer
     │                             └─ PreparedTile (compact, transferable)
     │
     ├─ TileRasterizer: PreparedTile ─► ui.Picture ─► toImageSync (GPU)
     │       one raster per *display* tile at tileSize·dpr, evaluated at
     │       the display zoom (crisp overzoom via subdivision, not scaling);
     │       features are culled — and at deep overzoom clipped — to the
     │       tile's window of the data tile
     │
     └─ symbols: SymbolLayouter collects label/icon anchors per tile
             └─ LabelPainter: per-frame screen-space pass, global collision
                grid across all tiles, upright text under rotation

Rasterization and symbol extraction are two separate jobs in a budgeted
per-frame render pump (rasters for every pending tile first, symbols
after), and a finished tile — image plus symbols — enters the shared
result cache, so re-crossing a zoom level skips the pipeline entirely.
The pump's stages emit DevTools timeline events (`VT render pump`,
`VT rasterize`, `VT symbols`, `VT labels`).
```

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

At overzoom — display zoom past the source's maxzoom — each display tile
shows only a small window of its data tile. Features are rejected
against that window (expanded by a 64-logical-px buffer) using bounds
computed once at decode time, *before* any filter or paint expression
runs; from two levels of overzoom the surviving geometry is additionally
clipped to the window, with dash and line-pattern phase measured from
the original run start so patterns stay aligned across clip boundaries
and display-tile seams. Rasterization cost per display tile is therefore
bounded by what is visible, not by the density of the data tile — the
difference between ~1 ms and ~85 ms per tile for a dense city tile
viewed at z20 over z14 data.

Labels and icons are **not** baked into the tile images. They are drawn
each frame in screen space:

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
rasterize at device scale under the transform. The shape-cache key
therefore contains no font size; `text-opacity` (1/32 steps) and
`text-halo-width` (1/128-em ratio steps) enter it quantized, so style
ramps re-shape a label a bounded number of times ever rather than per
zoom step. Never put a font size — or an unquantized opacity or halo
width — back into that key: it re-creates the full-screen re-shape per
pinch that this design removed. Collision boxes and curved-text cluster
metrics are the reference-size measurements multiplied by the scale.

Symbol layout applies the same decode-time bounds culling before
evaluating any expressions, and along-line anchors keep their full-line
spacing parametrization — an anchor lands at the same world position no
matter which display tile lays it out — while being *enumerated* only
inside the tile's window. It runs as its own budgeted job after the
tile's raster (skipped entirely when no symbol layer intersects the
tile's zoom band),
and the tile's label text is shaped into the caches before the first
frame that can draw it, never during paint.

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

Which labels fade — in *and* out — is decided per frame, per label, by
`render/label_continuity.dart`. Every label carries a position-free
continuity key, `(layer, text, icon)`: position plays no part because
two zoom levels simplify geometry differently, and a missed match would
re-fade a label that never left the screen. A `LabelFadeTracker` inside
the label painter holds one opacity per key and integrates it toward
"placed this frame ? 1 : 0", a wall-clock fraction of the fade per
frame. Anything that appears eases in and anything that disappears
eases out, whatever the cause: a tile arriving, a zoom crossing handing
over to new tiles, a collision won or lost mid-gesture, a layer cut at
its zoom threshold. There is no per-cause bookkeeping, no publish-time
diff, and no moment at which the tile grid must be complete — the
one-shot hand-over whose evaluation order used to be subtle is gone.

Two properties of the tracker carry the anti-blink guarantees. One
opacity per key: the outgoing level's copy of a label and the arriving
level's share their fade state, so whichever copy wins collision draws
at the same opacity and the swap is invisible — a label can never
cross-fade against itself. And direction changes resume rather than
restart: a key re-placed mid-fade-out rises from where it is, so a
label briefly unplaced (a republish, a lost frame of collision) dips at
most one opacity step instead of blinking to zero.

The position-free key is right for *point* anchors, whose world
position belongs to the feature. Along-line anchors are re-derived from
`symbol-spacing` per display layout, so the same street's label
genuinely sits somewhere else at the next zoom level — half the spacing
away on a plain straight road — and one shared opacity would hand the
new position the old one's full opacity: the name teleports along its
street at every crossing (and its provisional ancestor-data layout adds
a third position on the way). Along-line fades are therefore tracked
per **sitting**: within the loose key, states are matched by screen
position (`LabelFadeTracker.showAt`, the same 32 px radius the
placement memory uses, refreshed on every sighting so a sitting follows
the camera). A moved sitting cross-fades — the old position ghosts out
while the new one fades in — while simplification noise, seam twins and
provisional→final swaps land inside the radius and resume their state.
This is the fade half of MapLibre's `CrossTileSymbolIndex`, expressed
in the screen space the label pass already works in.

Every label fades on **its own clock**, from the frame it is placed. The
invariant that makes this safe is that a placed label always paints
something: a key on its first frame has no elapsed fade time, so the
painter floors it at one opacity step rather than letting it draw at
zero.

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

Fade-outs draw as **ghosts**. A key that stops being placed keeps being
drawn for the length of its fade — from whatever instance of it is
still on offer, laid out past the zoom gate that may just have cut its
layer — but claims no collision space. Whatever replaces the label
therefore places (and fades in) immediately, over the ghost, instead of
waiting for the fade to end and popping into the freed space. An
along-line sitting's ghost takes the candidate nearest the sitting
(bounded at twice the match radius, else it draws nothing) — never the
priority-first candidate, which for a street with several repeats could
be a different repeat entirely, teleporting the ghost. When a retained
tile is disposed while keys from it may still be fading, its symbols
are parked for one fade duration as ghost-only fallbacks (plain Dart
objects — no tile texture is pinned by a fade).

Retention feeds the tracker; it no longer decides fades. Retained
previous-level tiles keep offering their labels as ordinary candidates
while an overlapping current tile still lacks final label data (a tile
whose symbols are pending counts as loading, and provisional
ancestor-data cohorts do not count as coverage), and as ghost-only
fallbacks afterwards. One rule of the retention window remains, the
**pin**: the crossing that moves a level into retention cuts its
cohorts to what the last frame actually drew (`drawnLabels` against
`_drawnLastFrame` — candidates that were losing collision are dropped
for good). An outgoing level exists to keep what was visible, never to
introduce labels: a crossing typically cuts whole symbol layers at
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
passes. A pass also runs immediately whenever the candidate set itself
changes (the widget bumps a placement generation whenever symbols are
published, tiles come and go, or a retained cohort changes role) or the
viewport is resized, so labels from a tile that just landed never wait
on the clock. Because a frozen decision would otherwise outlive the
gesture that produced it, the painter reports the pass it owes and the
fade ticker keeps painting until it runs.

Three placement choices are remembered so that a pass reproduces the
last one rather than re-deriving it from scratch — each is a spot where
an arbitrary tie-break used to move a label that had no reason to move:

* **Which candidate draws a label.** A street name reaches the pass more
  than once (the two carriageways of one road; the outgoing and arriving
  copy at a zoom crossing), and which one sorts first depends on their
  screen y — so a slow pan walked the name across the street. The
  copy already drawn is tried ahead of the others *of its own label*,
  never ahead of another label, so priority between labels is untouched.
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
continuity key *and* screen position, rather than on the
`SymbolInstance`. Instances are built per display-tile layout, so a zoom
crossing, a provisional→final swap or any re-layout hands the painter a
brand-new object for a street that never left the screen; state kept on
the instance dies exactly there, and since the continuity key is
unchanged the arriving copy's cold decision lands at full opacity, with
no crossfade to cover it. Entries are matched to the nearest sighting
within 32 px and refreshed every painted frame, so a label moves only as
far as the camera does between frames, and the repeats of one name along
a single street (`symbol-spacing`, 250 px by default) keep their own.

Position belongs in *that* key and not in the continuity key, because
the two answer different questions and fail in opposite directions. A
missed match costs a *fade* the blink it exists to prevent, so the
continuity key errs loose; for a *decision* a loose key is what does the
damage — every same-named street would share one side of the road —
while a missed match merely decides cold. This is the useful core of
MapLibre's `CrossTileSymbolIndex`, which matches symbols across zoom
levels by position for much the same reason. The index proper is not
worth porting: it exists to give MapLibre's per-tile placement a
cross-tile identity, which a screen-space pass over every level's
candidates at once already has.

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

## Concurrency

MVT decoding and per-layer feature filtering run on a small isolate pool
with a priority queue (tiles closest to the camera centre first) and
*silent* cancellation — a cancelled job never surfaces an exception.
`PreparedTile` keeps geometry in `Float32List`s (tile-extent units) so
isolate transfer is cheap, and only the feature properties referenced by
the theme are retained.

Requests are coalesced per key at every level (`SingleFlight`); a
coalesced load polls a token joined over *all* its waiters, so one
cancelled waiter never aborts work others still await. Transient
failures are throttled (15 s per key) and visible tiles retry a bounded
number of times just past that throttle; a worker isolate that dies is
replaced, and if isolates cannot be spawned at all the pool falls back
to the event loop permanently.

On web (no isolate support for this workload) the pool degrades to
chunked event-loop execution.

## Caching

| layer | keyed by | bounded by |
| --- | --- | --- |
| memory: `PreparedTile` | data tile + theme id | entry count + bytes |
| memory: raster-source `ui.Image` | data tile per raster source | entry count + bytes (handed out as ref-counted clones) |
| memory: finished display tile (raster `ui.Image` + symbols) | display tile, per render signature (theme id, providers, dpr, sprite *content*, labels) | GPU texture bytes (`rasterCacheMaxBytes` — by default sized from the live viewport and dpr, see below; cache owns the master image, tiles hold clones); retained signatures bounded by their combined cost |
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
previous signature's textures. Signatures are retained past their
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
other. Those jobs are flagged so they are not written back into the
cache they came from: a second `put` under the same key would mint a
second master image and dispose the one the display tile's clone came
from.

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
disk cache is untouched.

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
all. So the render pump refuses to run below `resumed`, parking its
queue rather than dropping it, and on the return the layer discards the
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
rasterization but marks nothing, so the common case costs no re-render.

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
evaluates each once instead of per feature. Parsed CSS colours are
memoized process-wide for the same reason. Sources are resolved through TileJSON when `url` is present,
including `{key}` substitution. Whatever a source (or its TileJSON)
declares as `attribution` is collected into `Style.attributions`,
deduplicated across sources; since that value is HTML by convention it
is parsed into both flattened text and text-plus-link spans, because
Flutter has no DOM to hand it to. Relative URLs resolve against the
document that declared them — sprite and source URLs against the style
URL, tile templates against the TileJSON URL when they came from one
(ArcGIS declares `"url": "../../"` and `tile/{z}/{y}/{x}.pbf`) — and
the `{z}`/`{x}`/`{y}` braces survive resolution un-percent-encoded.

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
  `executor_lib`), one rendering mode instead of three;
* `stash` replaced by ~200 lines of deterministic cache code;
* labels moved out of tile rasters into a global screen-space pass;
* cancellation is a state, not an exception;
* tile substitution (parent/child retention) is part of the core grid
  logic instead of an afterthought;
* `Picture.toImageSync` keeps rasters on the GPU (no async readback).
