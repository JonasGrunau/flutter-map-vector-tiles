import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:latlong2/latlong.dart';

/// Run with your MapTiler key (any MapLibre style URL works):
///
/// ```
/// flutter run \
///   --dart-define=MAPTILER_KEY=yourKey \
///   --dart-define=STYLE_URL=https://api.maptiler.com/maps/streets-v2/style.json?key={key} \
///   --dart-define=LANGUAGE=de
/// ```
///
/// `LANGUAGE` is optional: without it labels show the style's own text.
///
/// Tap the map to see what is drawn there; a tapped building is
/// highlighted through feature state.
///
/// On web (`flutter run -d chrome --dart-define=MAPTILER_KEY=yourKey`)
/// the style and tile hosts must send CORS headers — MapTiler does.
const _apiKey = String.fromEnvironment('MAPTILER_KEY');
const _styleUrl = String.fromEnvironment(
  'STYLE_URL',
  defaultValue: 'https://api.maptiler.com/maps/streets-v2/style.json?key={key}',
);
const _language = String.fromEnvironment('LANGUAGE');

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
        title: 'flutter_map_vector_tiles example',
        home: VectorMapPage(),
      );
}

class VectorMapPage extends StatefulWidget {
  const VectorMapPage({super.key});

  @override
  State<VectorMapPage> createState() => _VectorMapPageState();
}

class _VectorMapPageState extends State<VectorMapPage> {
  late final Future<vt.Style> _style;

  /// Answers what is drawn where the map is tapped, and holds the
  /// feature state the selection layer reads.
  final _features = vt.VectorTileLayerController();
  vt.RenderedFeature? _selected;
  vt.Theme? _theme;

  @override
  void initState() {
    super.initState();
    _style = vt.StyleReader(
      uri: _styleUrl,
      apiKey: _apiKey,
      language: _language.isEmpty ? null : _language,
      logger: const vt.Logger.console(),
    ).read();
  }

  @override
  void dispose() {
    // Release providers and sprites once the map is gone.
    _style.then((style) => style.dispose()).ignore();
    super.dispose();
  }

  /// The style's layers plus one that paints the selected building.
  /// Hosted styles do not read feature state, so the example brings its
  /// own layer for it: transparent until a building is `selected`.
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
              0.7,
              0,
            ],
          },
        },
      ],
    });
    // A theme of its own id: finished tiles are cached by it.
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
        .where((feature) => feature.layerId != 'selection')
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
    final top = hits.firstOrNull;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(top == null
            ? 'Nothing here'
            : '${top.layerId} · ${top.properties['name'] ?? top.properties['class'] ?? top.geometryType}'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vector tiles')),
      body: FutureBuilder(
        future: _style,
        builder: (context, snapshot) {
          final style = snapshot.data;
          if (style == null) {
            final error = snapshot.error;
            return Center(
              child: error != null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Failed to load style:\n$error'),
                    )
                  : const CircularProgressIndicator(),
            );
          }
          return FlutterMap(
            options: MapOptions(
              initialCenter: style.center ?? const LatLng(48.137, 11.575),
              initialZoom: style.zoom ?? 12,
              maxZoom: 21,
              minZoom: 2,
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
                logger: const vt.Logger.console(),
              ),
              // Whatever the style's sources declare — never a hardcoded
              // provider name. Most providers' terms require showing it.
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
      ),
    );
  }
}
