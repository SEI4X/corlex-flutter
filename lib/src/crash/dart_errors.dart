import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../client.dart';
import '../limits.dart';
import 'dart_stack.dart';
import 'privacy.dart';

/// Dart errors as `corlex.crash`: `FlutterError.onError` (framework errors: build, layout, gestures)
/// and `PlatformDispatcher.instance.onError` (uncaught async errors). The previous handlers are
/// called afterwards, so the console dump, Crashlytics or Sentry installed before keep working.
///
/// The event follows the JS shape of the contract: `kind: "js"`, `fatal: false`, frames
/// `{fn, file, line, col}`, plus `runtime: "dart"`. The process does not die, so these errors do not
/// count against crash-free users. See the README for why there is no `kind: "dart"`.
///
/// Frequency: the same error is sent once per launch, at most 5 a minute and 20 a launch.
class DartErrorCapture {
  DartErrorCapture(this._client, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  static const int _perMinute = 5;
  static const int _perSession = 20;

  final CorlexClient _client;
  final DateTime Function() _now;
  final Set<String> _seen = {};
  final List<DateTime> _recent = [];
  int _sent = 0;
  FlutterExceptionHandler? _previousFlutter;
  ui.ErrorCallback? _previousPlatform;
  FlutterExceptionHandler? _flutterHandler;
  ui.ErrorCallback? _platformHandler;

  void install() {
    if (_flutterHandler != null) return;
    _previousFlutter = FlutterError.onError;
    _flutterHandler = (FlutterErrorDetails details) {
      record(details.exception, details.stack, source: 'global_handler');
      _previousFlutter?.call(details);
    };
    FlutterError.onError = _flutterHandler;
    final dispatcher = ui.PlatformDispatcher.instance;
    _previousPlatform = dispatcher.onError;
    _platformHandler = (Object error, StackTrace stack) {
      record(error, stack, source: 'unhandled_rejection');
      return _previousPlatform?.call(error, stack) ?? false;
    };
    dispatcher.onError = _platformHandler;
  }

  /// Puts the previous handlers back, where ours are still the current ones.
  void uninstall() {
    if (identical(FlutterError.onError, _flutterHandler)) {
      FlutterError.onError = _previousFlutter;
    }
    final dispatcher = ui.PlatformDispatcher.instance;
    if (identical(dispatcher.onError, _platformHandler)) {
      dispatcher.onError = _previousPlatform;
    }
    _flutterHandler = null;
    _platformHandler = null;
  }

  /// Reports an error. Never throws: a failing reporter must not replace the error it reports.
  /// Also the entry point of `Corlex.recordError`.
  void record(Object error, StackTrace? stack,
      {required String source, bool fatal = false}) {
    try {
      final frames = parseDartStack(stack?.toString());
      final name = errorType(error.runtimeType.toString());
      if (!_allowed(name, frames)) return;
      final crashId = newUuid();
      _client.capture(
        eventCrash,
        {
          'crash_id': crashId,
          'kind': 'js',
          'runtime': 'dart',
          'fatal': fatal,
          'name': truncateBytes(name, 128),
          'message': _client.options.captureErrorMessages
              ? scrubMessage(_messageOf(error))
              : 'Error details omitted',
          'source': source,
          'frames': frames,
          'symbolicated': false,
        },
        CaptureMeta(eventId: crashId),
      );
    } on Object {
      // Nothing to do: the app's own error handling goes on.
    }
  }

  static String _messageOf(Object error) {
    try {
      return error is FlutterError ? error.message : error.toString();
    } on Object {
      return '';
    }
  }

  bool _allowed(String name, List<Map<String, Object?>> frames) {
    final top =
        frames.isEmpty ? '' : '${frames.first['file']}:${frames.first['line']}';
    final signature = '$name|$top';
    if (_seen.contains(signature)) return false;
    final now = _now();
    _recent.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_recent.length >= _perMinute || _sent >= _perSession) return false;
    _seen.add(signature);
    _recent.add(now);
    _sent += 1;
    return true;
  }
}
