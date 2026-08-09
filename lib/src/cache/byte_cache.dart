import 'dart:typed_data';

/// A byte cache with a freshness TTL: [get] returns only fresh entries,
/// [getStale] returns entries regardless of age (the offline fallback).
///
/// Implemented by `DiskCache` on platforms with a filesystem; on web no
/// implementation exists and callers run with a null cache, falling back
/// to the in-memory cache and the browser's own HTTP cache.
abstract interface class ByteCache {
  /// Returns the entry if it is still fresh, else null.
  Future<Uint8List?> get(String key);

  /// Returns the entry regardless of age — the offline fallback when a
  /// network fetch fails.
  Future<Uint8List?> getStale(String key);

  Future<void> put(String key, Uint8List bytes);
}
