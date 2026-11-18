// The app the screenshots are taken of: one map, set up entirely from the
// page URL, so `capture.mjs` gets every image from a single web build.
//
// It lives outside `example/` to keep the example small, and is built with
// the example's package configuration:
//
//     cd example && flutter build web --release -t ../screenshots/tool/shot_app.dart
//
// URL parameters (see `capture.mjs` for the shots that use them):
//
// - `style`: style JSON URL, relative to the page or absolute
// - `lat`, `lon`, `zoom`, `rot`: the camera; `rot` in degrees
// - `extrusion=perspective`: 3D buildings
// - `labels=tile`: labels baked into the tiles
// - `lang`: label language
//
// A tap selects the building under it through feature state, as the
// example does.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:latlong2/latlong.dart';

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: ShotMap()),
    ));

class ShotMap extends StatefulWidget {
  const ShotMap({super.key});

  @override
  State<ShotMap> createState() => _ShotMapState();
}

class _ShotMapState extends State<ShotMap> {
  final _query = Uri.base.queryParameters;
  final _features = vt.VectorTileLayerController();
  late final Future<vt.Style> _style;
  vt.RenderedFeature? _selected;
  vt.Theme? _theme;

  double _number(String name, double fallback) =>
      double.tryParse(_query[name] ?? '') ?? fallback;

  @override
  void initState() {
    super.initState();
    _style = vt.StyleReader(
      uri:
          Uri.base.resolve(_query['style'] ?? 'styles/liberty.json').toString(),
      language: _query['lang'],
      logger: const vt.Logger.console(),
    ).read();
  }

  @override
  void dispose() {
    _style.then((style) => style.dispose()).ignore();
    super.dispose();
  }

  /// The style's layers plus one that paints the selected building.
  vt.Theme _withSelection(vt.Theme theme) {
    final buildings = theme.layers
        .where((layer) => layer.sourceLayer == 'building')
        .firstOrNull;
    if (buildings == null) return theme;
    final selection = const vt.ThemeReader().read({
      'layers': [
        {
          'id': 'selection',
          'type': 'fill',
          'source': buildings.source,
          'source-layer': 'building',
          'paint': {
            'fill-color': '#e53935',
            'fill-opacity': [
              'case',
              [
                'boolean',
                ['feature-state', 'selected'],
                false
              ],
              0.75,
              0,
            ],
          },
        },
      ],
    });
    return vt.Theme(
      id: '${theme.id}+selection',
      layers: [...theme.layers, ...selection.layers],
    );
  }

  void _onTap(TapPosition tap, LatLng _) {
    final point = tap.relative;
    if (point == null) return;
    final previous = _selected;
    if (previous != null) {
      _features.removeFeatureState(
        source: previous.source,
        sourceLayer: previous.sourceLayer,
        id: previous.id!,
      );
      _selected = null;
    }
    final building = _features
        .queryRenderedFeatures(point)
        .where((f) =>
            f.layerId != 'selection' &&
            f.sourceLayer == 'building' &&
            f.id != null)
        .firstOrNull;
    if (building == null) return;
    _features.setFeatureState(
      source: building.source,
      sourceLayer: building.sourceLayer,
      id: building.id!,
      state: {'selected': true},
    );
    _selected = building;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
        future: _style,
        builder: (context, snapshot) {
          final style = snapshot.data;
          if (style == null) {
            return Center(child: Text('${snapshot.error ?? ''}'));
          }
          return FlutterMap(
            options: MapOptions(
              initialCenter: LatLng(
                _number('lat', 48.1373),
                _number('lon', 11.5755),
              ),
              initialZoom: _number('zoom', 15),
              initialRotation: _number('rot', 0),
              maxZoom: 21,
              onTap: _onTap,
            ),
            children: [
              vt.VectorTileLayer(
                controller: _features,
                theme: _theme ??= _withSelection(style.theme),
                tileProviders: style.providers,
                rasterSources: style.rasterSources,
                sprites: style.sprites,
                glyphs: style.glyphs,
                labelMode: _query['labels'] == 'tile'
                    ? vt.LabelMode.tile
                    : vt.LabelMode.screen,
                extrusionMode: _query['extrusion'] == 'perspective'
                    ? vt.ExtrusionMode.perspective
                    : vt.ExtrusionMode.flat,
                logger: const vt.Logger.console(),
              ),
              if (style.attributions.isNotEmpty)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text(
                          'flutter_map | © '
                          '${style.attributions.map((a) => a.text).join(' · ')}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black87,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
}
