# Trim RSS · Nothing Phone (1) · 2026-10-20

Not a comparison session: re-measures what `VectorTileLayer.clearMemoryCache()`
gives back now that its trim keeps the label text of the buffer ring
around the screen, not only the labels the last placement pass looked up.
The figure it replaces came from `2026-10-12-textcache-android`, which
predates that change.

Built from 8090c1f in profile mode. Arms `fmvt` (default `TileOffset`)
and `fmvt-none`, 2 rounds, every scenario, portrait 411×914, tiles
replayed `--offline` from the same recording as the 2026-10-12 sessions
(the copy used here only adds glyphs). 0 interrupted passes.

Each run ended with an extra `trim` record from a temporary hook in
`bench_page.dart` (not committed), the same one as on 2026-10-12 except
that the trim step calls the layer's `_trimLabelCaches()`, which is what
`clearMemoryCache()` runs: RSS 3 s after the last pass (`rssBeforeMb`),
then the trim on every mounted layer and RSS 3 s later
(`rssAfterTrimMb`), then the whole `clearMemoryCache()` and RSS 3 s
later (`rssAfterClearMb`). `texts` and `textsAfter` are the text cache
entries before and after the trim. RSS on this phone excludes GPU memory.

| | default offset | `TileOffset.none` |
|---|---|---|
| RSS at the end, MB | 395, 354 | 469, 450 |
| RSS after the trim, MB | 365, 331 | 426, 414 |
| given back, MB | 30, 23 | 43, 36 |
| text entries before → after | 5585 → 712, 4833 → 673 | 8000 → 712, 8000 → 3402 |
| peak RSS, MB | 387, 391 | 506, 503 |

Rounds are listed r0, r1. On 2026-10-12 the trim gave back 25–30 MB with
the default offset and 42–48 MB with `TileOffset.none`. Same tiles, but
that build (9caac25) predates PR #9 and everything since, so the trim's
new prewarm is not the only difference between the two sessions.
