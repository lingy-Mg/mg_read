import 'dart:collection';

import 'diagnostic_event.dart';
import 'diagnostic_value.dart';

enum DiagnosticSessionState { active, ended, expired, deleting, deleted }

final class DiagnosticSession {
  DiagnosticSession({
    required this.sessionId,
    required this.source,
    required this.sourceRunId,
    required this.startedAtUtcMicros,
    required this.state,
    required this.payloadKind,
    required this.eventCount,
    required this.attachmentCount,
    required this.storedBytes,
    this.endedAtUtcMicros,
    this.expiresAtUtcMicros,
  }) {
    validateDiagnosticOpaqueId(sessionId, 'sessionId');
    validateDiagnosticOpaqueId(sourceRunId, 'sourceRunId');
  }

  final String sessionId;
  final DiagnosticSource source;
  final String sourceRunId;
  final int startedAtUtcMicros;
  final int? endedAtUtcMicros;
  final int? expiresAtUtcMicros;
  final DiagnosticSessionState state;
  final DiagnosticPayloadKind payloadKind;
  final int eventCount;
  final int attachmentCount;
  final int storedBytes;
}

final class DiagnosticCursor {
  DiagnosticCursor(this.value) {
    if (!_cursorPattern.hasMatch(value)) {
      throw ArgumentError.value(value, 'value', 'Invalid opaque cursor.');
    }
  }

  final String value;

  static final RegExp _cursorPattern = RegExp(r'^[A-Za-z0-9_-]{8,512}$');
}

final class DiagnosticPage<T> {
  DiagnosticPage({required Iterable<T> items, this.nextCursor})
    : items = List<T>.unmodifiable(items);

  final List<T> items;
  final DiagnosticCursor? nextCursor;
}

final class DiagnosticSessionFilter {
  const DiagnosticSessionFilter({
    this.sources = const <DiagnosticSource>{},
    this.states = const <DiagnosticSessionState>{},
    this.startedAfterUtcMicros,
    this.startedBeforeUtcMicros,
  });

  final Set<DiagnosticSource> sources;
  final Set<DiagnosticSessionState> states;
  final int? startedAfterUtcMicros;
  final int? startedBeforeUtcMicros;
}

final class DiagnosticEventFilter {
  DiagnosticEventFilter({
    this.sessionId,
    this.traceId,
    this.minimumSeverity,
    Set<String> components = const <String>{},
    Set<String> eventNames = const <String>{},
    this.occurredAfterUtcMicros,
    this.occurredBeforeUtcMicros,
  }) : components = Set<String>.unmodifiable(components),
       eventNames = Set<String>.unmodifiable(eventNames) {
    if (sessionId case final value?) {
      validateDiagnosticOpaqueId(value, 'sessionId');
    }
    if (traceId case final value?) validateDiagnosticOpaqueId(value, 'traceId');
    for (final component in components) {
      validateDiagnosticName(component, 'component');
    }
    for (final eventName in eventNames) {
      validateDiagnosticName(eventName, 'eventName');
    }
  }

  final String? sessionId;
  final String? traceId;
  final DiagnosticSeverity? minimumSeverity;
  final Set<String> components;
  final Set<String> eventNames;
  final int? occurredAfterUtcMicros;
  final int? occurredBeforeUtcMicros;
}

