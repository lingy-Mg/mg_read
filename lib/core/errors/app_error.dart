/// Stable error codes shared by Flutter application layers and future protocol
/// adapters. Unknown wire values deliberately collapse to [internal].
enum AppErrorCode {
  runtimeUnavailable('runtime_unavailable', false),
  runtimeStartFailed('runtime_start_failed', false),
  runtimeNotReady('runtime_not_ready', true),
  transportDisconnected('transport_disconnected', false),
  versionIncompatible('version_incompatible', false),
  pluginNotFound('plugin_not_found', false),
  pluginDisabled('plugin_disabled', false),
  pluginDamaged('plugin_damaged', false),
  pluginExecutionFailed('plugin_execution_failed', false),
  sourceMediaResolutionFailed('source_media_resolution_failed', true),
  methodNotFound('method_not_found', false),
  unsupported('unsupported', false),
  invalidRequest('invalid_request', false),
  fileNameInvalid('file_name_invalid', false),
  fileUnavailable('file_unavailable', false),
  fileUnreadable('file_unreadable', false),
  fileTooLarge('file_too_large', false),
  fileReadFailed('file_read_failed', false),
  pluginInstallFailed('plugin_install_failed', false),
  invalidFormat('invalid_format', false),
  integrityFailed('integrity_failed', false),
  notFound('not_found', false),
  interactionRequired('interaction_required', false),
  rateLimited('rate_limited', true),
  overloaded('overloaded', true),
  timeout('timeout', false),
  cancelled('cancelled', false),
  conflict('conflict', false),
  diskFull('disk_full', true),
  rangeNotSatisfiable('range_not_satisfiable', false),
  internal('internal', false);

  const AppErrorCode(this.wireValue, this.defaultRetryable);

  /// Stable serialized value defined by the public protocol.
  final String wireValue;

  /// Default when a method-specific retry decision is unavailable.
  final bool defaultRetryable;

  /// Converts a received wire value to a known protocol value.
  static AppErrorCode fromWireValue(String wireValue) {
    for (final AppErrorCode value in AppErrorCode.values) {
      if (value.wireValue == wireValue) {
        return value;
      }
    }
    return AppErrorCode.internal;
  }
}

/// UI-level semantic category derived from a stable [AppErrorCode].
enum AppErrorCategory {
  retryableTemporary,
  runtimeUnavailable,
  pluginUnavailable,
  interactionRequired,
  contentUnavailable,
  storagePressure,
  incompatible,
  cancelled,
  unknownSafe,
}

/// A normalized, immutable error shared across application boundaries.
///
/// Stable metadata remains the authority for control flow. [detail] and
/// [location] are optional technical context for diagnostics and local error UI.
final class AppError implements Exception {
  /// Creates a normalized error.
  AppError({required this.code, required this.retryable, this.retryAfter, this.traceId, this.detail, this.location})
    : assert(retryAfter == null || !retryAfter.isNegative);

  /// Creates an error using the protocol default retry rule for [code].
  factory AppError.fromCode(AppErrorCode code, {bool? retryable, Duration? retryAfter, String? traceId, String? detail, String? location}) {
    return AppError(
      code: code,
      retryable: retryable ?? code.defaultRetryable,
      retryAfter: retryAfter,
      traceId: traceId,
      detail: detail,
      location: location,
    );
  }

  /// Creates an error from a protocol code while dropping unknown codes.
  factory AppError.fromWireCode(String wireCode, {bool? retryable, Duration? retryAfter, String? traceId}) {
    return AppError.fromCode(AppErrorCode.fromWireValue(wireCode), retryable: retryable, retryAfter: retryAfter, traceId: traceId);
  }

  /// Normalizes an implementation exception and keeps its message as detail.
  factory AppError.fromUnknown(Object error) {
    if (error case final AppError appError) {
      return appError;
    }
    return AppError.fromCode(AppErrorCode.internal, detail: error.toString());
  }

  /// Stable machine-readable error code.
  final AppErrorCode code;

  /// Whether the current operation may be retried by its caller.
  final bool retryable;

  /// Optional bounded delay requested by the producing layer.
  final Duration? retryAfter;

  /// Optional technical correlation ID.
  final String? traceId;

  /// Optional technical reason. It never controls retry behavior.
  final String? detail;

  /// Optional application-owned operation/stage where the failure surfaced.
  final String? location;

  /// Adds reviewed diagnostic context without changing stable error semantics.
  AppError withContext({String? detail, String? location}) => AppError(
    code: code,
    retryable: retryable,
    retryAfter: retryAfter,
    traceId: traceId,
    detail: detail ?? this.detail,
    location: location ?? this.location,
  );

  /// Maps protocol-level errors to product-level, actionable semantics.
  AppErrorCategory get category {
    return switch (code) {
      AppErrorCode.runtimeUnavailable ||
      AppErrorCode.runtimeStartFailed ||
      AppErrorCode.runtimeNotReady ||
      AppErrorCode.transportDisconnected => AppErrorCategory.runtimeUnavailable,
      AppErrorCode.pluginNotFound || AppErrorCode.pluginDisabled || AppErrorCode.pluginDamaged => AppErrorCategory.pluginUnavailable,
      AppErrorCode.pluginExecutionFailed => AppErrorCategory.unknownSafe,
      AppErrorCode.sourceMediaResolutionFailed => AppErrorCategory.retryableTemporary,
      AppErrorCode.interactionRequired => AppErrorCategory.interactionRequired,
      AppErrorCode.notFound || AppErrorCode.rangeNotSatisfiable => AppErrorCategory.contentUnavailable,
      AppErrorCode.diskFull => AppErrorCategory.storagePressure,
      AppErrorCode.versionIncompatible || AppErrorCode.unsupported => AppErrorCategory.incompatible,
      AppErrorCode.cancelled => AppErrorCategory.cancelled,
      _ when retryable => AppErrorCategory.retryableTemporary,
      _ => AppErrorCategory.unknownSafe,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is AppError &&
        other.code == code &&
        other.retryable == retryable &&
        other.retryAfter == retryAfter &&
        other.traceId == traceId &&
        other.detail == detail &&
        other.location == location;
  }

  @override
  int get hashCode => Object.hash(code, retryable, retryAfter, traceId, detail, location);

  @override
  String toString() {
    final parts = <String>[code.wireValue];
    if (detail != null && detail!.isNotEmpty) parts.add('detail=$detail');
    if (location != null && location!.isNotEmpty) parts.add('location=$location');
    return 'AppError(${parts.join(', ')})';
  }
}
