import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Browser side of `host_io.dart`; see there.

const _wasm = bool.fromEnvironment('dart.tool.dart2wasm');

String get platformName => _wasm ? 'web-wasm' : 'web';

/// Neither package has a disk cache on web that takes a path.
Future<String?> freshCacheDir(String runId) async => null;

Future<void> deleteCacheDir(String? path) async {}

/// On web `vector_map_tiles` types `cacheFolder` as returning a `String`
/// and stores its cache in IndexedDB regardless; [resetBrowserStorage]
/// clears that instead.
Future<String> Function()? vmtCacheFolder(String? path) => null;

/// Deletes `vector_map_tiles`' IndexedDB cache — tile bytes *and* rendered
/// PNG tiles — so a reload measures rendering rather than a cache replay.
/// `flutter_map_vector_tiles` keeps nothing persistent on web.
Future<void> resetBrowserStorage() async {
  final done = Completer<void>();
  final request = web.window.indexedDB.deleteDatabase('vector_map_tiles');
  void finish(web.Event _) {
    if (!done.isCompleted) done.complete();
  }

  request
    ..onsuccess = finish.toJS
    ..onerror = finish.toJS
    ..onblocked = finish.toJS;
  await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
}

int? currentRss() => null;

void exitApp() {}

String? readLocal(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void writeLocal(String key, String? value) {
  try {
    if (value == null) {
      web.window.localStorage.removeItem(key);
    } else {
      web.window.localStorage.setItem(key, value);
    }
  } catch (_) {}
}

void navigate(String url) => web.window.location.href = url;

void openInNewTab(String url) => web.window.open(url, '_blank');

String get userAgent => web.window.navigator.userAgent;
