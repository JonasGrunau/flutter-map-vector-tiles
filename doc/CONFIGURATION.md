# Configuration

Every option of `VectorTileLayer` and `StyleReader`, what the caches hold, and how the layer spends a frame. Part of the [flutter_map_vector_tiles](../README.md) documentation.

- [Layer options](#layer-options)
- [Understanding `TileOffset`](#understanding-tileoffset)
- [Frame budget and profiling](#frame-budget-and-profiling)
- [Memory compared with `vector_map_tiles`](#memory-compared-with-vector_map_tiles)

## Layer options

Everything has sensible defaults; override what you need:

```dart
vt.VectorTileLayer(
  theme: style.theme,
  tileProviders: style.providers,
  rasterSources: style.rasterSources,          // imagery and hillshade elevations
  sprites: style.sprites,
  glyphs: style.glyphs,                        // the style's fonts
  tileOffset: vt.TileOffset.maplibre,          // 512px style convention (default)
  concurrency: 3,                              // decoding isolates
  diskCacheMaximumSizeInBytes: 50 * 1024 * 1024,
  diskCacheTtl: const Duration(days: 14),
  memoryCacheMaxBytes: 24 * 1024 * 1024,
  // sized for the device by default; a byte count overrides it
  rasterCacheMaxBytes: vt.VectorTileLayer.autoRasterCacheBytes,
  tileFadeDuration: const Duration(milliseconds: 150),
  labelFadeDuration: const Duration(milliseconds: 150),
  showLabels: true,
  labelMode: vt.LabelMode.screen,              // or .tile: labels baked into tiles
  extrusionMode: vt.ExtrusionMode.flat,        // or .perspective: 3D buildings
  controller: myController,                    // queries + feature state, optional
  retainAllProperties: false,                  // keep properties the style never reads
  logger: const vt.Logger.console(),           // see style warnings in debug
)
```

| Parameter | Default | What it does |
|---|---|---|
| `glyphs` | none | the style's `glyphs` (`style.glyphs`): labels drawn in the style's own fonts, laid out without the platform's text shaper. Without them every label uses the system font. See [Fonts](LABELS.md#fonts) |
| `tileOffset` | `TileOffset.maplibre` | zoom relation between map and style, see below 👇 |
| `concurrency` | `3` | worker isolates decoding tiles off the UI thread (ignored on web) |
| `diskCacheMaximumSizeInBytes` | 50 MB | `0` disables disk caching (no effect on web) |
| `diskCacheTtl` | 14 days | freshness window: younger tiles skip the network, older ones still paint instantly and refresh in the background. ⚠️ Respect your provider's terms |
| `cachePath` | app support dir | your own directory, to control or clear it (ignored on web) |
| `memoryCacheMaxBytes` | 24 MB | decoded tile budget per source. The caches are shared process-wide, so the most recently mounted layer's value wins |
| `rasterCacheMaxBytes` | sized for the device | finished-tile budget: zooming back to a recent level, or reopening the same style, paints instantly instead of re-rendering. These are GPU texture bytes (plus, with 3D buildings, the buildings each tile holds), roughly 1 MB per tile at devicePixelRatio 2 and 2.25 MB at 3, and a phone screenful is 25 to 35 tiles, so a *single* level costs about 80 MB on a large dpr-3 phone. The default measures your viewport and dpr and budgets 2.5 screenfuls, clamped to 64 to 256 MB, so a zoom round trip keeps the level it returns to. Pass a byte count to pin it, or `0` to disable |
| `tileFadeDuration` | 150 ms | fade-in of newly rendered tiles. Tiles from the finished-tile cache fade only when retained imagery lies beneath to cross-fade over; with nothing beneath, as on a reopened map or in the ring a zoom-out exposes, ready imagery appears at once rather than fading over the background. `Duration.zero` disables |
| `labelFadeDuration` | 150 ms | fade of appearing *and* departing labels and icons, one fade state per label identity, so a label carried across a zoom level never re-fades or blinks. Also how often collision is re-decided, capped at 300 ms: camera and candidate changes wait at most one interval, while an unchanged map schedules no further placement work. `Duration.zero` restores instant pops and per-frame collision, and immediately finishes a fade already in progress; on a Nothing Phone (1) that took the peak GPU memory from 391–409 to 317–320 MB and cost frames ([compare/RESULTS.md](../compare/RESULTS.md)). No effect with `LabelMode.tile`, where labels fade in with their tile |
| `showLabels` | `true` | disables the whole symbol pass when `false`; toggling it re-lays-out the tiles already on screen |
| `labelMode` | `LabelMode.screen` | where labels and icons are drawn: every frame in screen space, or once into each tile's image (`LabelMode.tile`, what `vector_map_tiles` calls raster mode). Changing it re-renders the tiles already on screen. See [Choosing a label mode](LABELS.md#choosing-a-label-mode) |
| `extrusionMode` | `ExtrusionMode.flat` | how `fill-extrusion` layers are drawn: flat in the tile images, as every release before 3D buildings drew them, or opted into with `ExtrusionMode.perspective`, as 3D buildings leaning away from the screen centre, the way MapLibre draws them looking straight down (UI-thread time every frame the map moves). Always flat with `LabelMode.tile`. See [3D buildings](STYLE_SUPPORT.md#3d-buildings) |
| `controller` | none | a `VectorTileLayerController` to ask what is drawn where and to set feature state. See [Querying features and feature state](QUERYING.md) |
| `retainAllProperties` | `false` | decode every feature property, not only those the style reads, so query results carry them all. Costs memory and decode time, see below |

The memory caches are shared process-wide and outlive the layer, which is
why reopening a map paints instantly. If those budgets are too generous
under memory pressure, the static `VectorTileLayer.clearMemoryCache()`
releases decoded tiles, raster-source images and finished tiles alike,
leaving the disk cache untouched. It also trims the label text each open
map keeps, which is held per map rather than shared, down to the labels
of the tiles it is showing. Call it from a handler such as
`WidgetsBindingObserver.didHaveMemoryPressure`: visible maps keep their
imagery and their labels, only tiles panned to afterwards are re-read
from disk, and only labels met again are shaped again.

The layer manages those caches itself in one case. Coming back from the
background it discards the finished tiles and re-renders, because iOS
revokes GPU access for a backgrounded process and a tile rasterized just
as that happens comes back solid magenta, indistinguishable from a real
image. So it stops rasterizing on the way out and treats what it has as
suspect on the way back in. Recovery costs no network and no decoding,
since the decoded geometry never left memory, and on-screen imagery is
replaced only once the new render is ready. A window that is merely
unfocused (a desktop window behind another app, a browser window that
lost focus, the other half of an Android split screen) keeps rendering.

`StyleReader` also takes:

- `apiKey`, substituted for `{key}` in the style URI and every URL the
  style references. For `mapbox://` URIs (style ids, sprite bases and
  tileset sources, expanded to `api.mapbox.com` automatically) it is the
  access token.
- `headers`, added to the style, TileJSON, sprite and glyph requests and
  forwarded to the created tile providers, for header-authenticated
  services such as `Authorization`.
- `httpClient`, your own `http.Client` for proxying, certificate pinning
  or tests. A passed client stays yours and is never closed for you.
- `language`, to show labels in that language (`'de'`, `'fr'`,
  `'zh-Hans'`) wherever the tiles carry a translation, and in the
  style's own text everywhere else. See [Label language](LABELS.md#label-language).

## Understanding `TileOffset`

MapLibre renders 512px tiles, so at the same visual scale a MapLibre zoom
is **one lower** than flutter_map's. Styles from MapTiler and friends are
authored against that convention.

- `TileOffset.maplibre` *(default)* matches the author's intent exactly,
  for text sizes, road widths and layer zoom ranges.
- `TileOffset.none` evaluates the style at flutter_map's zoom directly, so
  everything appears one zoom earlier and larger. The legacy
  `vector_map_tiles` default, if you need parity with it.

## Frame budget and profiling

New tiles are rendered by a render pump that runs on a time budget per
frame: 4 ms while the camera moves, from the first frame of a drag or
zoom, and 12 ms once it has stood still for 150 ms. It records a tile
one style layer at a time and shapes its labels one at a time,
checking the budget in between, so a dense tile is spread over several
frames. What it never splits can still take a frame of its own: one
very dense layer (22 ms for the densest buildings layer measured on a
phone), and with `LabelMode.tile` one tile's label placement, drawing
and snapshot, which wait for the next frame rather than run in one
whose budget is already spent. The still budget takes most of a 60 Hz
frame and more than a 120 Hz one, so an animation of your own running
over a still map that is still loading tiles can drop frames until
they are in.

For profiling, the render pipeline emits DevTools timeline events:
`VT render pump`, `VT rasterize`, `VT symbols`, `VT labels`, `VT
extrusion` (a frame's 3D buildings), `VT heatmap` (a heatmap pass's
UI-thread part), and with `LabelMode.tile`
`VT rasterize with labels` and `VT tile labels`. A
dense tile's `VT rasterize` and `VT symbols` repeat over several
frames, one slice per frame.
## Memory compared with `vector_map_tiles`

- **Memory.** With baked labels this package uses a little less on the
  Android phone: 264 against 313 MB of GPU memory at the peak, 391
  against 401 MB RSS (336 against 387 MB on the iPhone, 495 against
  577 MB on macOS). This package's default, which draws labels every
  frame, needs more GPU memory than baked labels (365 MB, vector mode
  376 MB), much of it for the label fades: in a separate A/B, turning
  them off took its peak from 391–409 to 317–320 MB, and cost frames
  instead. It needs far less RSS than vector mode (393 against 892 MB;
  335 against 836 MB on the iPhone, 527 against 948 MB on macOS). Its
  label text cache keeps up to 8000 shaped labels; after a run through
  four dense cities that held 37–49 MB more than the 2500 it used to
  keep, and 117–119 MB more with `TileOffset.none`.
  `VectorTileLayer.clearMemoryCache()` gives 23–43 MB of that back (see
  the CHANGELOG).
