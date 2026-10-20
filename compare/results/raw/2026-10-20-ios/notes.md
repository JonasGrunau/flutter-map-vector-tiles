# 2026-10-20-ios

All six arms, 4 rounds, built from d8c2e86 in profile mode, on an
iPhone 15 Pro Max (iOS 27.0.1, 120 Hz, 430×932 logical px at dpr 3).
The first iOS session, run with `tool/run_ios.sh`. Ran 2026-10-20 11:55
to 13:03.

- The phone was wired to the Mac, charging, and nobody touched it. The
  app reached the lab server over the USB link (`--bind` on the Mac's
  169.254 address on that interface), not over Wi-Fi.
- Replayed the same recorded tiles as the 2026-10-12-c1dc45c sessions
  (OpenFreeMap `planet/20261004_113936_pt`) with `--offline`: 0 misses.
- d8c2e86 is later than those sessions' c1dc45c. Since then the package
  keeps road shields off lines too short for them and long words whole
  (d2b2d4d), fixed the 2.9.1..main review findings (7ba8dd0), and dims
  fill outlines by `fill-opacity` and draws them one device pixel wide,
  as MapLibre does (cbcb8a0, cbc75a5, e8bddfe).
  Compare arms within this session, not with the other platforms'
  sessions.
- One measurement is flagged `interrupted` and left out of the tables:
  round 0, `fmvt`, pan, cold (the app was `inactive` for a moment,
  during the session's first run). That cell is the median of the other
  3 rounds.
- GPU memory was not sampled: the scripts have no iOS counterpart to
  Android's `dumpsys gpu --gpumem`.
- Round-to-round spread of frames delivered: at most 4.2 points
  (`vmt-vector`, zoom, cold), 0.4 at the median.
