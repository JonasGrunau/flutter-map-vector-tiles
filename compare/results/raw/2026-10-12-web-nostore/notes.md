# 2026-10-12-web-nostore

All six arms in Chrome, 3 rounds, on 3408659, 05:32–06:28. No pass was
interrupted. On battery (51 % → 34 %), other apps open.

The lab server still answered every request with `Cache-Control:
no-store`, which turned off the browser's HTTP cache. OpenFreeMap lets
browsers cache its tiles for ten years, and on the web this package has
no disk cache: a tile that has left its 32 MB decoded-tile memory cache
comes back through the HTTP cache. Here it came back from the network.
The zoom path stays over the opening view, and in the macOS session its
two passes requested 12 and 0 tiles with the default offset, 0 and 0
with `TileOffset.none`. Here they requested 28 and 18, and 38 and 38
(`fmvt`, `fmvt-none`; the `LabelMode.tile` arms the same). The other
paths requested what they request on macOS, within a few tiles.
`vector_map_tiles` keeps tile bytes in memory and requested nothing on
either zoom pass.

So this is what this package does on the web behind a tile server that
forbids caching. Superseded by a session with OpenFreeMap's caching.
