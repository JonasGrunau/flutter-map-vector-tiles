# Text-cache A/B · Nothing Phone (1) · 2026-10-12

Not a comparison session: one build of the compare app, run twice with
only `LabelPainter.textCacheEntries` changed (2500, then 8000), to price
the larger label text cache and what `VectorTileLayer.clearMemoryCache()`
gives back. Arms `fmvt` (default `TileOffset`) and `fmvt-none`, 2 rounds,
every scenario, tiles replayed `--offline`. The records say commit
9caac25; the package also carried the uncommitted `trimCaches()` change
that shipped in the next commit.

Each fmvt run ended with an extra `trim` record from a temporary hook in
`bench_page.dart` (not committed): RSS 3 s after the last pass
(`rssBeforeMb`), then `trimCaches()` on every mounted layer and RSS 3 s
later (`rssAfterTrimMb`), then the whole `clearMemoryCache()` and RSS
3 s later (`rssAfterClearMb`). `texts` and `textsAfter` are the text cache
entries before and after the trim. RSS on this phone excludes GPU memory.

| | default offset, 2500 → 8000 | `TileOffset.none`, 2500 → 8000 |
|---|---|---|
| peak RSS, MB | 381, 362 → 410, 384 | 384, 384 → 491, 495 |
| RSS at the end, MB | 339, 315 → 388, 352 | 348, 325 → 467, 442 |
| text entries at the end | 2500, 2500 → 5241, 4490 | 2500, 2500 → 8000, 8000 |
| RSS after the trim, MB | 325, 302 → 358, 327 | 334, 317 → 419, 400 |
| zoom warm settle, ms | 901, 680 → 161, 197 | 343, 343 → 231, 490 |
| fling settle cold/warm, ms | 210/269, 191/244 → 343/282, 173/341 | 1623/1800, 1790/1726 → 326/376, 378/374 |

Rounds are listed r0, r1. The trim left 360–1187 entries, the labels of
the last screen. `clearMemoryCache()` after it changed RSS by nothing
further: the finished tiles it also drops are GPU memory.
