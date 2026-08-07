import 'package:flutter/foundation.dart';

/// Minimal logger abstraction so library diagnostics can be surfaced or
/// silenced by the application.
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

  void log(String message) => _log?.call(message);

  void warn(String message) => (_warn ?? _log)?.call(message);
}

class _ConsoleLogger implements Logger {
  const _ConsoleLogger();

  @override
  void Function(String message)? get _log => _print;

  @override
  void Function(String message)? get _warn => (m) => _print('WARN: $m');

  static void _print(String message) {
    if (kDebugMode) debugPrint('[vector_tiles] $message');
  }

  @override
  void log(String message) => _log?.call(message);

  @override
  void warn(String message) => _warn?.call(message);
}
