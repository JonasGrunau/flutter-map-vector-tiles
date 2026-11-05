# 2026-11-03-7dd024a-android

All seven arms (the six of `2026-10-12-c1dc45c-android` plus `fmvt-3d`,
`ExtrusionMode.perspective`), 3 rounds, built from 7dd024a (2.11.0 plus
3D buildings). Replaces `2026-10-12-c1dc45c-android` (2.9.1). Started
2026-11-03 18:34, finished 19:39, while the iPhone session ran on its
own lab port.

- Nothing Phone (1), portrait, on USB power.
- Tiles replayed `--offline` from the recording the October sessions
  used, with the Noto Sans glyph ranges added (Liberty's labels draw
  from glyph PBFs since 2.10.0): 0 misses. A first pass the same
  evening replayed a copy without most glyph ranges, so bold and some
  other labels fell back to platform text; it was discarded.
- GPU memory sampled every ~3 s from `dumpsys gpu --gpumem`
  (`gpu-memory.txt`, the same sampler as before).
- 0 interrupted passes; an arm's three rounds lie at most 5.2 points
  apart (`fmvt-3d`'s cold fling).
- The `vmt-*` arms did not change and serve as a control: their medians
  moved by at most 2.3 points against the October session.
