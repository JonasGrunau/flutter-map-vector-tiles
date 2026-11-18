# Troubleshooting

Symptoms, their usual cause and the fix. Part of the [flutter_map_vector_tiles](../README.md) documentation.

- [Blank map, no errors](#blank-map-no-errors)
- [`read()` or `open()` throws](#read-or-open-throws)
- [Anything MBTiles-related](#anything-mbtiles-related)
- [Some labels ignore `language`](#some-labels-ignore-language)
- [Labels/roads look bigger than in MapLibre](#labelsroads-look-bigger-than-in-maplibre)
- [A layer or property shows its default where it used to draw](#a-layer-or-property-shows-its-default-where-it-used-to-draw)
- [Stale data after changing styles](#stale-data-after-changing-styles)
- [A `hillshade` layer draws nothing](#a-hillshade-layer-draws-nothing)
- [Blank map on web](#blank-map-on-web)
- [Solid magenta tiles after reopening the app on iOS](#solid-magenta-tiles-after-reopening-the-app-on-ios)

## Blank map, no errors

Pass `logger: const vt.Logger.console()` to
both `StyleReader` and `VectorTileLayer`. Usually the style's source ids
don't match your `TileProviders` keys, or the API key is invalid; HTTP
403s are logged. Every message reaches the logger with API keys
redacted (`key`, `apikey`, `api_key`, `access_token` and `token` query
values read `***`), so warnings can be forwarded to a crash reporter
as they are.

## `read()` or `open()` throws

The designed failure path for a broken
setup. `StyleReader.read()` throws `StyleReaderException` when the style
can't be loaded or parsed, and `PmTilesVectorTileProvider.open` throws
`PmTilesException` on an invalid or unsupported archive, or
`http.ClientException` on network failure. Catch these to show a retry
UI. Runtime tile fetches never throw into your code; failures are logged
and retried.

## Anything MBTiles-related

See the companion package's own
[troubleshooting section](https://pub.dev/packages/flutter_map_vector_tiles_mbtiles).

## Some labels ignore `language`

Those features have no
`name:<language>` or `name_<language>` in the tiles, so they keep the
style's text. That is the tile data, mostly streets and small places;
check a feature's tags on openstreetmap.org.

## Labels/roads look bigger than in MapLibre

Probably `TileOffset.none`
with a 512px-convention style; use the default.

## A layer or property shows its default where it used to draw

The
style relies on a value of the wrong type, such as a number stored as
a string in the tiles, which versions up to 2.10 converted and
MapLibre never did. Convert it in the style (`to-number`,
`to-string`, `to-boolean`), and the style draws the same in MapLibre
too.

## Stale data after changing styles

The disk cache keys by URL, and a
changed `{key}` or map id is a different URL, so usually there is
nothing to do. Supply `cachePath` to wipe it yourself.

## A `hillshade` layer draws nothing

Its `raster-dem` source has to
reach the layer: pass `style.rasterSources` as `rasterSources`. The
shading is a fragment shader bundled with this package; a platform
where it cannot load logs a warning once and leaves the layer out.

## Blank map on web

Open the browser console: missing
`Access-Control-Allow-Origin` headers on the style or tile host block
every request (see [Web support](TILE_SOURCES.md#web-support)).

## Solid magenta tiles after reopening the app on iOS

Tiles rasterized
while iOS had revoked the process's GPU access. The layer handles this
itself; on 2.6.1 and earlier the corrupted tiles are cached for the life
of the process, and calling `VectorTileLayer.clearMemoryCache()` on
`AppLifecycleState.resumed` is the workaround. The underlying engine gap
is [flutter#191255](https://github.com/flutter/flutter/issues/191255).
Magenta from *decoded* images, meaning sprites and raster sources, is
the same iOS bug one layer down and outside this package's reach
([flutter#166668](https://github.com/flutter/flutter/issues/166668),
fixed in 3.32), so keep your Flutter up to date. Glyph ranges are
decoded images too; one hit by it shows its labels as solid blocks in
the text colour.

