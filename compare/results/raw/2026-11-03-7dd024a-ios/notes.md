# 2026-11-03-7dd024a-ios

All seven arms (the six of `2026-10-20-ios` plus `fmvt-3d`,
`ExtrusionMode.perspective`), 4 rounds, built from 7dd024a (2.11.0 plus
3D buildings). Replaces `2026-10-20-ios`. Started 2026-11-03 18:34,
finished 19:54, while the Android session ran on its own lab port.

- iPhone 15 Pro Max, iOS 27.0.1, over the USB link, release builds
  (no Local Network prompt: screenshots before and during the session).
- Tiles replayed `--offline` from the recording the October sessions
  used, with the Noto Sans glyph ranges added: 0 misses.
- 0 interrupted passes. `vmt-vector` is the noisy arm: its four rounds
  lie up to 13.4 points apart (cold fling), and its medians moved by up
  to 8.7 points against October. This package's arms' rounds lie within
  0.6 points, `vmt-raster`'s within 2.1, and the `vmt-raster` medians
  moved by less than 1 point against October.
