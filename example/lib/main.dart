import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:latlong2/latlong.dart';

/// Run with your MapTiler key (any MapLibre style URL works):
///
/// ```
/// flutter run \
///   --dart-define=MAPTILER_KEY=yourKey \
///   --dart-define=STYLE_URL=https://api.maptiler.com/maps/streets-v2/style.json?key={key}
/// ```
const _apiKey = String.fromEnvironment('MAPTILER_KEY');
const _styleUrl = String.fromEnvironment(
  'STYLE_URL',
  defaultValue: 'https://api.maptiler.com/maps/streets-v2/style.json?key={key}',
);

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

  @override
  void initState() {
    super.initState();
    _style = const vt.StyleReader(
      uri: _styleUrl,
      apiKey: _apiKey,
      logger: vt.Logger.console(),
    ).read();
  }

  @override
  void dispose() {
    // Release providers and sprites once the map is gone.
    _style.then((style) => style.dispose()).ignore();
    super.dispose();
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
            ),
            children: [
              vt.VectorTileLayer(
                theme: style.theme,
                tileProviders: style.providers,
                rasterSources: style.rasterSources,
                sprites: style.sprites,
                logger: const vt.Logger.console(),
              ),
              const SimpleAttributionWidget(
                source: Text('© MapTiler © OpenStreetMap contributors'),
              ),
            ],
          );
        },
      ),
    );
  }
}
