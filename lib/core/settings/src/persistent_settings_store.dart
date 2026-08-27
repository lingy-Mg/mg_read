import 'dart:io';

import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/persistence/persistence.dart';

import 'settings_registry.dart';
import 'settings_store.dart';

const _settingsInlinePreparationPolicy = JsonInlinePreparationPolicy(
  maxDocuments: 8,
  maxTotalNodes: 384,
  maxDepth: 8,
  maxCollectionLength: 64,
  maxTotalTextCodeUnits: 12 * 1024,
);

final class PersistentSettingsStore implements SettingsStore {
  PersistentSettingsStore({required this._records, required this.scope, required this._registry, this._closeRecordsOnClose = false});

  final PersistenceRecordStore _records;
  final ScopeKey scope;
  final SettingsRegistry _registry;
  final bool _closeRecordsOnClose;

  static Future<PersistentSettingsStore> open({
    required Directory dataRoot,
    required ScopeKey scope,
    required SettingsRegistry registry,
    DiagnosticsManager? diagnostics,
  }) async {
    final records = await PersistenceRecordStore.open(
      dataRoot: dataRoot,
      registry: RecordDocumentRegistry(settingsRecordDocumentCodecs(registry, scopeKind: scope.kind)),
      diagnostics: diagnostics,
    );
    return PersistentSettingsStore(records: records, scope: scope, registry: registry, closeRecordsOnClose: true);
  }

  @override
  Future<List<SettingsDocument>> loadAll(Iterable<SettingsDocumentDefinition> documents) async {
    final requested = List<SettingsDocumentDefinition>.of(documents);
    for (final definition in requested) {
      final registered = _registry.requireDocument(definition.kind);
      if (registered.id != definition.id) {
        throw const SettingsStoreFailure('unregistered_document');
      }
    }
    final batch = await _records.readMany(ids: requested.map((document) => document.id), scope: scope);
    final output = <SettingsDocument>[];
    for (final definition in requested) {
      final failure = batch.failures[definition.id];
      if (failure != null) {
        output.add(
          SettingsDocument(
            id: definition.id,
            kind: definition.kind,
            values: const {},
            problem: failure is PersistenceFutureVersionError ? SettingsDocumentProblem.futureVersion : SettingsDocumentProblem.corruption,
          ),
        );
        continue;
      }
      final record = batch.records[definition.id];
      if (record == null) {
        continue;
      }
      if (record.recordKind != definition.kind) {
        output.add(
          SettingsDocument(id: definition.id, kind: definition.kind, values: const {}, problem: SettingsDocumentProblem.corruption),
        );
        continue;
      }
      output.add(SettingsDocument(id: definition.id, kind: definition.kind, values: record.document, revision: record.revision));
    }
    return output;
  }

  @override
  Future<List<SettingsDocument>> writeAll(List<SettingsDocument> documents) async {
    for (final document in documents) {
      final definition = _registry.requireDocument(document.kind);
      if (definition.id != document.id || document.readOnly) {
        throw const SettingsStoreFailure('read_only_document');
      }
    }
    try {
      final results = await _records.writeDocumentsCas([
        for (final document in documents)
          RecordDocumentWrite(
            id: document.id,
            recordKind: document.kind,
            scope: scope,
            expectedRevision: document.revision,
            document: Map<String, Object?>.of(document.values),
          ),
      ]);
      final byId = {for (final result in results) result.id: result};
      return [
        for (final document in documents)
          SettingsDocument(
            id: document.id,
            kind: document.kind,
            values: byId[document.id]!.document,
            revision: byId[document.id]!.revision,
          ),
      ];
    } on PersistenceConflictError {
      throw const SettingsStoreConflict();
    } on PersistenceError catch (error) {
      throw SettingsStoreFailure(error.code);
    }
  }

  @override
  Future<void> close() async {
    if (_closeRecordsOnClose) {
      await _records.close();
    }
  }
}

Iterable<RecordDocumentCodec> settingsRecordDocumentCodecs(SettingsRegistry registry, {required String scopeKind}) sync* {
  for (final definition in registry.documents.values) {
    yield RecordDocumentCodec(
      recordKind: definition.kind,
      scopeKind: scopeKind,
      currentVersion: definition.currentVersion,
      validators: {
        for (var version = 1; version <= definition.currentVersion; version++)
          version: (document) {
            definition.validators[version]?.call(document);
          },
      },
      upgraders: {for (final entry in definition.upgraders.entries) entry.key: (document) => entry.value(document)},
      inlinePreparationPolicy: _settingsInlinePreparationPolicy,
      limits: const JsonDocumentLimits(
        maxEncodedBytes: settingsDocumentMaxEncodedBytes,
        maxDepth: settingsDocumentMaxDepth,
        maxKeys: settingsDocumentMaxKeys,
        maxNodes: settingsDocumentMaxNodes,
        maxArrayLength: settingsDocumentMaxArrayLength,
        maxStringLength: settingsDocumentMaxStringLength,
        forbiddenKeyTokens: forbiddenSettingsJsonKeyTokens,
      ),
    );
  }
}
