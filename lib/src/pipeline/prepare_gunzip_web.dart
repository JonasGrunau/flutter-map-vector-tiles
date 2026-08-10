import 'dart:typed_data';

/// Web never sees compressed tile bytes here: there is no worker
/// isolate to defer to, so PMTiles providers inflate at fetch time (via
/// `DecompressionStream`, which is async) and browsers decode HTTP
/// `Content-Encoding` transparently.
Uint8List maybeGunzip(Uint8List bytes) => bytes;
