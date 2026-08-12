import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'mbtiles_metadata.dart';
import 'mbtiles_reader.dart';

/// Opens [path] on a dedicated reader isolate.
Future<MbTilesReader> openMbTilesReader(String path) =>
    _IsolateReader.open(path);

// Messages. Kept transferable: strings, ints and Uint8Lists only.

class _Boot {
  final String path;
  final SendPort reply;
  const _Boot(this.path, this.reply);
}

/// The worker is up and the archive checked out.
class _Ready {
  final SendPort requests;
  final Map<String, String> metadata;
  final int minZoom;
  final int maxZoom;
  const _Ready(this.requests, this.metadata, this.minZoom, this.maxZoom);
}

/// The archive could not be opened. Terminal — the worker exits.
class _Failed {
  final String message;
  const _Failed(this.message);
}

class _Request {
  final int id;
  final int z;
  final int x;
  final int tmsY;
  const _Request(this.id, this.z, this.x, this.tmsY);
}

class _Response {
  final int id;
  final Uint8List? bytes;
  final String? error;
  const _Response(this.id, this.bytes, this.error);
}

class _Close {
  const _Close();
}

class _IsolateReader implements MbTilesReader {
  final Isolate _isolate;
  final ReceivePort _responses;
  final SendPort _requests;
  final Map<int, Completer<Uint8List?>> _pending;

  @override
  final MbTilesMetadata metadata;
  @override
  final int minZoom;
  @override
  final int maxZoom;
  @override
  final String identity;

  var _nextId = 0;
  var _closed = false;

  _IsolateReader._({
    required Isolate isolate,
    required ReceivePort responses,
    required SendPort requests,
    required Map<int, Completer<Uint8List?>> pending,
    required this.metadata,
    required this.minZoom,
    required this.maxZoom,
    required this.identity,
  })  : _isolate = isolate,
        _responses = responses,
        _requests = requests,
        _pending = pending;

  static Future<MbTilesReader> open(String path) async {
    // Statted here rather than on the worker: the result is part of the
    // cache identity, and a missing file should fail before an isolate is
    // spawned for it.
    final FileStat stat;
    try {
      stat = await File(path).stat();
    } catch (e) {
      throw MbTilesException('cannot read $path: $e');
    }
    if (stat.type != FileSystemEntityType.file) {
      throw MbTilesException('no MBTiles archive at $path');
    }

    final responses = ReceivePort();
    final pending = <int, Completer<Uint8List?>>{};
    final ready = Completer<_Ready>();

    void failEverything(Object error) {
      if (!ready.isCompleted) ready.completeError(error);
      for (final completer in pending.values) {
        if (!completer.isCompleted) completer.completeError(error);
      }
      pending.clear();
    }

    responses.listen((Object? message) {
      switch (message) {
        case _Ready():
          if (!ready.isCompleted) ready.complete(message);
        case _Failed():
          failEverything(MbTilesException(message.message));
        case _Response():
          final completer = pending.remove(message.id);
          if (completer == null || completer.isCompleted) return;
          final error = message.error;
          if (error != null) {
            completer.completeError(MbTilesException(error));
          } else {
            completer.complete(message.bytes);
          }
        // onExit sends null, onError a [error, stackTrace] pair. Either
        // means no further response is coming, so waiters must not hang.
        case null:
          failEverything(const MbTilesException('reader isolate exited'));
        case final List<Object?> error:
          failEverything(MbTilesException('reader isolate failed: '
              '${error.isEmpty ? 'unknown' : error.first}'));
      }
    });

    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _worker,
        _Boot(path, responses.sendPort),
        onExit: responses.sendPort,
        onError: responses.sendPort,
        debugName: 'mbtiles reader',
      );
    } catch (e) {
      responses.close();
      throw MbTilesException('cannot start the reader isolate: $e');
    }

    final _Ready boot;
    try {
      boot = await ready.future;
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      responses.close();
      rethrow;
    }

    return _IsolateReader._(
      isolate: isolate,
      responses: responses,
      requests: boot.requests,
      pending: pending,
      metadata: MbTilesMetadata.parse(boot.metadata),
      minZoom: boot.minZoom,
      maxZoom: boot.maxZoom,
      identity: '$path:${stat.size}:${stat.modified.millisecondsSinceEpoch}',
    );
  }

  @override
  Future<Uint8List?> tile(int z, int x, int tmsY) {
    if (_closed) {
      return Future.error(const MbTilesException('archive closed'));
    }
    final id = _nextId++;
    final completer = Completer<Uint8List?>();
    _pending[id] = completer;
    _requests.send(_Request(id, z, x, tmsY));
    return completer.future;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _requests.send(const _Close());
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const MbTilesException('archive closed'));
      }
    }
    _pending.clear();
    _responses.close();
    // The worker disposes the database and closes its port on _Close, so
    // this is only a backstop for a wedged one. Read-only SQLite has no
    // journal to clean up, so killing it is safe.
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

