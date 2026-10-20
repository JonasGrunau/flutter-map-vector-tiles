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
///
/// `lab` from the URL only when it names the page's own origin. The lab
/// server serves the app from its own `/app/` and gives its control
/// endpoints no CORS headers, so a real lab never is anywhere else; on
/// the public demo, any other `?lab=` would make the page render a style
/// from that server and report to it.
String _setting(String name, String fallback) {
  if (kIsWeb) {
    final fromUrl = Uri.base.queryParameters[name];
    if (fromUrl != null &&
        fromUrl.isNotEmpty &&
        (name != 'lab' || _isPageOrigin(fromUrl))) {
      return fromUrl;
    }
  }
  final defined = _defines[name] ?? '';
  return defined.isEmpty ? fallback : defined;
}

bool _isPageOrigin(String url) {
  final uri = Uri.tryParse(url);
  // `origin` throws for anything but http(s) with a host.
  if (uri == null ||
      !(uri.isScheme('http') || uri.isScheme('https')) ||
      uri.host.isEmpty) {
    return false;
  }
  return uri.origin == Uri.base.origin;
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
