# Tile sources, offline and web

Where tiles come from, what is kept on disk, and what differs in the browser. Part of the [flutter_map_vector_tiles](../README.md) documentation.

- [Tested style providers](#tested-style-providers)
- [Custom tile sources](#custom-tile-sources)
- [Offline behaviour](#offline-behaviour)
- [Web support](#web-support)

## Tested style providers

| Provider | Style URL shape | Notes |
|---|---|---|
| 🟢 [MapTiler](https://maptiler.com) | `https://api.maptiler.com/maps/<mapId>/style.json?key={key}` | works with custom map styles |
| 🟢 [OpenFreeMap](https://openfreemap.org) | `https://tiles.openfreemap.org/styles/liberty` | free, no key needed |
| 🟢 [Stadia Maps](https://stadiamaps.com) | `https://tiles.stadiamaps.com/styles/osm_bright.json?api_key={key}` | |
| 🟢 ArcGIS / Esri | `https://…/VectorTileServer/resources/styles/root.json` | relative `../../` sources, `tile/{z}/{y}/{x}` templates and sprites all resolve. Verified against `World_Basemap_v2` |
| 🟢 Self-hosted (TileServer GL, Martin, …) | any MapLibre `style.json` | relative tile templates supported. Verified against the MapLibre demo tiles |
| 🟢 [Protomaps](https://protomaps.com) hosted API | `https://api.protomaps.com/styles/v5/light/en.json?key={key}` | verified against the v5 `light` style, which embeds the key in an absolute `…/tiles/v4/{z}/{x}/{y}.mvt?key=…` template. On web, allow-list your origin per key in the Protomaps portal; `localhost` is exempt |
| 🟢 [PMTiles](https://docs.protomaps.com/pmtiles/) archives | `pmtiles://https://…/planet.pmtiles` source URLs in any style | single-file archives over HTTP range requests, verified against the Protomaps samples. Gzip-internal only; brotli and zstd are rejected |
| 🟢 [MBTiles](https://github.com/mapbox/mbtiles-spec) archives | wired up in code via [`flutter_map_vector_tiles_mbtiles`](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles) | local SQLite archives from QGIS, tilemaker or TileServer GL. A companion package, so this one stays free of `dart:ffi`. Native only |

## Custom tile sources

No style URL? Any `{z}/{x}/{y}` MVT endpoint works. Build the theme
yourself and wire providers manually:

```dart
vt.VectorTileLayer(
  theme: vt.ThemeReader(logger: const vt.Logger.console()).read(myStyleJson),
  tileProviders: vt.TileProviders({
    'openmaptiles': vt.NetworkVectorTileProvider(
      urlTemplate: 'https://tiles.example.com/{z}/{x}/{y}.pbf?key=$key',
      maximumZoom: 14, // the source's max; higher zooms overzoom this data
    ),
  }),
)
```

Those are the two options you'll always set.
`NetworkVectorTileProvider` also takes `headers` for header-authenticated
tile servers, `minimumZoom`, `maxRetries` (default 2) and an optional
`client` if you bring your own `http.Client`, which is shared and never
closed for you.

### PMTiles

Single-file archives work out of the box: styles with
`pmtiles://https://…/planet.pmtiles` source URLs just load, or open an
archive directly:

```dart
final provider = await vt.PmTilesVectorTileProvider.open(
  'https://tiles.example.com/planet.pmtiles',
);
// → vt.TileProviders({'mySource': provider})
```

`open` likewise accepts `headers`, `maxRetries`, a shared `client`, and
`minimumZoom`/`maximumZoom` to override the archive header, the same role
a style source's `minzoom`/`maxzoom` plays.

### MBTiles

Archives live in a companion package,
[`flutter_map_vector_tiles_mbtiles`](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles),
separate because SQLite through `dart:ffi` would cost every app here a
native dependency and this package its web support:

```dart
final provider = await MbTilesVectorTileProvider.open('…/bavaria.mbtiles');
```

### Your own provider

You write against `VectorTileProvider`, which is four
members; `MemoryVectorTileProvider` covers tests and tiles you already
hold. Two hooks exist for custom providers.

`resolveProvider` substitutes yours into a style by source id, so you keep
the style's theme, sprites and attribution and replace only the tiles.
Handy when the source lives somewhere no style document can name, like a
device-absolute path:

```dart
final style = await vt.StyleReader(
  uri: 'asset://styles/liberty.json',
  resolveProvider: (id) async => id == 'openmaptiles' ? provider : null,
).read();
```

Returning null falls through to the style's own URL, it applies to raster
sources too, and the `Style` takes ownership of what you return, so
`style.dispose()` disposes it.

`cacheBytesToDisk => false` says your provider is already backed by local
storage, so the disk cache is skipped in both directions instead of
storing a second copy. Implement it on anything reading from local
storage, and use `vt.SingleFlight` to coalesce concurrent loads, as the
built-in providers do.

Raster imagery (satellite, pre-rendered hillshade) wires up the same
way: pass `rasterSources:` entries of `RasterTileSource(provider: …,
tileSize: 512)`, where the provider serves encoded PNG/JPEG/WebP bytes
instead of MVT. `NetworkVectorTileProvider` works unchanged. 256px
sources are fetched one zoom deeper for the same visual scale. An
elevation source for `hillshade` layers (a style's `raster-dem`) is the
same thing with an `encoding`:
`RasterTileSource(provider: …, tileSize: 256, encoding:
vt.DemEncoding.terrarium)` (or `.mapbox`, or a `DemEncoding(...)` with
the factors of a `custom` one).

A source's `promoteId` comes along from the style document; built by
hand, pass it as `TileProviders(providers, promoteIds: {'openmaptiles':
vt.PromoteId('osm_id')})` (or `PromoteId.bySourceLayer({...})` for one
property per source layer).

## Offline behaviour

Everything you looked at recently keeps working without network:

- **Style bundle.** `StyleReader` caches style.json, TileJSON, sprites
  and every glyph range a map has drawn with on disk,
  stale-while-revalidate: the cached copy is served instantly,
  including fully offline, and refreshed in the background once older than
  `refreshAfter` (12 h default). Opt out with `StyleReader(cache: false)`.
- **Tiles.** Served from disk while fresh. Past `diskCacheTtl` they still
  paint instantly and revalidate in the background: changed tiles
  cross-fade to the new imagery, and with no network the old tile simply
  stays. Stale tiles are deleted only by the size cap, oldest first, never
  by age alone. Elevation tiles for a hillshade are tiles like any other;
  one whose neighbour was never cached shades that edge without it, a
  faint seam, until the neighbour can be fetched.
- **Durable location.** Both caches default to the application support
  directory, which the OS doesn't purge, unlike the temp directory.

This is a *visited-places* cache, not region pre-download. For a
guaranteed offline region, ship a tile archive: point
`PmTilesVectorTileProvider` at a `.pmtiles` file, or
[`flutter_map_vector_tiles_mbtiles`](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles)
at a `.mbtiles` one, alongside an `asset://` style. Nothing on that path
touches the network, and a local archive is excluded from the disk cache,
being the local copy already.

Disk caching, and with it everything above, is native-only. See
[Web support](#web-support) for the browser.

## Web support

The layer runs on Flutter web with the CanvasKit/Skwasm renderer, the
default since Flutter 3.29. (Do not force the removed HTML renderer on
Flutter 3.27/3.28: it lacks `Picture.toImageSync`.) What differs from
native:

- **No persistent cache.** `cachePath`, `diskCacheTtl`,
  `diskCacheMaximumSizeInBytes` and `StyleReader(cache: …)` are no-ops.
  Tiles and the style bundle rely on the in-memory caches plus the
  browser's HTTP cache instead.
- **Decoding runs on the event loop.** A yielding queue replaces the
  worker-isolate pool, and `concurrency` is ignored. Layer filters are
  matched against a tile's features when it is first drawn, not while it
  is decoded, a heatmap layer's density is computed on the event loop
  too, after the frame that asked for it, and so are the meshes of a
  style's 3D buildings, when they are on, cut while a tile is decoded.
- **Label collision runs in the frame.** The placement pass that runs on
  an isolate of its own elsewhere costs the frame it is due in.
- **Fonts for other scripts are fetched.** Labels the style's glyphs
  don't draw (see [Fonts](LABELS.md#fonts)) — Chinese, Japanese,
  Korean, Arabic, Hebrew, Thai, the Indic scripts, emoji and the rest —
  are shaped by the platform, and the browser lends Flutter no system
  fonts. Flutter lays such a label out with the fonts it has, in boxes,
  and fetches Noto fonts that cover it from `fonts.gstatic.com`; the
  layer shapes the label again when they arrive, usually within a
  second or two. Where that host is blocked or the browser is offline
  the boxes stay: serve the fonts yourself and set Flutter's
  `fontFallbackBaseUrl` in the engine configuration to point at them.
- **CORS.** The browser fetches style.json, TileJSON, sprites, glyphs and
  tiles directly, so every host involved must send
  `Access-Control-Allow-Origin`. MapTiler, OpenFreeMap and Stadia do;
  self-hosted tile servers need it configured. PMTiles hosts additionally
  need range requests to pass CORS, meaning `Range` in
  `Access-Control-Allow-Headers` when preflighted.
- **PMTiles gunzip** uses the browser's native `DecompressionStream`,
  available wherever Flutter web runs.
- **No MBTiles.** The companion package reads SQLite through `dart:ffi`,
  which has no web implementation. PMTiles fills the same role over HTTP
  range requests.
- **Hillshade** draws on CanvasKit and Skwasm alike; the web engine
  snapshots each tile's shading once more before the tile does, so a
  hillshaded tile costs a little more to render there than on native.

