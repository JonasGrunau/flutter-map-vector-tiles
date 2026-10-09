import 'package:flutter/foundation.dart';

const _defines = {
  'lab': String.fromEnvironment('LAB'),
  'arm': String.fromEnvironment('ARM'),
  'mode': String.fromEnvironment('MODE'),
  'style': String.fromEnvironment('STYLE'),
  'device': String.fromEnvironment('DEVICE'),
};

/// A setting from the page URL on web (so the demo can switch packages by
/// reloading), otherwise from `--dart-define`.
String _setting(String name, String fallback) {
  if (kIsWeb) {
    final fromUrl = Uri.base.queryParameters[name];
    if (fromUrl != null && fromUrl.isNotEmpty) return fromUrl;
  }
  final defined = _defines[name] ?? '';
  return defined.isEmpty ? fallback : defined;
}

/// The app's start-up configuration.
class Config {
  Config.fromEnvironment()
      : lab = _setting('lab', ''),
        arm = _setting('arm', 'fmvt'),
        mode = _setting('mode', 'demo'),
        style = _setting('style', 'liberty'),
        device = _setting('device', '');

  /// Lab server base URL (`tool/lab_server.dart`). Set for measured runs,
  /// which then take their arm from the server's queue.
  final String lab;

  /// The arm the demo shows.
  final String arm;

  /// `demo`, `bench` (the in-browser benchmark) or `results`. A set [lab]
  /// always means a measured run.
  final String mode;

  /// OpenFreeMap style name: `liberty`, `bright` or `positron`.
  final String style;

  /// Device label for the results, passed in by the run scripts.
  final String device;

  bool get hasLab => lab.isNotEmpty;
}
