import 'dart:js_interop';
import 'dart:typed_data';

/// Web gunzip via the browser's native `DecompressionStream` (available
/// in all browsers that run Flutter web). The stream is drained through
/// a `Response`, which buffers it into a single `ArrayBuffer`.
Future<Uint8List> gunzip(Uint8List bytes) async {
  final stream = _Blob([bytes.toJS].toJS)
      .stream()
      .pipeThrough(_DecompressionStream('gzip'));
  final buffer = await _Response(stream).arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> blobParts);
  external _ReadableStream stream();
}

@JS('DecompressionStream')
extension type _DecompressionStream._(JSObject _) implements JSObject {
  external factory _DecompressionStream(String format);
}

@JS('Response')
extension type _Response._(JSObject _) implements JSObject {
  external factory _Response(_ReadableStream body);
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('ReadableStream')
extension type _ReadableStream._(JSObject _) implements JSObject {
  external _ReadableStream pipeThrough(JSObject transform);
}
