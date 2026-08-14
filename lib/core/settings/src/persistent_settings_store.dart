import 'package:mg_read/core/persistence/persistence.dart';

import 'settings_store.dart';

final class PersistentSettingsStore implements SettingsStore {
  PersistentSettingsStore({
    required PersistenceRecordStore records,
    required this.scope,
  }) : _records = records;
  final PersistenceRecordStore _records;
  final ScopeKey scope;
  static const _prefix = 'app-settings:';
  @override
  Future<List<SettingsDocument>> loadAll(Iterable<String> documentKinds) async {
    final output = <SettingsDocument>[];
    for (final kind in documentKinds) {
      try {
        final record = await _records.read(id: '$_prefix$kind', scope: scope);
        if (record != null)
          output.add(
            SettingsDocument(
              kind: kind,
              values: record.document,
              revision: record.revision,
            ),
          );
      } on PersistenceFutureVersionError {
        output.add(
          SettingsDocument(kind: kind, values: const {}, readOnly: true),
        );
      } on PersistenceCorruptionError {
        output.add(
          SettingsDocument(kind: kind, values: const {}, readOnly: true),
        );
      }
    }
    return output;
  }

  @override
  Future<void> writeAll(List<SettingsDocument> documents) =>
      _records.transaction(() async {
        for (final document in documents) {
          if (document.readOnly)
            throw StateError(
              'A future or corrupt settings document is read-only.',
            );
          final id = '$_prefix${document.kind}';
          final existing = await _records.read(id: id, scope: scope);
          if (existing == null) {
            await _records.create(
              RecordDraft(
                id: id,
                recordKind: document.kind,
                scope: scope,
                document: Map.of(document.values),
              ),
            );
          } else {
            await _records.update(
              previous: existing,
              document: Map.of(document.values),
            );
          }
        }
      });
  @override
  Future<void> close() async {}
}
