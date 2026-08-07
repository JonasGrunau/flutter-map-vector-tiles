import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../logger.dart';

/// A byte cache on disk with TTL and a size cap.
///
/// Entries are single files named by an FNV-1a hash of the key; freshness
/// uses the file's modification time. A size sweep runs opportunistically
/// after writes and deletes the oldest files first. There is no index
/// file to corrupt — the filesystem is the index.
class DiskCache {
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

  Future<Uint8List?> get(String key) async {
    try {
      final file = _fileFor(key);
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      if (DateTime.now().difference(stat.modified) > ttl) {
        unawaited(file.delete().catchError((_) => file));
        return null;
      }
      return await file.readAsBytes();
    } catch (e) {
      return null;
    }
  }

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

  /// Deletes expired entries, then oldest entries until under the cap.
  Future<void> _sweep() => _sweepInFlight ??= _doSweep().whenComplete(() {
        _sweepInFlight = null;
      });

  Future<void> _doSweep() async {
    try {
      final now = DateTime.now();
      final files = <({File file, DateTime modified, int size})>[];
      await for (final entity in directory.list()) {
        if (entity is! File || !entity.path.endsWith('.bin')) continue;
        final stat = await entity.stat();
        if (now.difference(stat.modified) > ttl) {
          await entity.delete().catchError((_) => entity);
        } else {
          files.add((file: entity, modified: stat.modified, size: stat.size));
        }
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

  static String _fnv1a(String input) {
    var hash = 0xcbf29ce484222325;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
