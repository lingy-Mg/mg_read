/// 应用设置事务、串行写入、冲突合并、重试与 flush 队列。
///
/// 只拆分既有队列职责；不得改变内存优先或持久化提交语义。
part of 'app_settings_manager.dart';

extension _AppSettingsTransactionQueue on AppSettingsManager {
  void _applyMutations(List<_SettingsMutation> operations, {required SettingsChangeSource source}) {
    if (operations.isEmpty) {
      return;
    }
    final affectedKinds = {for (final operation in operations) operation.documentKind};
    for (final kind in affectedKinds) {
      final document = _documents[kind]!;
      if (document.readOnly) {
        throw SettingsReadOnlyException(kind);
      }
    }

    final raw = <String, Map<String, Object?>>{};
    final decoded = <String, Map<String, Object?>>{};
    final changedByKind = <String, Set<String>>{};
    for (final operation in operations) {
      final kind = operation.documentKind;
      final document = _documents[kind]!;
      final rawGroup = raw.putIfAbsent(kind, () => Map<String, Object?>.of(document.values));
      final decodedGroup = decoded.putIfAbsent(kind, () => Map<String, Object?>.of(document.decodedValues));
      final changed = changedByKind.putIfAbsent(kind, () => <String>{});
      switch (operation) {
        case _SetMutation(:final key, :final value, :final encoded):
          if (!rawGroup.containsKey(key.id) || !_jsonEquals(rawGroup[key.id], encoded)) {
            rawGroup[key.id] = encoded;
            decodedGroup[key.id] = value;
            changed.add(key.id);
          }
        case _ResetMutation(:final key):
          if (rawGroup.remove(key.id) != null || decodedGroup.remove(key.id) != null || document.values.containsKey(key.id)) {
            changed.add(key.id);
          }
        case _ResetGroupMutation(:final documentKind):
          for (final key in _registry.keysForDocument(documentKind)) {
            if (rawGroup.containsKey(key.id) || decodedGroup.containsKey(key.id)) {
              rawGroup.remove(key.id);
              decodedGroup.remove(key.id);
              changed.add(key.id);
            }
          }
      }
    }
    final replacements = <String, Map<String, Object?>>{};
    final changedKeys = <String>{};
    for (final kind in affectedKinds) {
      final changed = changedByKind[kind] ?? const <String>{};
      if (changed.isEmpty) {
        continue;
      }
      validateSettingsEncodedValue(raw[kind]);
      final document = _documents[kind]!;
      document.values = raw[kind]!;
      document.decodedValues = decoded[kind]!;
      document.generation++;
      document.patch = _buildPatch(document.persistedValues, document.values, _registry.keysForDocument(kind));
      if (document.patch.isEmpty) {
        document.persistedGeneration = document.generation;
        document.transientErrorCode = null;
        document.retryCount = 0;
        document.timer?.cancel();
        document.timer = null;
      } else {
        _scheduleDebounce(document);
      }
      replacements[kind] = document.decodedValues;
      changedKeys.addAll(changed);
    }
    if (changedKeys.isEmpty) {
      return;
    }
    _snapshot = _snapshot.replaceGroups(replacements);
    _emitStatus();
    final event = SettingsChangeEvent(snapshot: _snapshot, changedKeyIds: changedKeys, source: source, changedAtUtc: _clock().toUtc());
    if (!_streamsClosed) {
      _changes.add(_snapshot);
      _changeEvents.add(event);
    }
  }

  void _scheduleDebounce(_RuntimeDocument document) {
    document.timer?.cancel();
    document.timer = Timer(_policy.debounce, () {
      document.timer = null;
      _dueKinds.add(document.definition.kind);
      _ensureWorker();
    });
  }

  void _scheduleRetry(_RuntimeDocument document) {
    if (_state == SettingsState.closing || _state == SettingsState.closed) {
      return;
    }
    document.timer?.cancel();
    final multiplier = math.pow(2, math.max(0, document.retryCount - 1));
    final requested = _policy.retryBaseDelay.inMilliseconds * multiplier;
    final milliseconds = math.min(requested.round(), _policy.retryMaxDelay.inMilliseconds);
    document.timer = Timer(Duration(milliseconds: milliseconds), () {
      document.timer = null;
      _dueKinds.add(document.definition.kind);
      _ensureWorker();
    });
  }