final class DiagnosticAttachmentDescriptor {
  DiagnosticAttachmentDescriptor({
    required this.attachmentId,
    required this.eventId,
    required this.kind,
    required this.mediaType,
    required this.formatId,
    required this.formatVersion,
    required this.privacyClass,
    required this.captureState,
    required this.rawByteLength,
    required this.storedByteLength,
    required this.storageCodec,
    required this.redactionVersion,
    this.charset,
    this.schemaId,
    this.schemaVersion,
    this.sha256,
    this.truncationReason,
  }) {
    validateDiagnosticOpaqueId(attachmentId, 'attachmentId');
    validateDiagnosticOpaqueId(eventId, 'eventId');
    validateDiagnosticName(kind, 'kind');
    validateDiagnosticName(formatId, 'formatId');
    if (formatVersion <= 0 ||
        rawByteLength < 0 ||
        storedByteLength < 0 ||
        redactionVersion <= 0 ||
        (schemaVersion != null && schemaVersion! <= 0)) {
      throw ArgumentError('Invalid diagnostic attachment descriptor.');
    }
    if (sha256 != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256!)) {
      throw ArgumentError.value(sha256, 'sha256');
    }
  }

  final String attachmentId;
  final String eventId;
  final String kind;
  final String mediaType;
  final String? charset;
  final String formatId;
  final int formatVersion;
  final String? schemaId;
  final int? schemaVersion;
  final DiagnosticPrivacyClass privacyClass;
  final DiagnosticCaptureState captureState;
  final int rawByteLength;
  final int storedByteLength;
  final String? sha256;
  final DiagnosticStorageCodec storageCodec;
  final int redactionVersion;
  final String? truncationReason;
}

final class DiagnosticByteRange {
  DiagnosticByteRange({required this.offset, required this.length}) {
    if (offset < 0 || length <= 0) {
      throw ArgumentError(
        'Attachment range must be non-negative and non-empty.',
      );
    }
  }

  final int offset;
  final int length;
}

enum DiagnosticStructuredNodeKind {
  scalar,
  object,
  list,
  reference,
  dateTime,
  int64,
  nonFinite,
  attachment,
  redacted,
  truncated,
  unsupported,
}

final class DiagnosticStructuredNode {
  DiagnosticStructuredNode({
    required this.path,
    required this.kind,
    required this.displayName,
    this.scalarPreview,
    this.childCount,
    this.nodeId,
    this.referenceNodeId,
  });

  final String path;
  final DiagnosticStructuredNodeKind kind;
  final String displayName;
  final String? scalarPreview;
  final int? childCount;
  final String? nodeId;
  final String? referenceNodeId;
}

abstract interface class DiagnosticsQuery {
  Future<DiagnosticPage<DiagnosticSession>> listSessions({
    DiagnosticSessionFilter filter = const DiagnosticSessionFilter(),
    DiagnosticCursor? cursor,
    int limit = 100,
  });

  Future<DiagnosticPage<DiagnosticEvent>> listEvents({
    required DiagnosticEventFilter filter,
    DiagnosticCursor? cursor,
    int limit = 100,
  });

  Future<DiagnosticEvent?> getEvent(String eventId);

  Future<List<DiagnosticAttachmentDescriptor>> listAttachments(String eventId);

  Stream<List<int>> openAttachment(
    String attachmentId, {
    DiagnosticByteRange? range,
  });

  Future<DiagnosticPage<DiagnosticStructuredNode>> listStructuredNodes(
    String attachmentId, {
    required String path,
    DiagnosticCursor? cursor,
    int limit = 100,
  });
}

final class DiagnosticCapturePolicy {
  DiagnosticCapturePolicy({
    required this.payloadKind,
    required this.duration,
    required this.maxStoredBytes,
    Set<String> components = const <String>{},
    Set<String> origins = const <String>{},
  }) : components = Set<String>.unmodifiable(components),
       origins = Set<String>.unmodifiable(origins) {
    if (duration <= Duration.zero || maxStoredBytes <= 0) {
      throw ArgumentError('Capture duration and byte quota must be positive.');
    }
    if (payloadKind != DiagnosticPayloadKind.metadataOnly &&
        components.isEmpty &&
        origins.isEmpty) {
      throw ArgumentError(
        'Payload capture needs a component or origin allowlist.',
      );
    }
    for (final component in components) {
      validateDiagnosticName(component, 'component');
    }
    for (final origin in origins) {
      final uri = Uri.tryParse(origin);
      if (uri == null ||
          !uri.hasScheme ||
          uri.host.isEmpty ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          uri.userInfo.isNotEmpty) {
        throw ArgumentError.value(origin, 'origins', 'Origin only is allowed.');
      }
    }
  }

