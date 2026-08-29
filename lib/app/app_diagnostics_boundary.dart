/// Process-level Flutter and platform error boundary.
///
/// Records the error text and stack supplied by Flutter/platform unchanged.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/app/app_fatal_error_reporter.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

/// Installs process-level Flutter and root-isolate error observation.
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

  static AppDiagnosticsErrorBoundary install(DiagnosticsManager diagnostics, {AppFatalErrorReporter? fatalReporter}) =>
      AppDiagnosticsErrorBoundary._(
        reporter: fatalReporter ?? AppFatalErrorReporter(diagnostics),
        ownsReporter: fatalReporter == null,
        previousFlutterHandler: FlutterError.onError,
        previousPlatformHandler: PlatformDispatcher.instance.onError,
      );

  void _handleFlutterError(FlutterErrorDetails details) {
    _reporter.reportUnhandled(
      boundary: 'flutter-framework',
      errorCode: 'unhandled_flutter_error',
      errorText: details.exception.toString(),
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
      errorCode: _platformErrorCode(error),
      errorText: error.toString(),
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

  String _platformErrorCode(Object error) {
    if (error is PlatformException) {
      final normalized = error.code.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
      if (normalized.isNotEmpty && normalized.length <= 64) {
        return 'platform_$normalized';
      }
    }
    return 'unhandled_platform_error';
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
