import 'package:flutter/foundation.dart';
import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

/// Installs process-level Flutter and root-isolate error observation without
/// persisting raw exception text, stack frames, arguments or paths.
final class AppDiagnosticsErrorBoundary {
  AppDiagnosticsErrorBoundary._({
    required this._reporter,
    required this._ownsReporter,
    required this._previousFlutterHandler,
    required this._previousPlatformHandler,
  }) {
    _flutterHandler = _handleFlutterError;
    _platformHandler = _handlePlatformError;
    FlutterError.onError = _flutterHandler;
    PlatformDispatcher.instance.onError = _platformHandler;
  }

  final AppFatalErrorReporter _reporter;
  final bool _ownsReporter;
  final FlutterExceptionHandler? _previousFlutterHandler;
  final bool Function(Object, StackTrace)? _previousPlatformHandler;
  late final FlutterExceptionHandler _flutterHandler;
  late final bool Function(Object, StackTrace) _platformHandler;
  bool _disposed = false;

  static AppDiagnosticsErrorBoundary install(
    DiagnosticsManager diagnostics, {
    AppFatalErrorReporter? fatalReporter,
  }) => AppDiagnosticsErrorBoundary._(
    reporter: fatalReporter ?? AppFatalErrorReporter(diagnostics),
    ownsReporter: fatalReporter == null,
    previousFlutterHandler: FlutterError.onError,
    previousPlatformHandler: PlatformDispatcher.instance.onError,
  );

  void _handleFlutterError(FlutterErrorDetails details) {
    _reporter.reportUnhandled(
      boundary: 'flutter-framework',
      errorCode: 'unhandled_flutter_error',
      stackTrace: details.stack ?? StackTrace.empty,
      fatal: false,
    );
    try {
      _previousFlutterHandler?.call(details);
    } catch (_) {
      // A previous observer cannot re-open the uncaught error path.
    }
  }

  bool _handlePlatformError(Object error, StackTrace stackTrace) {
    _reporter.reportUnhandled(
      boundary: 'platform-dispatcher',
      errorCode: 'unhandled_platform_error',
      stackTrace: stackTrace,
      fatal: true,
    );
    try {
      _previousPlatformHandler?.call(error, stackTrace);
    } catch (_) {
      // A previous observer cannot re-open the uncaught error path.
    }
    return true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(FlutterError.onError, _flutterHandler)) {
      FlutterError.onError = _previousFlutterHandler;
    }
    if (identical(PlatformDispatcher.instance.onError, _platformHandler)) {
      PlatformDispatcher.instance.onError = _previousPlatformHandler;
    }
    if (_ownsReporter) _reporter.dispose();
  }
}
