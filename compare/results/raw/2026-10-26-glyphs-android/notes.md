# Glyph-drawn labels · Nothing Phone (1) · 2026-10-26

Not a comparison with `vector_map_tiles`: the verification of drawing
labels from the style's glyph PBFs (`VectorTileLayer.glyphs`), `main`
against the branch, back to back on the same phone.

Arms `fmvt` and `fmvt-raster`, every scenario, 2 rounds per session,
portrait 411×914, tiles and glyph ranges replayed `--offline` from one
recording (the 2026-10-12 cache plus OpenFreeMap's Noto Sans Regular,
Bold and Italic ranges 0–255, 256–511, 768–1023, 1024–1279, 7680–7935
and 8192–8447). Four sessions, alternating: `main-A` (f794e0b),
`branch-A`, `main-B`, `branch-B` (both dd3bbc5, the glyph work on top of
f794e0b, before it was restacked on the script suite — no change to the
measured code). The branch's `fmvt` arms pass `glyphs: style.glyphs`.
0 interrupted passes. `gpu-memory-*.txt` are `tool/gpu_sampler.sh`
samples; `tile-probe.txt` is the plan's tile-cost probe (label shaping
and first paints of one dense Munich z14 tile, 2 alternating rounds).

Medians over the 4 runs per side, ranges in brackets.

| `fmvt` | main | branch |
|---|---|---|
| first complete map, ms | 939 (927–1146) | 824 (810–850) |
| peak RSS over a run (harness), MB | 394–409 | 318–322 |
| peak PSS over a run (sampler), MB | 368–398 | 281–303 |
| peak GPU allocation, MB | 337–382 | 363–417 |
| requests / MB per run | 68 / 26.66 | 76 / 27.23 |
| frames delivered, pan cold | 78.0 (75.1–80.1) | 81.7 (79.0–88.2) |
| frames delivered, zoom cold | 89.3 (87.4–90.5) | 89.5 (88.8–91.8) |
| frames delivered, rotate cold | 79.4 (78.0–81.1) | 78.9 (76.8–82.6) |
| frames delivered, fling cold | 85.1 (82.0–86.4) | 83.0 (82.5–84.5) |
| raster p50, pan cold, ms | 5.3 | 4.3 |
| raster p50, rotate cold, ms | 8.6 | 6.7 |
| raster p50, fling cold, ms | 10.0 | 7.8 |

| `fmvt-raster` | main | branch |
|---|---|---|
| first complete map, ms | 934 (881–949) | 750 (718–754) |
| peak RSS over a run (harness), MB | 376–393 | 309–349 |
| peak PSS over a run (sampler), MB | 348–379 | 276–294 |
| peak GPU allocation, MB | 270–304 | 266–296 |

Warm passes and the rest of the columns are in the `.jsonl` files; no
scenario moved outside its run-to-run range except the first complete
map, memory and raster-thread figures above.

`results/shots/2026-10-26-glyphs-android/` puts `main`, the branch and
MapLibre GL JS 4.7.1 side by side at three of the fidelity cameras (the
MapLibre column rendered at the phone's 411×914 viewport and pixel ratio
through the lab server).

`showcase.webp` and `showcase-detail.webp` (2026-10-27) are a page of
names in 24 scripts, one label each, drawn by a profile build on the
phone: `main` (f794e0b), the branch (d978e3d) with OpenFreeMap's Noto
Sans glyph ranges served by the lab server over `adb reverse`, and
MapLibre GL JS 4.7.1 with the same glyphs and no RTL plugin. Latin,
Greek, Cyrillic, Armenian and Georgian come from the glyphs and wrap as
MapLibre wraps them; every other script is drawn by the platform, as on
`main`. The same branch build with no network drew every label in the
system font once its glyph requests failed.
