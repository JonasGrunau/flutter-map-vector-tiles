# 2026-10-12-c1dc45c-web

All six arms, 3 rounds, built from c1dc45c with `flutter build web
--profile` (dart2js), in headed Chrome 155 driven by Playwright, on the
MacBook Pro of `2026-10-12-c1dc45c-macos`. Replaces
`2026-10-12-web-nostore`. Ran 2026-10-13 05:41 to 06:37.

- On AC power, nobody at the Mac: the run waited until the Mac had been
  idle for 10 minutes and no Android emulator was running.
- Tiles replayed `--offline` from the recording the Android sessions
  use, with cacheable responses (`max-age=86400`): 0 misses.
- 0 interrupted passes; an arm's three rounds lie at most 3.7 points
  apart.
- Machine load, sampled every 30 s: median 6.5 (1-minute average, two
  booted iOS simulators of other work included), one spike to 45 at
  05:45–05:49 from macOS background services (`contactsd`,
  `amsengagementd`). It overlapped round 0 of `fmvt-none` and
  `fmvt-raster`, and both lie within 2 points of their other rounds.
- The zoom passes request what they do on macOS: 12 tiles on the first
  pass and 0 on the second for `fmvt`, none for `fmvt-none`, so the
  browser's HTTP cache answered every repeat request (the no-store
  session's 28/18 and 38/38 are gone).
- MapLibre GL JS 4.7.1 reference shots (`maplibre` column) rendered from
  the same recording afterwards; the MapLibre lab ran online for its
  glyphs, with 0 upstream errors.
