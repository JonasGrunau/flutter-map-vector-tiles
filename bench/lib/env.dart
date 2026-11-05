/// The harness's knobs: every one a `--dart-define`, passed through by
/// `run.sh` from the environment.
library;

import 'package:latlong2/latlong.dart';

/// What a run measures. See [Env.mode].
enum BenchMode { bench, idle, manual, stability, query }

/// How `fill-extrusion` layers are drawn. See [Env.extrude].
enum ExtrudeArm { flat, perspective, opaque }

abstract final class Env {
  /// Key-free by default so the harness is reproducible without a key. Any
  /// MapLibre style URL works; `{key}` is substituted from [apiKey].
  static const styleUrl = String.fromEnvironment(
    'STYLE_URL',
    defaultValue: 'https://tiles.openfreemap.org/styles/liberty',
  );
  static const apiKey = String.fromEnvironment('MAPTILER_KEY');

  /// Tag for the log lines, so two runs can be diffed.
  static const label =
      String.fromEnvironment('BENCH_LABEL', defaultValue: 'run');

  /// `bench` runs the phase matrix; `idle` parks the map at [idleZoom] so you
  /// can screenshot it and confirm which labels the style is actually drawing.
  /// That check is not optional busywork: aiming this harness at a zoom band
  /// whose POIs never switch on measures nothing, convincingly.
  /// `manual` hands the camera to your fingers instead of the sweep driver:
  /// gestures are enabled, a report is printed every few seconds, and every
  /// frame over the 60 Hz budget logs a `JANK` line tagged with the zoom it
  /// happened at — for chasing a stutter you can feel but the scripted sweep
  /// does not reproduce.
  /// `stability` measures label steadiness instead of frame time: four slow
  /// *monotonic* sweeps across the band (cold in/out, then warm in/out), each
  /// reporting a `STABILITY` line counting pop-ins (a label appearing at full
  /// opacity with no fade), pop-outs (vanishing from full opacity with no
  /// ghost) and blinks (disappearing and returning at the same spot within a
  /// few seconds). Monotonic is the point: on a one-way sweep a zoom gate
  /// fires at most once, so every blink is a genuine placement flip-flop —
  /// an oscillating sweep would re-cross its gates and drown the signal.
  /// `query` parks the map at [idleZoom] and measures
  /// `VectorTileLayerController`: what a `queryRenderedFeatures` call costs
  /// across the screen, what one `setFeatureState` costs until the tiles it
  /// touches are drawn again (ms, frames, tiles), and what decoding every
  /// property (`retainAllProperties`) costs per tile against the style's own.
  /// An unknown name runs `bench`.
  static final mode = BenchMode.values.asNameMap()[_mode] ?? BenchMode.bench;
  static const _mode =
      String.fromEnvironment('BENCH_MODE', defaultValue: 'bench');

  /// `query` mode: run the layer with `retainAllProperties`, to compare
  /// what the process holds after the same walk with and without it.
  static const retainAll = bool.fromEnvironment('BENCH_RETAIN_ALL');

  /// `BENCH_LOG_GONE=true` prints a `GONE` line for every on-screen label
  /// that stops drawing — for lining a burst of blinks up with its zoom.
  static const logGone = bool.fromEnvironment('BENCH_LOG_GONE');

  /// `BENCH_WATCH=<regexp>` prints every rejection, frame by frame, of the
  /// labels whose continuity key matches, and a `DRAWN` line (label id,
  /// screen position, opacity) for every frame one is drawn — for chasing
  /// one blink.
  static final watch = _watch.isEmpty ? null : RegExp(_watch);
  static const _watch = String.fromEnvironment('BENCH_WATCH');

  /// Which app's layer wiring the harness mirrors. `default` is the bench's
  /// own setup. `safenow` reproduces the SafeNow app's `MapBaseLayer`/`SnMap`
  /// wiring exactly: no raster sources, 16 MiB decoded-tile memory cache,
  /// 150 MiB disk cache, zoom clamped to 2..21, the style's light background,
  /// and the app's gesture set in manual mode. Point `STYLE_URL` at that
  /// app's style document and pass its key via `MAPTILER_KEY` on the command
  /// line — keys must never be committed to this repo.
  static const safenow = _setup == 'safenow';
  static const _setup =
      String.fromEnvironment('BENCH_SETUP', defaultValue: 'default');

  /// `false` draws text halos crisp, ignoring `text-halo-blur`, to put a
  /// number on the blur's cost (A/B against the default).
  static const haloBlur =
      bool.fromEnvironment('BENCH_HALO_BLUR', defaultValue: true);

  /// How `fill-extrusion` layers are drawn: `flat` (the package's
  /// default), `perspective` (3D buildings, opt-in), or `opaque` —
  /// perspective without the layer's `saveLayer`, to cost that on the
  /// raster thread. Any other value draws perspective.
  static final extrude =
      ExtrudeArm.values.asNameMap()[_extrude] ?? ExtrudeArm.perspective;
  static const _extrude =
      String.fromEnvironment('BENCH_EXTRUDE', defaultValue: 'flat');

  /// Zooms are given in tenths, because `double.fromEnvironment` does not exist.
  static const idleZoom =
      int.fromEnvironment('BENCH_ZOOM10', defaultValue: 170) / 10;

  /// The crossing to oscillate across. The default straddles z17, which is where
  /// OpenFreeMap Liberty opens the POI floodgates — see `AGENTS.md` for that
  /// style's rank table, and re-derive it for any other style before trusting a
  /// number out of this harness.
  static const lo = int.fromEnvironment('BENCH_LO', defaultValue: 163) / 10;
  static const hi = int.fromEnvironment('BENCH_HI', defaultValue: 177) / 10;

  /// Munich centre — dense enough to have something to draw at every zoom.
  static const lat =
      int.fromEnvironment('BENCH_LAT_E5', defaultValue: 4813720) / 1e5;
  static const lon =
      int.fromEnvironment('BENCH_LON_E5', defaultValue: 1157550) / 1e5;
  static const centre = LatLng(lat, lon);
}
