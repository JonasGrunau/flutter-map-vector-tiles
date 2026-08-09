import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../logger.dart';
import 'byte_cache.dart';
import 'disk_cache.dart';

/// The shared tile byte cache for [cachePath] (or the default location),
/// via [DiskCacheRegistry]. Returns null when the directory cannot be
/// resolved or created.
Future<ByteCache?> obtainTileCache({
  Future<String> Function()? cachePath,
  required Duration ttl,
  required int maxSizeBytes,
  required Logger logger,
}) =>
    DiskCacheRegistry.obtain(
      folder: cachePath == null
          ? _defaultCacheFolder
          : () async => Directory(await cachePath()),
      ttl: ttl,
      maxSizeBytes: maxSizeBytes,
      logger: logger,
    );

/// Opens the on-disk style cache; failures degrade to network-only.
Future<ByteCache?> openStyleCache({
  Future<String> Function()? cachePath,
  required Duration refreshAfter,
  required Logger logger,
}) async {
  try {
    final dir = cachePath != null
        ? Directory(await cachePath())
        : Directory('${(await getApplicationSupportDirectory()).path}'
            '${Platform.pathSeparator}flutter_map_vector_tiles'
            '${Platform.pathSeparator}style');
    final diskCache = DiskCache(
      directory: dir,
      ttl: refreshAfter,
      maxSizeBytes: 8 * 1024 * 1024,
      logger: logger,
    );
    await diskCache.initialize();
    return diskCache;
  } catch (e) {
    logger.warn('style cache unavailable: $e');
    return null;
  }
}

Future<Directory> _defaultCacheFolder() async => Directory(
      '${(await getApplicationSupportDirectory()).path}'
      '${Platform.pathSeparator}flutter_map_vector_tiles',
    );
