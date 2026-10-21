import 'package:flutter/foundation.dart';

import 'core/redact.dart';

/// Minimal logger abstraction so library diagnostics can be surfaced or
/// silenced by the application.
///
/// Messages arrive with API keys redacted: the value of every `key`,
/// `apikey`, `api_key`, `access_token` and `token` query parameter in a URL
/// is replaced with `***` (`style.json?key=***`), whichever part of the
/// package logs it, so warnings can be forwarded to a crash reporter as
/// they are.
class Logger {
  final void Function(String message)? _log;
  final void Function(String message)? _warn;

  const Logger.custom({
    void Function(String message)? onLog,
    void Function(String message)? onWarn,
  })  : _log = onLog,
        _warn = onWarn;

  const Logger.noop()
      : _log = null,
        _warn = null;

  const factory Logger.console() = _ConsoleLogger;

  void log(String message) => _log?.call(redactKeys(message));

  void warn(String message) => (_warn ?? _log)?.call(redactKeys(message));
}

class _ConsoleLogger implements Logger {
  const _ConsoleLogger();

  @override
  void Function(String message)? get _log => _print;

  @override
  void Function(String message)? get _warn => (m) => _print('WARN: $m');

  static void _print(String message) {
    if (kDebugMode) debugPrint('[vector_tiles] ${redactKeys(message)}');
  }

  @override
  void log(String message) => _log?.call(message);

  @override
  void warn(String message) => _warn?.call(message);
}
