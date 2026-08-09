import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../logger.dart';
import 'byte_cache.dart';

/// A byte cache on disk with a freshness TTL and a size cap.
///
/// Entries are single files named by an FNV-1a hash of the key; freshness
/// uses the file's modification time. [get] only returns entries within
/// [ttl]; older entries are *kept* and remain readable via [getStale] so
/// callers can fall back to them when the network is unavailable. The
/// size cap is what actually deletes data: a sweep runs opportunistically
/// after writes and deletes the oldest files first. There is no index
/// file to corrupt — the filesystem is the index.
class DiskCache implements ByteCache {
  final Directory directory;
  final Duration ttl;
  final int maxSizeBytes;
  final Logger logger;

  var _bytesSinceSweep = 0;
  Future<void>? _sweepInFlight;

  DiskCache({
    required this.directory,
    this.ttl = const Duration(days: 14),
    this.maxSizeBytes = 50 * 1024 * 1024,
    this.logger = const Logger.noop(),
  });

  Future<void> initialize() async {
    try {
      await directory.create(recursive: true);
      unawaited(_sweep());
    } catch (e) {
      logger.warn('disk cache unavailable: $e');
    }
  }

  File _fileFor(String key) =>
      File('${directory.path}${Platform.pathSeparator}${_fnv1a(key)}.bin');

  /// Returns the entry if it is fresher than [ttl], else null. Expired
  /// entries are left in place for [getStale].
  @override
  Future<Uint8List?> get(String key) async {
    try {
      final file = _fileFor(key);
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      if (DateTime.now().difference(stat.modified) > ttl) return null;
      return await file.readAsBytes();
    } catch (e) {
      return null;
    }
  }

  /// Returns the entry regardless of age — the offline fallback when a
  /// network fetch fails.
  @override
  Future<Uint8List?> getStale(String key) async {
    try {
      final file = _fileFor(key);
      return await file.exists() ? await file.readAsBytes() : null;
    } catch (e) {
      return null;
    }
  }

  @override
  Future<void> put(String key, Uint8List bytes) async {
    try {
      final file = _fileFor(key);
      // Write-then-rename for atomicity.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: false);
      await tmp.rename(file.path);
      _bytesSinceSweep += bytes.length;
      if (_bytesSinceSweep > maxSizeBytes ~/ 10) {
        _bytesSinceSweep = 0;
        unawaited(_sweep());
      }
    } catch (e) {
      logger.warn('disk cache write failed: $e');
    }
  }

  /// Deletes the oldest entries until the cache is under the size cap.
  /// Age alone never deletes: stale entries are the offline safety net.
  Future<void> _sweep() => _sweepInFlight ??= _doSweep().whenComplete(() {
        _sweepInFlight = null;
      });

  Future<void> _doSweep() async {
    try {
      final files = <({File file, DateTime modified, int size})>[];
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith('.bin')) continue;
        final stat = await entity.stat();
        files.add((file: entity, modified: stat.modified, size: stat.size));
      }
      var total = files.fold(0, (sum, f) => sum + f.size);
      if (total <= maxSizeBytes) return;
      files.sort((a, b) => a.modified.compareTo(b.modified));
      for (final f in files) {
        if (total <= maxSizeBytes) break;
        total -= f.size;
        await f.file.delete().catchError((_) => f.file);
      }
    } catch (e) {
      logger.warn('disk cache sweep failed: $e');
    }
  }

  /// Deletes the entire cache directory.
  Future<void> destroy() async {
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  }

  // FNV-1a 64-bit. The offset basis is assembled from two 32-bit halves
  // because the literal 0xcbf29ce484222325 cannot be represented in
  // JavaScript, and the web test bundle compiles this file even though
  // only dart:io platforms ever run it. VM multiplication wraps at 64
  // bits, so no mask is needed — hashes (and cache file names) are
  // bit-identical to earlier releases.
  // Not const: a const would be folded at compile time, and the web
  // compiler folds with JavaScript semantics — the exact corruption the
  // two-halves construction avoids.
  // ignore: prefer_const_declarations
  static final int _fnvOffsetBasis = (0xcbf29ce4 << 32) | 0x84222325;

  static String _fnv1a(String input) {
    var hash = _fnvOffsetBasis;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash *= 0x100000001b3;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

/// Process-wide [DiskCache] instances, one per cache directory.
///
/// A cache can never be handed out synchronously — resolving its directory
/// goes through a platform channel — but tiles are requested on the very
/// first frame. Callers therefore hold the *future* and await it on the load
/// path, so the opening screenful is served from disk instead of racing
/// initialization and going to the network for tiles that are already there.
///
/// Instances are shared and never evicted, so reopening a map reuses an
/// initialized cache rather than repeating the directory setup. The first
/// caller for a directory fixes its [DiskCache.ttl] and
/// [DiskCache.maxSizeBytes]; a later caller naming the same directory gets
/// that instance whatever settings it asked for.
abstract final class DiskCacheRegistry {
  static final _caches = <String, DiskCache>{};
  static final _pending = <String, Future<DiskCache>>{};

  /// The cache for the directory [folder] resolves to, creating and
  /// initializing it on first use.
  ///
  /// Returns null when the directory cannot be resolved or created; the
  /// caller then runs without a disk cache rather than failing.
  static Future<DiskCache?> obtain({
    required Future<Directory> Function() folder,
    Duration ttl = const Duration(days: 14),
    int maxSizeBytes = 50 * 1024 * 1024,
    Logger logger = const Logger.noop(),
  }) async {
    try {
      final directory = await folder();
      final path = directory.path;
      final existing = _caches[path];
      if (existing != null) return existing;
      final pending = _pending[path];
      if (pending != null) return await pending;
      final creation = _create(directory, ttl, maxSizeBytes, logger);
      _pending[path] = creation;
      return await creation;
    } catch (e) {
      logger.warn('disk cache unavailable: $e');
      return null;
    }
  }

  static Future<DiskCache> _create(
    Directory directory,
    Duration ttl,
    int maxSizeBytes,
    Logger logger,
  ) async {
    final cache = DiskCache(
      directory: directory,
      ttl: ttl,
      maxSizeBytes: maxSizeBytes,
      logger: logger,
    );
    try {
      await cache.initialize();
      _caches[directory.path] = cache;
      return cache;
    } finally {
      // Dropping the entry, not awaiting it — this *is* that future.
      _pending.remove(directory.path)?.ignore();
    }
  }

  /// Forgets every registered instance so the next [obtain] initializes
  /// afresh. The files on disk are untouched. Intended for tests.
  @visibleForTesting
  static void reset() {
    _caches.clear();
    _pending.clear();
  }
}
