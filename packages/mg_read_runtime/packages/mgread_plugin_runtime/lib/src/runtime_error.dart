part of mgread_plugin_runtime;

/// Severity of a Runtime diagnostic projected to Flutter.
///
/// Diagnostics contain stable codes and bounded text.
enum RuntimeDiagnosticLevel {
  /// Informational lifecycle detail that does not prevent Runtime operation.
  info,

  /// Recoverable or degraded condition that callers may choose to display.
  warning,

  /// Startup or lifecycle failure that prevents the requested operation.
  error,

  /// A terminal Runtime failure. The next Facade invocation may perform one
  /// orderly cold restart; callers can surface global fatal UI immediately.
  fatal,
}

/// A Runtime-owned diagnostic record.
///
/// The Facade exposes this type so Flutter can present actionable startup and
/// lifecycle failures without taking ownership of the underlying launcher or
/// transport.
@immutable
final class RuntimeDiagnostic {
  const RuntimeDiagnostic({
    required this.code,
    required this.level,
    required this.message,
  });

  /// Stable machine-readable code used for UI state and support workflows.
  final String code;

  /// Severity assigned by the Runtime-owned supervisor.
  final RuntimeDiagnosticLevel level;

  /// Bounded text suitable for direct user-visible diagnostics.
  final String message;

  /// Whether this record represents a terminal Runtime lifecycle failure.
  bool get isFatal => level == RuntimeDiagnosticLevel.fatal;
}

/// A stable Runtime failure exposed by the Flutter-facing Facade.
///
/// [diagnostics] is an immutable point-in-time snapshot collected before this
/// exception was surfaced. Flutter callers remain decoupled from Runtime
/// internals.
@immutable
final class PluginRuntimeException implements Exception {
  const PluginRuntimeException(
    this.code,
    this.message, {
    this.diagnostics = const <RuntimeDiagnostic>[],
  });

  /// Stable Runtime-owned failure code for programmatic handling.
  final String code;

  /// Bounded immutable diagnostic context available at the time of failure.
  final List<RuntimeDiagnostic> diagnostics;

  /// Summary suitable for logs and user-facing error state.
  final String message;

  @override
  String toString() => 'PluginRuntimeException($code): $message';
}
