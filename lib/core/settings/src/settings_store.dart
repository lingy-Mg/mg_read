import 'dart:collection';

import 'settings_registry.dart';

enum SettingsDocumentProblem { futureVersion, corruption }

final class SettingsDocument {
  SettingsDocument({
    required this.id,
    required this.kind,
    required Map<String, Object?> values,
    this.revision,
    this.problem,
  }) : values = UnmodifiableMapView(_copyJsonObject(values));

  final String id;
  final String kind;
  final Map<String, Object?> values;
  final int? revision;
  final SettingsDocumentProblem? problem;

  bool get readOnly => problem != null;
}

sealed class SettingsStoreException implements Exception {
  const SettingsStoreException(this.code);

  final String code;

  @override
  String toString() => 'SettingsStoreException($code)';
}

final class SettingsStoreConflict extends SettingsStoreException {
  const SettingsStoreConflict() : super('revision_conflict');
}

final class SettingsStoreFailure extends SettingsStoreException {
  const SettingsStoreFailure(super.code);
}

abstract interface class SettingsStore {
  Future<List<SettingsDocument>> loadAll(
    Iterable<SettingsDocumentDefinition> documents,
  );

  /// Atomically writes the supplied document groups using each baseline
  /// revision. A conflict rolls back the complete batch.
  Future<List<SettingsDocument>> writeAll(List<SettingsDocument> documents);

  Future<void> close();
}

Map<String, Object?> _copyJsonObject(Map<String, Object?> value) => {
  for (final entry in value.entries) entry.key: _copyJson(entry.value),
};

Object? _copyJson(Object? value) {
  if (value is Map) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw ArgumentError('Settings document keys must be strings.');
      }
      result[entry.key as String] = _copyJson(entry.value);
    }
    return UnmodifiableMapView(result);
  }
  if (value is List) {
    return UnmodifiableListView(value.map(_copyJson));
  }
  return value;
}
