# 2026-10-12-c1dc45c-android

All six arms, 3 rounds, built from c1dc45c. Replaces
`2026-10-12-android` (built from 31e7d17), which predates 3408659 and
PR #9. Started 2026-10-12 20:03, finished 21:02.

- Nothing Phone (1), portrait, on USB power: battery 100 % throughout,
  28 °C at the start, 31 °C at the end.
- Tiles replayed `--offline` from a copy of the recording
  `2026-10-12-android` used: 0 misses, so both sessions read the same
  bytes.
- GPU memory sampled every ~3 s from `dumpsys gpu --gpumem`
  (`gpu-memory.txt`, the same sampler as before).
- 0 interrupted passes; an arm's three rounds lie at most 7.3 points
  apart (`vmt-raster`'s warm fling, 71.2–78.5 %).
- The `vmt-*` arms did not change between the two builds and serve as a
  control: their frames moved by 0–4 points, so the device conditions
  match the earlier session.
