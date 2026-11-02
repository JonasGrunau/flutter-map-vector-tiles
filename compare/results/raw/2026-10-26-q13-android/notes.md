# Feature queries and state · Nothing Phone (1) · 2026-10-26/27

Main `f794e0b` against the `feature-query-state` branch with no controller
attached, plus the branch's own query bench. Profile builds, portrait
411×914 at dpr 2.625, Android 15, Impeller falling back to GLES, Wi-Fi off:
every tile came over USB from `tool/lab_server.dart` on port 8790,
replayed from one recorded `.lab-cache`.

## Compare sessions: `main-N.jsonl`, `branch-N.jsonl`

`tool/run_android.sh <serial> 1 --arms=fmvt,fmvt-raster`, one round of
every scenario per arm, one fresh process per arm.

| pair | started | order | branch commit |
|---|---|---|---|
| 1 | 2026-10-26 23:21 | main, branch | `70d0318` |
| 2 | 2026-10-26 23:35 | main, branch | `70d0318` |
| 3 | 2026-10-27 08:52 | branch, main | `0abf086` |
| 4 | 2026-10-27 09:06 | main, branch | `0abf086` |

Pairs 3 and 4 ran in one phone-lock block right after the query bench.
`gpu-memory-*.txt` are the `dumpsys gpu --gpumem` samples taken during
each session.

Two passes fell below main's whole spread: fmvt zoom cold on `0abf086`
(78.9 and 81.8 %, 26 and 20 stalls, against 83.3–92.3 % over 29 main runs
on this phone that day, 25 of them from other sessions' compare runs) and
fmvt-raster zoom warm on both branch commits (94.4–94.8 % against
95.0–96.6 % over 16). The only hot-path change between `70d0318` and
`0abf086` was `featureContext`, the builder that replaced
`EvalContext(...)` at the rasterizer and label-pass sites.

## Zoom sessions: `zoom-<n>-<build>.jsonl`

`tool/run_android.sh <serial> 2 --arms=fmvt,fmvt-raster --scenarios=zoom`,
2026-10-27 12:28–12:58, in the order N V M M V N:

- `M`: main `f794e0b`
- `N`: `0abf086` with `featureContext` marked `@pragma('vm:prefer-inline')`
  (`variant-n.diff`); this is what the branch ships, as `c6af7fd`
- `V`: `0abf086` with no `EvalContext` subclass, the state carried in
  `vars` under a reserved key (`variant-v.diff`)

| frames delivered, % | M | N | V |
|---|---|---|---|
| fmvt zoom cold | 88.8 (85.3–89.5) | 88.1 (87.4–90.3) | 87.2 (85.6–88.5) |
| fmvt zoom warm | 85.7 (85.0–86.7) | 88.7 (84.3–88.7) | 86.2 (85.2–86.5) |
| fmvt-raster zoom cold | 93.9 (92.8–94.3) | 93.7 (93.2–95.1) | 93.7 (93.2–94.2) |
| fmvt-raster zoom warm | 95.6 (94.8–96.2) | 95.4 (95.1–95.7) | 95.1 (94.8–95.4) |

Medians of 4 runs, ranges in brackets. N matches main in every cell.

## `query-bench.txt`

`bench/` in `BENCH_MODE=query` at Munich z16, Liberty, through the same
lab: 240 point and 240 48 px rect queries over a grid, then 20 buildings
and 20 roads selected and cleared one at a time through feature state,
then nine z14 tiles decoded with the style's keep-lists and with every
property, and RSS. Four runs per build (`q-<retainAllProperties>-<n>`),
before the edge cull (`70d0318`) and after it (`0abf086`). A state
change's `ms` runs from `setFeatureState` until the last re-rendered tile
lands. A clear reports 0 because nothing is rasterized: the stateless
images come back from the finished-tile cache. The decode comparison
always ran keep-lists first, so the faster "all" times there are an
order effect, not a gain.

`../../shots/2026-10-26-q13-android/selected-building.webp` is the bench's
screenshot after selecting one building.