  void _ensureWorker() {
    if (_workerScheduled || _state == SettingsState.closed) {
      return;
    }
    _workerScheduled = true;
    _workerTail = _workerTail.then((_) async {
      try {
        await _drainDueWrites();
      } finally {
        _workerScheduled = false;
        if (_dueKinds.isNotEmpty && _state != SettingsState.closed) {
          _ensureWorker();
        }
      }
    });
  }

  Future<void> _drainDueWrites() async {
    while (_dueKinds.isNotEmpty && _state != SettingsState.closed) {
      final kinds = Set<String>.of(_dueKinds);
      _dueKinds.clear();
      await _persistKinds(kinds);
    }
  }

  Future<void> _persistKinds(Set<String> kinds) async {
    var documents = [for (final kind in kinds) _documents[kind]!]..removeWhere((document) => !document.dirty || document.readOnly);
    if (documents.isEmpty || _store == null) {
      return;
    }
    final span = _diagnostics?.startSpan(
      AppDiagnosticEvents.settingsWrite,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'settingKey': DiagnosticValue.string('batch'),
        'documentCount': DiagnosticValue.int64(documents.length),
      }),
    );
    final stopwatch = Stopwatch()..start();
    void report(DiagnosticOutcome outcome) {
      final diagnostics = _diagnostics;
      if (diagnostics == null || span == null) return;
      stopwatch.stop();
      reportSlowDiagnostic(
        diagnostics,
        subjectComponent: 'app.settings',
        operation: 'writeBatch',
        elapsed: stopwatch.elapsed,
        threshold: AppDiagnosticThresholds.settingsWrite,
        outcome: outcome,
        traceContext: span.traceContext,
      );
    }

    for (final document in documents) {
      document.inFlight = true;
    }
    _emitStatus();

    var conflictAttempt = 0;
    while (documents.isNotEmpty) {
      final captures = [for (final document in documents) _capture(document)];
      try {
        final saved = await _store!.writeAll([
          for (final capture in captures)
            SettingsDocument(
              id: capture.document.definition.id,
              kind: capture.document.definition.kind,
              values: capture.values,
              revision: capture.revision,
            ),
        ]);
        final byKind = {for (final document in saved) document.kind: document};
        if (byKind.length != captures.length) {
          throw const SettingsStoreFailure('invalid_write_result');
        }
        for (final capture in captures) {
          final result = byKind[capture.document.definition.kind];
          if (result == null || result.id != capture.document.definition.id || result.revision == null) {
            throw const SettingsStoreFailure('invalid_write_result');
          }
          _applyWriteSuccess(capture, result);
        }
        _emitStatus();
        final revisions = saved.map((document) => document.revision ?? 0).toList(growable: false);
        span?.complete(
          attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
            'settingKey': DiagnosticValue.string('batch'),
            'documentCount': DiagnosticValue.int64(captures.length),
            'attempt': DiagnosticValue.int64(conflictAttempt + 1),
            'revision': DiagnosticValue.int64(revisions.isEmpty ? 0 : revisions.reduce(math.max)),
          }),
        );
        report(DiagnosticOutcome.success);
        return;
      } on SettingsStoreConflict {
        if (conflictAttempt >= _policy.maxConflictRetries) {
          _markWriteFailure(documents, 'revision_conflict');
          span?.fail(
            attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
              'settingKey': DiagnosticValue.string('batch'),
              'documentCount': DiagnosticValue.int64(documents.length),
              'attempt': DiagnosticValue.int64(conflictAttempt + 1),
              'errorCode': DiagnosticValue.string('revision_conflict'),
            }),
          );
          report(DiagnosticOutcome.error);
          return;
        }
        conflictAttempt++;
        try {
          await _reloadAndMerge(documents);
        } catch (error) {
          final errorCode = _safeWriteErrorCode(error);
          _markWriteFailure(documents, errorCode);
          span?.fail(
            attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
              'settingKey': DiagnosticValue.string('batch'),
              'documentCount': DiagnosticValue.int64(documents.length),
              'attempt': DiagnosticValue.int64(conflictAttempt + 1),
              'errorCode': DiagnosticValue.string(errorCode),
            }),
          );
          report(DiagnosticOutcome.error);
          return;
        }
        documents = [
          for (final document in documents)
            if (document.dirty && !document.readOnly) document,
        ];
      } catch (error) {
        final errorCode = _safeWriteErrorCode(error);
        _markWriteFailure(documents, errorCode);
        span?.fail(
          attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
            'settingKey': DiagnosticValue.string('batch'),
            'documentCount': DiagnosticValue.int64(documents.length),
            'attempt': DiagnosticValue.int64(conflictAttempt + 1),
            'errorCode': DiagnosticValue.string(errorCode),
          }),
        );
        report(DiagnosticOutcome.error);
        return;
      }
    }
    for (final document in kinds.map((kind) => _documents[kind]!)) {
      document.inFlight = false;
    }
    _emitStatus();
    span?.complete(
      attributes: DiagnosticObjectValue(<String, DiagnosticValue>{
        'settingKey': DiagnosticValue.string('batch'),
        'documentCount': DiagnosticValue.int64(0),
        'attempt': DiagnosticValue.int64(conflictAttempt + 1),
      }),
    );
    report(DiagnosticOutcome.success);
  }

  _WriteCapture _capture(_RuntimeDocument document) => _WriteCapture(
    document: document,
    generation: document.generation,
    revision: document.revision,
    values: Map<String, Object?>.of(document.values),
  );

  void _applyWriteSuccess(_WriteCapture capture, SettingsDocument result) {
    final document = capture.document;
    final newBase = Map<String, Object?>.of(result.values);
    final remainingPatch = _buildPatch(newBase, document.values, _registry.keysForDocument(document.definition.kind));
    document.revision = result.revision;
    document.persistedValues = newBase;
    document.values = _applyPatch(newBase, remainingPatch);
    document.patch = remainingPatch;
    document.persistedGeneration = remainingPatch.isEmpty
        ? document.generation
        : math.max(document.persistedGeneration, capture.generation);
    document.transientErrorCode = null;
    document.retryCount = 0;
    document.inFlight = false;
    if (remainingPatch.isEmpty) {
      document.timer?.cancel();
      document.timer = null;
    } else if (document.timer == null && !_dueKinds.contains(document.definition.kind)) {
      _scheduleDebounce(document);
    }
  }

  Future<void> _reloadAndMerge(List<_RuntimeDocument> documents) async {
    final loaded = await _store!.loadAll([for (final document in documents) document.definition]);
    final byKind = {for (final document in loaded) document.kind: document};
    final replacements = <String, Map<String, Object?>>{};
    final changedKeys = <String>{};
    for (final document in documents) {
      final persisted = byKind[document.definition.kind];
      if (persisted?.problem case final problem?) {
        _quarantineReloadedDocument(
          document,
          persistedValues: persisted?.values ?? const {},
          revision: persisted?.revision,
          errorCode: switch (problem) {
            SettingsDocumentProblem.futureVersion => 'future_document_version',
            SettingsDocumentProblem.corruption => 'corrupt_document',
          },
          replacements: replacements,
          changedKeys: changedKeys,
        );
        continue;
      }
      final oldDecoded = Map<String, Object?>.of(document.decodedValues);
      final base = Map<String, Object?>.of(persisted?.values ?? const {});
      final patch = Map<String, _PatchValue>.of(document.patch);
      document.persistedValues = base;
      document.revision = persisted?.revision;
      document.values = _applyPatch(base, patch);
      try {
        document.decodedValues = _decodeDocument(document);
      } catch (_) {
        _quarantineReloadedDocument(
          document,
          persistedValues: base,
          revision: persisted?.revision,
          errorCode: 'invalid_setting_value',
          replacements: replacements,
          changedKeys: changedKeys,
          oldDecoded: oldDecoded,
        );
        continue;
      }
      document.patch = _buildPatch(base, document.values, _registry.keysForDocument(document.definition.kind));
      replacements[document.definition.kind] = document.decodedValues;
      for (final key in _registry.keysForDocument(document.definition.kind)) {
        if (!_presenceAndValueEqual(oldDecoded, document.decodedValues, key.id)) {
          changedKeys.add(key.id);
        }
      }
    }
    if (replacements.isNotEmpty) {
      _snapshot = _snapshot.replaceGroups(replacements);
    }
    _emitStatus();
    if (changedKeys.isNotEmpty && !_streamsClosed) {
      final event = SettingsChangeEvent(
        snapshot: _snapshot,
        changedKeyIds: changedKeys,
        source: SettingsChangeSource.conflictMerge,
        changedAtUtc: _clock().toUtc(),
      );
      _changes.add(_snapshot);
      _changeEvents.add(event);
    }
  }

  void _quarantineReloadedDocument(
    _RuntimeDocument document, {
    required Map<String, Object?> persistedValues,
    required int? revision,
    required String errorCode,
    required Map<String, Map<String, Object?>> replacements,
    required Set<String> changedKeys,
    Map<String, Object?>? oldDecoded,
  }) {
    final previousDecoded = oldDecoded ?? Map<String, Object?>.of(document.decodedValues);
    final safePersisted = Map<String, Object?>.of(persistedValues);
    document.revision = revision;
    document.persistedValues = safePersisted;
    document.values = Map<String, Object?>.of(safePersisted);
    document.decodedValues = {};
    document.patch = {};
    document.persistedGeneration = document.generation;
    document.permanentErrorCode = errorCode;
    document.transientErrorCode = null;
    document.retryCount = 0;
    document.inFlight = false;
    document.timer?.cancel();
    document.timer = null;
    replacements[document.definition.kind] = const {};
    for (final key in _registry.keysForDocument(document.definition.kind)) {
      if (!_presenceAndValueEqual(previousDecoded, const {}, key.id)) {
        changedKeys.add(key.id);
      }
    }
  }

  void _markWriteFailure(Iterable<_RuntimeDocument> documents, String code) {
    for (final document in documents) {
      document.inFlight = false;
      document.transientErrorCode = code;
      document.retryCount++;
      if (document.dirty && !document.readOnly) {
        _scheduleRetry(document);
      }
    }
    _emitStatus();
  }

  Future<SettingsFlushResult> _performFlush() async {
    if (_state == SettingsState.closed || _store == null) {
      return _flushResult();
    }
    final attempts = math.max(1, _policy.flushRetryAttempts);
    for (var attempt = 0; attempt < attempts; attempt++) {
      for (final document in _documents.values) {
        document.timer?.cancel();
        document.timer = null;
        if (document.dirty && !document.readOnly) {
          _dueKinds.add(document.definition.kind);
        }
      }
      if (_dueKinds.isEmpty) {
        break;
      }
      _ensureWorker();
      await _waitForWorker();
      if (!_documents.values.any((document) => document.dirty && !document.readOnly)) {
        break;
      }
    }
    return _flushResult();
  }

  Future<void> _waitForWorker() async {
    while (_workerScheduled) {
      final tail = _workerTail;
      await tail;
      if (identical(tail, _workerTail) && !_workerScheduled) {
        return;
      }
    }
  }

  SettingsFlushResult _flushResult() {
    final current = _buildStatus();
    return SettingsFlushResult(
      persisted: current.isPersisted,
      dirtyDocumentKinds: current.dirtyDocumentKinds,
      degradedDocumentKinds: current.degradedDocumentKinds,
    );
  }

  String _safeWriteErrorCode(Object error) => switch (error) {
    SettingsStoreException(:final code) => code,
    TimeoutException() => 'write_timeout',
    _ => 'write_failed',
  };
}
