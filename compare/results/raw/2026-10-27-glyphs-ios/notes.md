# Glyph-drawn labels · iPhone 15 Pro Max · 2026-10-27

The iPhone check of drawing labels from the style's glyph PBFs
(`VectorTileLayer.glyphs`), `main` (f794e0b) against the branch
(67c03b9), back to back on the same phone: iOS 27.0.1, 120 Hz, Impeller
on Metal, profile builds. One block of 15 min, alternating: probe main,
probe branch, compare main, compare branch, then the same again.

`tile-probe.txt` is the plan's tile-cost probe (label shaping and first
paints of one dense Munich z14 tile and one z16 tile, Liberty, dpr 3),
two rounds per side. Each round prints two passes.

| | main | branch |
|---|---|---|
| shaping a z14 tile's labels (222 candidates, 134 shaped) | 3.9–4.1 ms | 0.2–0.4 ms |
| shaping a z16 tile's labels (108 / 58) | 1.3–2.0 ms | 0.1 ms |
| first shaping call in the process | 53.2–59.5 ms | 0.2 ms |
| first label paint, z14 | 0.2 ms | 0.4–0.6 ms |
| later label paints, z14 | 0.2 ms | 0.2–0.3 ms |

`{main,branch}-{1,2}.jsonl` are compare/ sessions of arm `fmvt` (the
default mode), every scenario, 1 round each, portrait 430×932. The lab
served tiles and glyph ranges from the Android recording, fetching the
few tiles the larger viewport adds once (in `main-1`, the first
session). 0 interrupted passes.

| `fmvt` | main | branch |
|---|---|---|
| first complete map, ms | 457, 491 | 491, 480 |
| peak RSS over a run, MB | 342, 279 | 289, 274 |
| requests / MB per run | 68 / 26.66 | 76 / 27.27 |
| frames delivered, every scenario cold and warm | 99.0–100 % | 99.1–100 % |
| frames delivered, rotate cold / warm | 99.0, 99.3 / 99.9, 99.9 | 99.1, 99.3 / 99.9, 99.9 |
| 50 ms stalls, any pass | 0 | 0 |
| raster p50, ms | 0.50–0.61 | 0.34–0.45 |
| UI build p50, ms | 1.5–2.4 | 1.6–2.5 |

The shaping saving holds on the iPhone, but at 4 ms a dense tile it was
never what limited the first map here: first complete map and frames
delivered don't move. The default mode's rotate loss on the Android
phone does not show. Raster p50 is 0.1–0.2 ms lower in every scenario;
UI build p50 is 0.05–0.25 ms higher (fling and zoom the most).

`results/shots/2026-10-27-glyphs-ios/` puts `main` and the branch side by
side at two of the fidelity cameras (`main` draws in the iOS system
font, the branch in the style's Noto Sans from its glyph PBFs on Metal),
and a 1:1 detail of the 45° camera.

## Script showcase (2026-10-28)

`showcase.webp`, `showcase-22.webp` and `showcase-22-detail.webp` are the
script showcase on the iPhone, `main` against the branch: release builds
(a profile build new to the iPhone raises the Local Network prompt), no
network, the branch's Noto Sans ranges bundled as assets. Every app was
launched twice; both launches gave identical shots. Page 1 is the
24-script page of the Android shots. Page 2 holds #22's cases, taken
from its script suite: Arabic and Hebrew with a Latin word (`شارع King
Fahd`, `Rue 5 ‎תל‎`, `כביש 90`), Arabic, Hebrew, Persian and Urdu that
wrap at `text-max-width`, Chinese and Japanese that wrap there, the long
Bengali name whose word #22 stopped splitting, Devanagari, Sinhala (with
its ZWJ), Tibetan and Thai stacking, vowelled Arabic, a ZWJ family, a
flag and a skin tone, and Chinese and Arabic along curved roads.

- Page 1: on the branch Latin, Greek, Cyrillic, Armenian and Georgian
  come from the glyphs in Noto Sans (`main`: the iOS system font); the
  column of complex scripts is pixel-identical on both sides.
- `شارع King Fahd`: `main` draws the Arabic word on the left, the branch
  (#22) on the right, reading right to left. The line is not taller on
  iOS: 42 device px of ink (43 with its halo) from the same top on both
  sides; the branch's sits 4 px further right.
- `北京市朝阳区建国门外大街`: one line on `main`, two on the branch
  (`北京市朝阳区建` / `国门外大街`).
- Everything else on page 2 is pixel-identical between `main` and the
  branch, apart from sub-pixel placement of the curved Arabic name. No
  `.notdef` boxes; Arabic, Persian and Urdu join, marks and stacks sit
  where they belong, the emoji draw as one glyph each. The Bengali name
  wraps into three lines at word boundaries on both sides; `main`'s
  split needs a narrower width than this page has.
