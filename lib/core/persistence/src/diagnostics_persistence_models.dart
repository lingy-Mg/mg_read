part of 'diagnostics_persistence.dart';

final class DiagnosticStoredCaptureSession {
  DiagnosticStoredCaptureSession({
    required this.session,
    required this.maxStoredBytes,
    required Set<String> components,
    required Set<String> origins,
    required this.isDefault,
    required this.detailStorage,
  }) : components = Set<String>.unmodifiable(components),
       origins = Set<String>.unmodifiable(origins);

  final DiagnosticSession session;
  final int maxStoredBytes;
  final Set<String> components;
  final Set<String> origins;
  final bool isDefault;
  final DiagnosticDetailStorage detailStorage;

  int get remainingBytes {
    final remaining = maxStoredBytes - session.storedBytes;
    return remaining > 0 ? remaining : 0;
  }
}

final class DiagnosticCommittedAttachment {
  const DiagnosticCommittedAttachment({required this.descriptor, required this.objectKey});

  final DiagnosticAttachmentDescriptor descriptor;

  /// Opaque internal detail key. The legacy name remains private to this
  /// package so callers cannot infer a filesystem path.
  final String? objectKey;
}
