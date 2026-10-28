# Feature queries and state · iPhone 15 Pro Max · 2026-10-28

Main `f794e0b` against the `feature-query-state` branch at `b04abb5`
with no controller attached, plus the branch's query bench. iPhone 15 Pro
Max, iOS 27.0.1, 120 Hz, Impeller on Metal, profile builds, tiles from
`tool/lab_server.dart` over the iPhone's USB link (`--bind`), replayed
from the same recorded caches as the Android sessions. One iPhone-lock
block, 05:06 to 05:26.

A screenshot before the block showed the home screen, and one 45 s after
each bench launch showed the bench drawing Munich, so no system prompt
covered any run. A first attempt the evening before (22:31) found another
app's Local Network prompt on screen; it measured nothing and its data
was discarded.

## Compare sessions: `<n>-<M|B>.jsonl`

`tool/run_ios.sh <udid> 1 --arms=fmvt,fmvt-raster --scenarios=zoom,pan`,
in the order main, branch, branch, main. Rotate and fling were left out to
keep the block inside 30 minutes; zoom was the scenario that moved on
Android. No pass was interrupted, and none had a stall.

## `query-bench.txt`

`bench/` in `BENCH_MODE=query` at Munich z16, Liberty, `retainAllProperties`
off, two runs: 240 point and 240 48 px rect queries, then 20 buildings and
20 roads selected and cleared one at a time, then nine z14 tiles decoded
both ways, and RSS. The iPhone's screen holds a different grid of query
points than the Android phone's, so hits per query differ (35.9 against
39.6 for the rect).