  final DiagnosticPayloadKind payloadKind;
  final Duration duration;
  final int maxStoredBytes;
  final Set<String> components;
  final Set<String> origins;
}

abstract interface class DiagnosticsCapture {
  Future<DiagnosticSession> startCapture(DiagnosticCapturePolicy policy);

  Future<void> stopCapture(String sessionId);

  Future<DiagnosticAttachmentDescriptor> captureAttachment({
    required String eventId,
    required String kind,
    required String mediaType,
    required String formatId,
    required int formatVersion,
    required DiagnosticPrivacyClass privacyClass,
    required Stream<List<int>> bytes,
    String? charset,
    String? schemaId,
    int? schemaVersion,
  });
}

final class DiagnosticRetentionPolicy {
  const DiagnosticRetentionPolicy({
    this.regularEventAge = const Duration(days: 3),
    this.regularEventBytes = 32 * 1024 * 1024,
    this.captureAge = const Duration(hours: 24),
    this.captureBytes = 256 * 1024 * 1024,
    this.globalHardBytes = 512 * 1024 * 1024,
    this.singleAttachmentBytes = 16 * 1024 * 1024,
  });

  final Duration regularEventAge;
  final int regularEventBytes;
  final Duration captureAge;
  final int captureBytes;
  final int globalHardBytes;
  final int singleAttachmentBytes;
}

final class DiagnosticMaintenanceResult {
  const DiagnosticMaintenanceResult({
    required this.deletedSessions,
    required this.deletedEvents,
    required this.deletedObjects,
    required this.reclaimedBytes,
  });

  final int deletedSessions;
  final int deletedEvents;
  final int deletedObjects;
  final int reclaimedBytes;
}

final class DiagnosticExportSelection {
  DiagnosticExportSelection(Iterable<String> sessionIds)
    : sessionIds = List<String>.unmodifiable(sessionIds) {
    if (this.sessionIds.isEmpty) {
      throw ArgumentError('At least one diagnostic session is required.');
    }
    for (final sessionId in this.sessionIds) {
      validateDiagnosticOpaqueId(sessionId, 'sessionId');
    }
  }

  final List<String> sessionIds;
}

final class DiagnosticExportPolicy {
  const DiagnosticExportPolicy({
    this.includeContentPayload = false,
    this.includeRestrictedRaw = false,
    this.reapplyRedaction = true,
  });

  final bool includeContentPayload;
  final bool includeRestrictedRaw;
  final bool reapplyRedaction;
}

final class DiagnosticExportResult {
  DiagnosticExportResult({
    required this.exportId,
    required this.relativeObjectKey,
    required this.byteLength,
    required this.sessionCount,
    required this.eventCount,
    required this.attachmentCount,
  }) {
    validateDiagnosticOpaqueId(exportId, 'exportId');
    if (relativeObjectKey.startsWith('/') || relativeObjectKey.contains('..')) {
      throw ArgumentError.value(relativeObjectKey, 'relativeObjectKey');
    }
  }

  final String exportId;
  final String relativeObjectKey;
  final int byteLength;
  final int sessionCount;
  final int eventCount;
  final int attachmentCount;
}

abstract interface class DiagnosticsMaintenance {
  Future<DiagnosticMaintenanceResult> enforceRetention(
    DiagnosticRetentionPolicy policy,
  );

  Future<void> deleteSession(String sessionId);

  Future<DiagnosticExportResult> exportBundle({
    required DiagnosticExportSelection selection,
    required DiagnosticExportPolicy policy,
  });
}

Map<String, DiagnosticValue> immutableDiagnosticValues(
  Map<String, DiagnosticValue> values,
) => UnmodifiableMapView<String, DiagnosticValue>(values);
