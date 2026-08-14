import 'dart:collection';

import 'setting_key.dart';

enum SettingsState { loading, ready, degraded, failed, closing, closed }

enum SettingsChangeSource { application, backgroundIsolate, conflictMerge }

final class SettingsChangeEvent {
  SettingsChangeEvent({
    required this.snapshot,
    required Iterable<String> changedKeyIds,
    required this.source,
    required this.changedAtUtc,
  }) : changedKeyIds = UnmodifiableSetView(changedKeyIds.toSet());

  final SettingsSnapshot snapshot;
  final Set<String> changedKeyIds;
  final SettingsChangeSource source;
  final DateTime changedAtUtc;
}

final class SettingsDocumentStatus {
  const SettingsDocumentStatus({
    required this.kind,
    required this.dirty,
    required this.persisted,
    required this.degraded,
    required this.readOnly,
    required this.inFlight,
    required this.revision,
    required this.generation,
    required this.persistedGeneration,
    required this.retryCount,
    required this.lastErrorCode,
  });

  final String kind;
  final bool dirty;
  final bool persisted;
  final bool degraded;
  final bool readOnly;
  final bool inFlight;
  final int? revision;
  final int generation;
  final int persistedGeneration;
  final int retryCount;
  final String? lastErrorCode;
}

final class SettingsStatus {
  SettingsStatus({
    required this.state,
    required Map<String, SettingsDocumentStatus> documents,
    required this.updatedAtUtc,
    this.lastErrorCode,
  }) : documents = UnmodifiableMapView(Map.of(documents));

  final SettingsState state;
  final Map<String, SettingsDocumentStatus> documents;
  final DateTime updatedAtUtc;
  final String? lastErrorCode;

  bool get isDirty => documents.values.any((document) => document.dirty);
  bool get isPersisted =>
      state != SettingsState.loading &&
      state != SettingsState.failed &&
      documents.values.every((document) => document.persisted);
  bool get isDegraded =>
      state == SettingsState.degraded ||
      state == SettingsState.failed ||
      documents.values.any((document) => document.degraded);

  Set<String> get dirtyDocumentKinds => UnmodifiableSetView({
    for (final document in documents.values)
      if (document.dirty) document.kind,
  });

  Set<String> get degradedDocumentKinds => UnmodifiableSetView({
    for (final document in documents.values)
      if (document.degraded) document.kind,
  });
}

final class SettingsFlushResult {
  const SettingsFlushResult({
    required this.persisted,
    required this.dirtyDocumentKinds,
    required this.degradedDocumentKinds,
  });

  final bool persisted;
  final Set<String> dirtyDocumentKinds;
  final Set<String> degradedDocumentKinds;
}
