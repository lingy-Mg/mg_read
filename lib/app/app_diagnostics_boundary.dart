import 'package:flutter/foundation.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

/// Installs process-level Flutter and root-isolate error observation without
/// persisting raw exception text, stack frames, arguments or paths.
final class AppDiagnosticsErrorBoundary {
  AppDiagnosticsErrorBoundary._({
    required this._diagnostics,
    required this._previousFlutterHandler,
    required this._previousPlatformHandler,
  }) {
    _flutterHandler = _handleFlutterError;
    _platformHandler = _handlePlatformError;
    FlutterError.onError = _flutterHandler;
    PlatformDispatcher.instance.onError = _platformHandler;
  }

  final DiagnosticsManager _diagnostics;
  final FlutterExceptionHandler? _previousFlutterHandler;
  final bool Function(Object, StackTrace)? _previousPlatformHandler;
  late final FlutterExceptionHandler _flutterHandler;
  late final bool Function(Object, StackTrace) _platformHandler;
  bool _disposed = false;

  static AppDiagnosticsErrorBoundary install(DiagnosticsManager diagnostics) =>
      AppDiagnosticsErrorBoundary._(
        diagnostics: diagnostics,
        previousFlutterHandler: FlutterError.onError,
        previousPlatformHandler: PlatformDispatcher.instance.onError,
      );

  void _handleFlutterError(FlutterErrorDetails details) {
    _emit(
      boundary: 'flutter-framework',
      errorCode: 'unhandled_flutter_error',
      stackTrace: details.stack ?? StackTrace.empty,
      fatal: false,
    );
    _previousFlutterHandler?.call(details);
  }

  bool _handlePlatformError(Object error, StackTrace stackTrace) {
    _emit(
      boundary: 'platform-dispatcher',
      errorCode: 'unhandled_platform_error',
      stackTrace: stackTrace,
      fatal: true,
    );
    return _previousPlatformHandler?.call(error, stackTrace) ?? false;
  }

  void _emit({
    required String boundary,
    required String errorCode,
    required StackTrace stackTrace,
    required bool fatal,
  }) {
    try {
      _diagnostics.emit(
        AppDiagnosticEvents.unhandledError,
        attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
          'boundary': DiagnosticValue.string(boundary),
          'errorCode': DiagnosticValue.string(errorCode),
          'stackFingerprint': DiagnosticValue.string(
            _diagnostics.privacyPolicy.stackFingerprint(stackTrace),
          ),
          'fatal': DiagnosticValue.boolean(fatal),
        }),
      );
    } catch (_) {
      // Diagnostics is fail-open even while handling another failure.
    }
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
  }
}
