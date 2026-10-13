# 2026-10-12-c1dc45c-fades-android

The label-fades A/B of `2026-10-12-fades-android`, repeated on c1dc45c,
which adds PR #9 (layer filters once per data tile, cheaper frames
between placement passes). Its GPU memory was expected to hold, its
frames not: with fades off every frame is a placement pass, and PR #9
made only the frames between passes cheaper.

Same phone (Nothing Phone (1), portrait, on USB power), `fmvt` arm only,
2 rounds per variant, tiles replayed `--offline` from the recording the
six-arm sessions use, GPU memory sampled every ~3 s from
`dumpsys gpu --gpumem` (`gpu-memory.txt`). Run right after
`2026-10-12-c1dc45c-android`, by the same script.

- `fades-150ms/`: the default, c1dc45c as committed.
- `fades-off/`: the same with `labelFadeDuration: Duration.zero` patched
  into `compare/lib/src/arms.dart` for the run, then reverted (checked:
  no changed files afterwards).

| | fades 150 ms | fades off |
|---|---:|---:|
| peak GPU allocation per run, MB | 391, 409 | 320, 317 |
| median GPU sample per run, MB | 270, 261 | 256, 255 |
| frames delivered, all passes | 75.8–88.1 % | 56.5–85.2 % |
| UI thread p90, ms | 14.4–22.0 | 17.8–32.9 |
| raster thread p90, ms | 7.4–17.5 | 5.9–13.0 |
| settle, ms | 174–354 | 15–67 |

The conclusion of the first A/B holds. Fades off lowers the GPU peak by
70–90 MB, though not all the way to `fmvt-raster`'s (258–290 MB in
`2026-10-12-c1dc45c-android`), and it costs frames in every scenario:
the UI thread then pays for a placement pass every frame. Against the
first A/B, fades on gained frames (68.7–90.7 % there) and fades off did
not (59.4–79.5 %), as expected.
