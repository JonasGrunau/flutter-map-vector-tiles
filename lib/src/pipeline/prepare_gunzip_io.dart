import 'dart:io';
import 'dart:typed_data';

/// Inflates gzip-compressed tile bytes synchronously. Runs inside the
/// worker isolate (or the inline fallback), where blocking is fine —
/// this is exactly the work moved off the UI isolate: PMTiles providers
/// hand compressed blobs through on native platforms.
///
/// Non-gzip bytes pass through untouched. The sniff is unambiguous: a
/// valid MVT tile starts with 0x1a (layer field), never 0x1f 0x8b.
Uint8List maybeGunzip(Uint8List bytes) {
  if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) return bytes;
  final decoded = gzip.decode(bytes);
  return decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
}
