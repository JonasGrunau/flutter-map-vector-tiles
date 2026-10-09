import 'dart:io' as io;

/// Native side of the few things that differ between a device and a browser.
/// The web side is `host_web.dart`; both export the same names.

String get platformName => io.Platform.operatingSystem;

/// A directory no earlier run has touched, so both packages' disk caches
/// start empty in every measured run.
Future<String?> freshCacheDir(String runId) async {
  final dir = io.Directory(
    '${io.Directory.systemTemp.path}/fmvt-compare/'
    '${runId.replaceAll(RegExp(r'[^\w-]'), '_')}',
  );
  if (dir.existsSync()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  return dir.path;
}

Future<void> deleteCacheDir(String? path) async {
  if (path == null) return;
  final dir = io.Directory(path);
  if (dir.existsSync()) await dir.delete(recursive: true);
}

/// `vector_map_tiles`' `cacheFolder`. Its parameter type is
/// `Future<Directory> Function()` with `Directory` being `dart:io`'s on
/// native and `String` on web, hence one shim per platform.
Future<io.Directory> Function()? vmtCacheFolder(String? path) => path == null
    ? null
    : () async => io.Directory('$path/vmt')..createSync(recursive: true);

/// Nothing to reset on native: [freshCacheDir] already isolates the run.
Future<void> resetBrowserStorage() async {}

/// Resident set size in bytes, or null where the platform cannot say.
int? currentRss() => io.ProcessInfo.currentRss;

/// Ends the process so the next run starts in a fresh one.
void exitApp() => io.exit(0);

String? readLocal(String key) => null;
void writeLocal(String key, String? value) {}
void navigate(String url) {}
String get userAgent => io.Platform.operatingSystemVersion;
