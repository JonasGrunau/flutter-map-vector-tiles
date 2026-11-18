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
// example does, and shows what the query returned on top in a pill.
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
  vt.RenderedFeature? _hit;
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

  /// The style's layers plus two that paint the selected building: a
  /// translucent blue fill and a darker outline.
  vt.Theme _withSelection(vt.Theme theme) {
    final buildings = theme.layers
        .where((layer) => layer.sourceLayer == 'building')
        .firstOrNull;
    if (buildings == null) return theme;
    List<Object> whenSelected(num value) => [
          'case',
          [
            'boolean',
            ['feature-state', 'selected'],
            false
          ],
          value,
          0,
        ];
    final selection = const vt.ThemeReader().read({
      'layers': [
        {
          'id': 'selection',
          'type': 'fill',
          'source': buildings.source,
          'source-layer': 'building',
          'paint': {
            'fill-color': '#1e88e5',
            'fill-opacity': whenSelected(0.45),
          },
        },
        {
          'id': 'selection-outline',
          'type': 'line',
          'source': buildings.source,
          'source-layer': 'building',
          'layout': {'line-join': 'round'},
          'paint': {
            'line-color': '#0d47a1',
            'line-width': 2,
            'line-opacity': whenSelected(1),
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
    final hits = _features
        .queryRenderedFeatures(point)
        .where((f) => !f.layerId.startsWith('selection'))
        .toList();
    final previous = _selected;
    if (previous != null) {
      _features.removeFeatureState(
        source: previous.source,
        sourceLayer: previous.sourceLayer,
        id: previous.id!,
      );
      _selected = null;
    }
    final building = hits
        .where((f) => f.sourceLayer == 'building' && f.id != null)
        .firstOrNull;
    if (building != null) {
      _features.setFeatureState(
        source: building.source,
        sourceLayer: building.sourceLayer,
        id: building.id!,
        state: {'selected': true},
      );
      _selected = building;
    }
    setState(() => _hit = hits.firstOrNull);
  }

  /// What the last tap's query returned on top, as the example's snackbar
  /// shows it: the style layer that drew it and its name.
  Widget _hitPill(vt.RenderedFeature hit) {
    final name =
        hit.properties['name'] ?? hit.properties['class'] ?? hit.geometryType;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            boxShadow: const [
              BoxShadow(color: Color(0x33000000), blurRadius: 6),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xff1e88e5),
                    shape: BoxShape.circle,
                  ),
                  child: SizedBox.square(dimension: 8),
                ),
                const SizedBox(width: 8),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 13, color: Colors.black87),
                    children: [
                      TextSpan(
                        text: hit.layerId,
                        style: const TextStyle(color: Colors.black54),
                      ),
                      const TextSpan(text: ' · '),
                      TextSpan(
                        text: '$name',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
              if (_hit case final hit?) _hitPill(hit),
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
