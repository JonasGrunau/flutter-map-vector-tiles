import 'package:flutter/material.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:vector_map_tiles/vector_map_tiles.dart' as vmt;

import 'platform/host.dart';

/// One configuration under test. Each measured run gets exactly one, in a
/// fresh process.
enum Arm {
  /// `flutter_map_vector_tiles` at its defaults.
  fmvt('fmvt', 'flutter_map_vector_tiles', 'defaults'),

  /// Control arm: `TileOffset.none` evaluates the style at the flutter_map
  /// zoom and loads data tiles at it, which is what `vector_map_tiles`
  /// does. The gap between this arm and [fmvt] is the cost of the extra
  /// content one zoom higher draws, not of either renderer.
  fmvtNone('fmvt-none', 'flutter_map_vector_tiles', 'TileOffset.none'),

  /// `flutter_map_vector_tiles` with `LabelMode.tile`: labels and icons
  /// drawn into the tile images, as `vector_map_tiles`' raster mode does,
  /// instead of by a screen-space pass every frame. The like-for-like
  /// counterpart of [vmtRaster], as [fmvt] is of [vmtVector].
  fmvtRaster('fmvt-raster', 'flutter_map_vector_tiles', 'LabelMode.tile'),

  /// [fmvtRaster] at `TileOffset.none`: the same content as
  /// [vmtRaster] draws, so the pair compares renderers rather than how
  /// many labels each one has to draw — what [fmvtNone] is to [fmvt].
  fmvtRasterNone('fmvt-raster-none', 'flutter_map_vector_tiles',
      'LabelMode.tile · TileOffset.none'),

  /// `vector_map_tiles` at its defaults — raster mode — plus
  /// `maximumZoom: 22`, without which its layer goes blank past z18.
  vmtRaster('vmt-raster', 'vector_map_tiles', 'raster mode (default)'),

  /// `vector_map_tiles` in vector mode, which its docs recommend for
  /// sharpness.
  vmtVector('vmt-vector', 'vector_map_tiles', 'vector mode');

  const Arm(this.id, this.package, this.variant);

  final String id;
  final String package;
  final String variant;

  String get label => '$package · $variant';

  bool get isVmt => this == vmtRaster || this == vmtVector;

  /// The arm with [id]. Throws on an unknown one: a measured run must fail
  /// with an error row, not measure [fmvt] under the misspelt name.
  static Arm parse(String id) =>
      tryParse(id) ??
      (throw ArgumentError.value(id, 'arm',
          'unknown arm; one of ${values.map((a) => a.id).join(', ')}'));

  /// The arm with [id], or null. For the demo's URL, which may be stale.
  static Arm? tryParse(String id) =>
      values.where((a) => a.id == id).firstOrNull;
}

/// The versions under test, shown on every result. The first follows the
/// parent package's pubspec; the run scripts pass it in.
const fmvtVersion = String.fromEnvironment('FMVT_VERSION', defaultValue: '');
const vmtVersion = '9.0.0-beta.13';

String versionOf(Arm arm) => arm.isVmt ? vmtVersion : fmvtVersion;

const openFreeMapAttribution =
    'OpenFreeMap © OpenMapTiles Data from OpenStreetMap';

/// A loaded arm: its style is read and its layer can be built.
class LoadedArm {
  LoadedArm._(this.arm, this._build, this._clear, this._dispose);

  final Arm arm;
  final Widget Function() _build;
  final void Function() _clear;
  final void Function() _dispose;

  /// A new layer widget. `vector_map_tiles` takes a controller that can be
  /// attached to one layer only, so every call builds a fresh one.
  Widget buildLayer() => _build();

  /// Empties the package's in-memory caches (not the disk).
  void clearMemoryCaches() => _clear();

  void dispose() => _dispose();
}

/// Reads [styleUrl] with the arm's own style reader. [cacheDir], when
/// given, holds the arm's disk cache for this run only.
Future<LoadedArm> loadArm(
  Arm arm, {
  required String styleUrl,
  String? cacheDir,
}) async {
  if (!arm.isVmt) {
    // `cache: false`: the style bundle is not part of what is measured, and
    // a cached copy would make the first and later runs differ.
    final style = await vt.StyleReader(uri: styleUrl, cache: false).read();
    return LoadedArm._(
      arm,
      () => vt.VectorTileLayer(
        theme: style.theme,
        tileProviders: style.providers,
        rasterSources: style.rasterSources,
        sprites: style.sprites,
        tileOffset: arm == Arm.fmvtNone || arm == Arm.fmvtRasterNone
            ? vt.TileOffset.none
            : vt.TileOffset.maplibre,
        labelMode: arm == Arm.fmvtRaster || arm == Arm.fmvtRasterNone
            ? vt.LabelMode.tile
            : vt.LabelMode.screen,
        cachePath: cacheDir == null ? null : () async => '$cacheDir/fmvt',
      ),
      vt.VectorTileLayer.clearMemoryCache,
      style.dispose,
    );
  }

  final style = await vmt.StyleReader(uri: styleUrl).read();
  vmt.VectorTileController? controller;
  return LoadedArm._(
    arm,
    () => vmt.VectorTileLayer(
      controller: controller = vmt.VectorTileController(),
      theme: style.theme,
      sprites: style.sprites,
      tileProviders: style.providers,
      layerMode: arm == Arm.vmtVector
          ? vmt.VectorTileLayerMode.vector
          : vmt.VectorTileLayerMode.raster,
      maximumZoom: 22,
      // vector_map_tiles types this `Future<Directory> Function()` through a
      // conditional typedef: `dart:io`'s Directory on native, `String` on
      // web. `vmtCacheFolder` returns exactly that on each platform, and
      // both compilers agree; the analyzer resolves the typedef through the
      // stub and does not.
      // ignore: argument_type_not_assignable
      cacheFolder: vmtCacheFolder(cacheDir),
    ),
    () {
      controller?.clearMemoryCaches();
      // Raster mode keeps its finished tiles in Flutter's global image
      // cache, which its controller does not clear.
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    },
    () {},
  );
}

/// OpenFreeMap style URLs, direct or through the lab server's replay proxy.
String styleUrlFor(String style, {String? lab, String? runId}) {
  final path = 'styles/$style';
  if (lab == null || lab.isEmpty) return 'https://tiles.openfreemap.org/$path';
  return '$lab/r/${runId ?? '-'}/ofm/$path';
}
