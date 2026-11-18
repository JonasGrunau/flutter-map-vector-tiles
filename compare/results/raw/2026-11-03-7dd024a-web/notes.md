# 2026-11-03-7dd024a-web

All seven arms (the six of `2026-10-12-c1dc45c-web` plus `fmvt-3d`,
`ExtrusionMode.perspective`), 3 rounds, built from 7dd024a (2.11.0 plus
3D buildings). Replaces `2026-10-12-c1dc45c-web` (2.9.1). Started
2026-11-04 03:23, finished 04:28.

- Chrome 156, headed, driven by Playwright on the MacBook Pro (M4 Pro),
  on AC power, the Mac untouched for over two hours before the start.
- Each window moved onto the built-in 120 Hz display
  (`tool/run_web.mjs`). The first Chrome session of this build, at
  01:14–02:19, opened its windows on a 50 Hz external monitor and
  measured 50 Hz frames; it was discarded. Its MapLibre GL JS
  reference shots (same cameras, same tiles) are the ones in this
  session's grid.
- Tiles replayed `--offline` from the recording the October sessions
  used, with the Noto Sans glyph ranges added: 0 misses.
- 0 interrupted passes; this package's arms' rounds lie at most 1.2
  points apart, except one slow round each for `fmvt-raster` (second
  pan, 4.3), `fmvt-raster-none` (2.5) and `fmvt-3d` (second fling,
  7.6); `vmt-raster`'s at most 4.8.
- The `vmt-raster` medians moved by at most 2.4 points against
  October; `vmt-vector`'s by at most 1.7, except panning (+8).
