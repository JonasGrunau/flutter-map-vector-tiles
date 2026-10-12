import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// A camera: what `MapController.moveAndRotate` takes.
class Pose {
  const Pose(this.center, this.zoom, [this.rotation = 0]);

  final LatLng center;
  final double zoom;

  /// flutter_map rotation in degrees.
  final double rotation;
}

/// A scripted camera path. Every arm drives exactly the same path, as a
/// function of elapsed time rather than of frame count, so a janky arm
/// covers the same ground as a smooth one — in fewer frames.
class Scenario {
  const Scenario(this.id, this.title, this.duration, this.at);

  final String id;
  final String title;
  final Duration duration;

  /// The pose at progress `t` in [0, 1].
  final Pose Function(double t) at;

  Pose get start => at(0);
}

// Each scenario runs over a different dense city, so its first ("cold")
// pass meets tiles no earlier scenario of the run has loaded.
const _munich = LatLng(48.1374, 11.5755); // Marienplatz
const _berlin = LatLng(52.5163, 13.3777); // Brandenburger Tor
const _paris = LatLng(48.8606, 2.3376); // Louvre
const _london = LatLng(51.5115, -0.1230); // Covent Garden

double _smooth(double t) => t * t * (3 - 2 * t);

/// Longitude covered by [px] logical pixels at [zoom] (256 px tiles).
double _lonPerPx(double zoom) => 360 / (256 * math.pow(2, zoom));

final scenarios = <Scenario>[
  Scenario(
    'zoom',
    'Zoom z14 → z18 → z14 over Munich',
    const Duration(seconds: 16),
    // Linear in zoom, so every level is crossed at the same rate. The band
    // spans OpenFreeMap Liberty's label gates for both packages: its POI
    // layers open at style z15/16/17, which is flutter_map z16/17/18 for
    // `TileOffset.maplibre` and z15/16/17 for vector_map_tiles.
    (t) => Pose(_munich, 14 + 4 * (t < 0.5 ? 2 * t : 2 - 2 * t)),
  ),
  Scenario(
    'pan',
    'Pan 3000 px east at z16 over Berlin',
    const Duration(seconds: 10),
    // 300 px/s: a new column of tiles roughly every 0.85 s.
    (t) => Pose(
      LatLng(_berlin.latitude, _berlin.longitude + t * 3000 * _lonPerPx(16)),
      16,
    ),
  ),
  Scenario(
    'rotate',
    'Rotate 360° at z16 over Paris',
    const Duration(seconds: 10),
    (t) => Pose(_paris, 16, 360 * t),
  ),
  Scenario(
    'fling',
    'Fast zoom z15 ↔ z17, 1 s per leg, over London',
    const Duration(seconds: 8),
    (t) {
      // Four round trips; each leg eases in and out like a pinch would.
      final legs = t * 8;
      final leg = math.min(legs.floor(), 7);
      final f = _smooth(legs - leg);
      final up = leg.isEven;
      return Pose(_london, up ? 15 + 2 * f : 17 - 2 * f);
    },
  ),
];

Scenario scenarioById(String id) => scenarios.firstWhere((s) => s.id == id);

/// Fixed cameras for the fidelity screenshots, all over Munich.
const shotPoses = <String, Pose>{
  'munich-z14': Pose(_munich, 14),
  'munich-z16': Pose(_munich, 16),
  'munich-z16-rot45': Pose(_munich, 16, 45),
  'munich-z17.5': Pose(_munich, 17.5),
  'munich-z18': Pose(_munich, 18),
};

const startPose = Pose(_munich, 16);
