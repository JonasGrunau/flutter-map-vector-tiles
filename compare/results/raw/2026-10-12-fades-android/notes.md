# 2026-10-12-fades-android

Why does `fmvt` peak at more GPU memory than `fmvt-raster` (372 against
273 MB in `2026-10-12-android`)? Suspect: the label fades. Labels that are
fading draw inside `saveLayer`s, one per opacity step in flight, each
bounded by the union of its labels (`LabelPainter`, "Fading symbols draw
through one translucent layer per opacity bucket"). Labels fading at the
same step can be spread over the whole screen.

Same phone (Nothing Phone (1), portrait), `fmvt` arm only, 2 rounds per
variant, offline lab on :8791, GPU memory sampled every ~3 s from
`dumpsys gpu --gpumem` (`gpu-memory.txt`, the same sampler as the
session's).

- `fades-150ms/`: the default, built from 3408659.
- `fades-off/`: the same with `labelFadeDuration: Duration.zero` patched
  into `compare/lib/src/arms.dart` for the run, then reverted. Built from
  fc9dd4c, which differs from 3408659 only in the lab server's
  `Cache-Control` header, and Android's HTTP client has no HTTP cache.

| | fades 150 ms | fades off |
|---|---:|---:|
| peak GPU allocation per run, MB | 350, 385 | 311, 272 |
| median GPU sample per run, MB | 268, 266 | 254, 253 |
| frames delivered, all passes | 68.7–90.7 % | 59.4–79.5 % |
| UI thread p90, ms | 13.7–24.6 | 19.6–32.1 |
| raster thread p90, ms | 7.2–16.0 | 6.3–13.0 |
| settle, ms | 172–347 | 12–40 (one pass 411) |

With fades off the peak drops to about `fmvt-raster`'s (263–285 MB in the
session), so the extra GPU memory of the default is the fades. The
median sample moves far less than the peak: the cost is there while
labels fade, after the camera moves, not all the time.

Turning the fades off is not a cheaper default, though. The collision
pass re-runs every `placementInterval(labelFadeDuration)`, the fade
duration capped, so without fades it runs every frame. The UI thread
then pays more than the raster thread saves, and fewer frames arrive in
every scenario but the first pan. GPU memory does not depend on how often
placement runs, so the GPU column still isolates the fades.
