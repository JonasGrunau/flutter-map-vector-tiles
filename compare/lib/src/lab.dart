import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// What the lab server says about a run's network traffic so far.
class NetSnapshot {
  NetSnapshot(Map<String, dynamic> json)
      : requests = json['requests'] as int,
        bytes = json['bytes'] as int,
        inflight = json['inflight'] as int,
        idleMs = json['idleMs'] as int;

  final int requests;
  final int bytes;
  final int inflight;
  final int idleMs;
}

/// The run the lab server handed out.
class LabRun {
  LabRun(Map<String, dynamic> json)
      : id = json['run'] as String,
        arm = json['arm'] as String,
        round = json['round'] as int,
        scenarios = (json['scenarios'] as String?)?.split(',');

  final String id;
  final String arm;
  final int round;
  final List<String>? scenarios;
}

/// Client for `tool/lab_server.dart`.
class Lab {
  Lab(this.base);

  final String base;
  final _client = http.Client();

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await _client.get(Uri.parse('$base$path'));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// The next queued run, or null when the queue is empty.
  Future<LabRun?> next() async {
    final json = await _get('/_next');
    return json['done'] == true ? null : LabRun(json);
  }

  Future<NetSnapshot> net(String run) async =>
      NetSnapshot(await _get('/_net?run=${Uri.encodeQueryComponent(run)}'));

  Future<void> result(Map<String, Object?> json) =>
      _client.post(Uri.parse('$base/_result'), body: jsonEncode(json));

  Future<void> shot(String name, Uint8List png) => _client.post(
        Uri.parse('$base/_shot?name=${Uri.encodeQueryComponent(name)}'),
        body: png,
      );

  Future<void> done(String run) => _client
      .post(Uri.parse('$base/_done?run=${Uri.encodeQueryComponent(run)}'));

  /// Prints [message] in the lab server's console. Naming the [run] also
  /// tells the server the run is alive (its inactivity timeout).
  Future<void> log(String? run, String message) => _client.post(
        Uri.parse('$base/_log?run=${Uri.encodeQueryComponent(run ?? '-')}'),
        body: message,
      );
}
