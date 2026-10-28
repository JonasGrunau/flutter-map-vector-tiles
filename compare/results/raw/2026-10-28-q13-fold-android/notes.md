# Feature state folded into featureContext · Nothing Phone (1) · 2026-10-28

The fmvt zoom passes after this branch merged the integration branch and
folded its feature-state subclass into #24's `featureContext` (decision
d13-5), against the integration branch before that merge.

- `I`: integration branch `85d28be` (main + #29, #22, #24, #30, #27, #21)
- `F`: `feature-query-state` at `79ce34f` (that merge, with the fold)

`tool/run_android.sh P11275000244 2 --arms=fmvt --scenarios=zoom`, in the
order I F F I, 13:20 to 13:31, tiles from compare's lab on 8790 over
`adb reverse`, replayed from the recorded cache. Profile builds, Impeller
falling back to GLES. No pass was interrupted.

| fmvt zoom, frames delivered % | I | F |
|---|---|---|
| cold | 92.0 (91.5–92.7) | 90.9 (89.5–91.8) |
| warm | 91.9 (91.1–92.0) | 91.4 (88.1–92.7) |

Medians of 4 runs, ranges in brackets. UI p90 in the cold pass was 12.6 ms
(12.5–12.9) against 13.2 ms (12.6–13.8); stalls 3–10 against 7–8.
