/// flutter_map_vector_tiles next to vector_map_tiles: one app that is both
/// the measured benchmark (with `tool/lab_server.dart`) and the web demo.
///
/// See `README.md` for how to run it and what each number means.
library;

import 'package:flutter/material.dart';

import 'src/bench_page.dart';
import 'src/config.dart';
import 'src/demo_page.dart';
import 'src/metrics.dart';
import 'src/results_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Start recording frames before the first one, so the demo's readout and
  // the benchmark's calibration see every frame.
  FrameLog.instance;
  runApp(CompareApp(config: Config.fromEnvironment()));
}

class CompareApp extends StatelessWidget {
  const CompareApp({super.key, required this.config});

  final Config config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_map_vector_tiles vs vector_map_tiles',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
      ),
      home: switch (config.mode) {
        _ when config.hasLab => BenchPage(config: config),
        'bench' => BenchPage(config: config),
        'results' => const ResultsPage(),
        _ => DemoPage(config: config),
      },
    );
  }
}