/// Reader-isolate entry point. Opens the archive, reports what the
/// provider needs up front, then answers tile requests until closed.
void _worker(_Boot boot) {
  final Database database;
  try {
    database = sqlite3.open(boot.path, mode: OpenMode.readOnly);
  } catch (e) {
    boot.reply.send(_Failed('cannot open ${boot.path}: $e'));
    return;
  }

  final Map<String, String> metadata;
  final int minZoom;
  final int maxZoom;
  try {
    // Doubles as the "is this really an MBTiles archive" check: SQLite
    // does not touch the file until the first statement, so a missing
    // `tiles` table (or a file that is not a database at all) surfaces
    // here rather than at open.
    database.select('SELECT 1 FROM tiles LIMIT 1');
    metadata = _readMetadata(database);
    final zooms = _zoomRange(database, metadata);
    minZoom = zooms.$1;
    maxZoom = zooms.$2;
  } catch (e) {
    database.dispose();
    boot.reply.send(_Failed('${boot.path} is not a readable MBTiles '
        'archive (no usable `tiles` table): $e'));
    return;
  }

  final requests = ReceivePort();
  boot.reply.send(_Ready(requests.sendPort, metadata, minZoom, maxZoom));

  requests.listen((Object? message) {
    if (message is _Close) {
      database.dispose();
      requests.close();
      return;
    }
    if (message is! _Request) return;
    try {
      final rows = database.select(
        'SELECT tile_data FROM tiles '
        'WHERE zoom_level = ? AND tile_column = ? AND tile_row = ? LIMIT 1',
        [message.z, message.x, message.tmsY],
      );
      final blob = rows.isEmpty ? null : rows.first['tile_data'];
      boot.reply.send(
        _Response(message.id, blob is Uint8List ? blob : null, null),
      );
    } catch (e) {
      boot.reply.send(_Response(message.id, null, '$e'));
    }
  });
}

/// The `metadata` table, or empty when the archive omits it — it is
/// optional in practice, and its absence must not fail an otherwise
/// readable archive.
Map<String, String> _readMetadata(Database database) {
  try {
    final rows = database.select('SELECT name, value FROM metadata');
    return {
      for (final row in rows)
        if (row['name'] case final String name)
          name: switch (row['value']) {
            final String value => value,
            final Object value => '$value',
            null => '',
          },
    };
  } catch (_) {
    return const {};
  }
}

/// Declared zoom range, falling back to the tile table and then to the
/// same defaults a vector source gets elsewhere.
(int, int) _zoomRange(Database database, Map<String, String> metadata) {
  var low = int.tryParse(metadata['minzoom']?.trim() ?? '');
  var high = int.tryParse(metadata['maxzoom']?.trim() ?? '');
  if (low == null || high == null) {
    try {
      final row = database
          .select('SELECT MIN(zoom_level) AS lo, MAX(zoom_level) AS hi '
              'FROM tiles')
          .first;
      low ??= row['lo'] is int ? row['lo'] as int : null;
      high ??= row['hi'] is int ? row['hi'] as int : null;
    } catch (_) {
      // Leave the defaults below.
    }
  }
  return (low ?? 0, high ?? 14);
}
