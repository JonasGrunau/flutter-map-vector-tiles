# Glyph-drawn labels · Nothing Phone (1) · 2026-10-26/27

Not a comparison with `vector_map_tiles`: the verification of drawing
labels from the style's glyph PBFs (`VectorTileLayer.glyphs`), `main`
against the branch, back to back on the same phone.

Arms `fmvt` and `fmvt-raster`, every scenario, 2 rounds per session,
portrait 411×914, tiles and glyph ranges replayed `--offline` from one
recording (the 2026-10-12 cache plus OpenFreeMap's Noto Sans Regular,
Bold and Italic ranges 0–255, 256–511, 768–1023, 1024–1279, 7680–7935
and 8192–8447). The branch's `fmvt` arms pass `glyphs: style.glyphs`.
`gpu-memory-*.txt` are `tool/gpu_sampler.sh` samples; `tile-probe.txt`
is the plan's tile-cost probe (label shaping and first paints of one
dense Munich z14 tile, 2 alternating rounds).

Eight sessions in four alternating blocks, `main` first in each, 0
interrupted passes:

- **C and D** (2026-10-27), the numbers below: `main` (f794e0b) against
  b25d39c, which is d978e3d plus result files. d978e3d fixed labels
  that waited on two or more glyph ranges at once: the render pump threw
  and that tile's labels never appeared.
- **A and B** (2026-10-26): `main` (f794e0b) against dd3bbc5, the glyph
  work before that fix (and before it was restacked on the script
  suite). Kept for reference; the bug may have left labels out of those
  branch runs.

Medians over the 4 runs per side of C and D, ranges in brackets.

| `fmvt` | main | branch |
|---|---|---|
| first complete map, ms | 1026 (957–1029) | 848 (816–869) |
| peak RSS over a run (harness), MB | 399–407 | 317–337 |
| peak PSS over a run (sampler), MB | 349–435 | 294–335 |
| peak GPU allocation, MB | 388 (361–406) | 395 (381–400) |
| requests / MB per run | 68 / 26.66 | 76 / 27.23 |
| frames delivered, pan cold | 77.8 (70.8–82.1) | 77.8 (73.5–79.1) |
| frames delivered, zoom cold | 86.7 (86.1–88.9) | 85.5 (83.9–88.4) |
| frames delivered, rotate cold | 78.3 (76.0–79.6) | 73.7 (72.0–76.8) |
| frames delivered, rotate warm | 81.6 (76.6–86.0) | 77.8 (72.7–79.1) |
| frames delivered, fling cold | 83.4 (82.0–87.1) | 81.5 (80.8–82.2) |
| frames delivered, zoom warm | 86.3 (84.9–87.0) | 89.6 (87.9–90.5) |
| 50 ms stalls per pass, rotate cold / warm | 16 / 14.5 | 24 / 21 |
| raster p50, pan / zoom / rotate / fling cold, ms | 5.5 / 7.3 / 7.8 / 9.4 | 4.4 / 5.3 / 6.3 / 7.1 |

| `fmvt-raster` | main | branch |
|---|---|---|
| first complete map, ms | 906 (860–923) | 714 (627–771) |
| peak RSS over a run (harness), MB | 382–405 | 310–334 |
| peak PSS over a run (sampler), MB | 340–369 | 282–304 |
| peak GPU allocation, MB | 278 (265–288) | 278 (265–292) |
| build p50, pan / zoom cold, ms | 6.4 / 5.4 | 3.6 / 3.7 |

Warm passes and the rest of the columns are in the `.jsonl` files.
Frames delivered in `fmvt-raster` stay within run-to-run range in every
scenario (the branch is ahead in fling warm, 98.2 against 94.3).

Rotate in `fmvt` is the one scenario where the branch delivers fewer
frames: behind in three of the four blocks (B, C, D; level in A), with
more 50 ms stalls, while its median UI and raster frame times are lower.
The cause is not established. A and B otherwise agree with C and D:
there the first complete map was 115 ms (`fmvt`) and 184 ms
(`fmvt-raster`) sooner, peak RSS 75–90 MB lower, and the peak GPU
allocation 26 MB higher in `fmvt` (median of the run peaks; 7 MB in C
and D).

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
