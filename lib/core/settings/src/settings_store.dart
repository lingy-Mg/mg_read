import 'dart:collection';

final class SettingsDocument {
  SettingsDocument({
    required this.kind,
    required Map<String, Object?> values,
    this.revision,
    this.readOnly = false,
  }) : values = UnmodifiableMapView(values);
  final String kind;
  final Map<String, Object?> values;
  final int? revision;
  final bool readOnly;
}

abstract interface class SettingsStore {
  Future<List<SettingsDocument>> loadAll(Iterable<String> documentKinds);
  Future<void> writeAll(List<SettingsDocument> documents);
  Future<void> close();
}
