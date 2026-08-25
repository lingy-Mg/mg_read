/// 应用全局设置管理器。
///
/// 职责：
/// - 提供内存优先的设置读取、事务修改和状态通知。
/// - 串行化持久化、冲突合并、重试和后台命令。
///
/// 注意：
/// - 热读取不得触发磁盘 IO；持久化必须异步且可恢复。
/// - 关闭、重试和 isolate 回调不得覆盖较新的本地事务。
///
/// TODO:
/// - 无。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:mg_read/core/diagnostics/diagnostics.dart';

import 'background_settings_client.dart';
import 'setting_key.dart';
import 'settings_registry.dart';
import 'settings_status.dart';
import 'settings_store.dart';

part 'app_settings_contract.dart';
part 'app_settings_mutations.dart';

final class AppSettingsManager {
  factory AppSettingsManager({
    SettingsStore? store,
    SettingsStoreFactory? storeFactory,
    SettingsRegistry? registry,
    Iterable<SettingKey<dynamic>>? keys,
    SettingsPersistencePolicy policy = const SettingsPersistencePolicy(),
    SettingsClock clock = _utcNow,
    DiagnosticsManager? diagnostics,
  }) {
    if ((store == null) == (storeFactory == null)) {
      throw ArgumentError('Provide exactly one SettingsStore or storeFactory.');
    }
    if (registry != null && keys != null) {
      throw ArgumentError('Provide SettingsRegistry or keys, not both.');
    }
    final effectiveRegistry = registry ?? SettingsRegistry.fromKeys(keys ?? const []);
    return AppSettingsManager._(
      store: store,
      storeFactory: storeFactory,
      registry: effectiveRegistry,
      policy: policy,
      clock: clock,
      diagnostics: diagnostics,
    );
  }

  AppSettingsManager._({
    required this._store,
    required this._storeFactory,
    required SettingsRegistry registry,
    required this._policy,
    required this._clock,
    required this._diagnostics,
  }) : _registry = registry,
       _documents = {for (final definition in registry.documents.values) definition.kind: _RuntimeDocument(definition)},
       _commandReceiver = ReceivePort('mg-read-settings-owner') {
    _commandReceiver.listen(_handleBackgroundCommand);
    _snapshot = SettingsSnapshot.withDefaults(registry.defaultValues);
    _status = _buildStatus();
  }

  SettingsStore? _store;
  final SettingsStoreFactory? _storeFactory;
  final SettingsRegistry _registry;
  final SettingsPersistencePolicy _policy;
  final SettingsClock _clock;
  final DiagnosticsManager? _diagnostics;
  final Map<String, _RuntimeDocument> _documents;
  final ReceivePort _commandReceiver;
  final StreamController<SettingsSnapshot> _changes = StreamController<SettingsSnapshot>.broadcast(sync: true);
  final StreamController<SettingsChangeEvent> _changeEvents = StreamController<SettingsChangeEvent>.broadcast(sync: true);
  final StreamController<SettingsStatus> _statusChanges = StreamController<SettingsStatus>.broadcast(sync: true);

  late SettingsSnapshot _snapshot;
  SettingsState _state = SettingsState.loading;
  late SettingsStatus _status;
  String? _globalErrorCode;
  bool _streamsClosed = false;
  bool _workerScheduled = false;
  final Set<String> _dueKinds = {};
  Future<void> _workerTail = Future<void>.value();
  Future<void> _flushTail = Future<void>.value();
  Future<void>? _initializeFuture;
  Future<void>? _closeFuture;

  SettingsState get state => _state;
  SettingsStatus get status => _status;
  SettingsSnapshot get snapshot => _snapshot;
  Stream<SettingsSnapshot> get changes => _changes.stream;
  Stream<SettingsChangeEvent> get changeEvents => _changeEvents.stream;
  Stream<SettingsStatus> get statusChanges => _statusChanges.stream;
  SendPort get backgroundCommandPort => _commandReceiver.sendPort;
  BackgroundSettingsClient get backgroundClient => BackgroundSettingsClient(backgroundCommandPort);

  T get<T>(SettingKey<T> key) {
    _requireRegisteredKey(key);
    return _snapshot.get(key);
  }

  Future<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    if (_state != SettingsState.loading) {
      return;
    }
    final span = _diagnostics?.startSpan(
      AppDiagnosticEvents.settingsInitialize,
      attributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'settingCount': DiagnosticValue.int64(_registry.keys.length)}),
    );
    SettingsStore? newlyOpenedStore;
    try {
      if (_store == null) {
        newlyOpenedStore = await _storeFactory!();
        if (_isClosingOrClosed) {
          await _closeLateStore(newlyOpenedStore);
          span?.cancel(
            attributes: DiagnosticObjectValue(<String, DiagnosticValue>{'errorCode': DiagnosticValue.string('settings_closing')}),
          );
          return;
        }
        _store = newlyOpenedStore;
      }
      final loaded = await _store!.loadAll(_registry.documents.values);
      if (_state != SettingsState.loading) {
        span?.cancel(attributes: DiagnosticObjectValue(<String, DiagnosticValue>{'errorCode': DiagnosticValue.string('state_changed')}));
        return;
      }
      final seen = <String>{};
      for (final document in loaded) {
        final definition = _registry.requireDocument(document.kind);
        if (document.id != definition.id || !seen.add(document.kind)) {
          throw const SettingsStoreFailure('invalid_load_result');
        }
        _loadDocument(_documents[document.kind]!, document);
      }
      _snapshot = SettingsSnapshot.withDefaults(
        _registry.defaultValues,
      ).replaceGroups({for (final entry in _documents.entries) entry.key: entry.value.decodedValues});
      _state = SettingsState.ready;
      _recomputeOperationalState();
      span?.complete(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{'settingCount': DiagnosticValue.int64(_registry.keys.length)}),
      );
    } catch (_) {
      if (_isClosingOrClosed) {
        if (newlyOpenedStore != null && !identical(newlyOpenedStore, _store)) {
          await _closeLateStore(newlyOpenedStore);
        }
        span?.cancel(attributes: DiagnosticObjectValue(<String, DiagnosticValue>{'errorCode': DiagnosticValue.string('settings_closing')}));
        return;
      }
      _state = SettingsState.failed;
      _globalErrorCode = 'initialization_failed';
      span?.fail(
        attributes: DiagnosticObjectValue(<String, DiagnosticValue>{'errorCode': DiagnosticValue.string('initialization_failed')}),
      );
    }
    _emitStatus(recomputeState: false);
  }

  Future<void> set<T>(SettingKey<T> key, T value) => transaction((editor) => editor.set(key, value));

  Future<void> reset<T>(SettingKey<T> key) => transaction((editor) => editor.reset(key));

  Future<void> resetGroup(String documentKind) => transaction((editor) => editor.resetGroup(documentKind));

  Future<void> transaction(
    void Function(SettingsTransaction editor) action, {
    SettingsChangeSource source = SettingsChangeSource.application,
  }) {
    try {
      (int, int, String) apply() {
        _ensureWritable();
        final editor = SettingsTransaction._(_registry);
        action(editor);
        _applyMutations(editor._operations, source: source);
        final operationKinds = editor._operations
            .map(
              (operation) => switch (operation) {
                _SetMutation() => 'set',
                _ResetMutation() => 'reset',
                _ResetGroupMutation() => 'resetGroup',
              },
            )
            .toSet();
        return (
          editor._operations.length,
          editor._operations.map((item) => item.documentKind).toSet().length,
          operationKinds.length == 1 ? operationKinds.single : 'mixed',
        );
      }

      final diagnostics = _diagnostics;
      if (diagnostics == null) {
        apply();
      } else {
        diagnostics.runSpanSync<(int, int, String)>(
          AppDiagnosticEvents.settingsMutation,
          (_) => apply(),
          startAttributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
            'operation': DiagnosticValue.string('transaction'),
            'source': DiagnosticValue.string(source.name),
          }),
          successAttributes: (result) => DiagnosticObjectValue(<String, DiagnosticValue>{
            'operation': DiagnosticValue.string(result.$3),
            'keyCount': DiagnosticValue.int64(result.$1),
            'documentCount': DiagnosticValue.int64(result.$2),
            'source': DiagnosticValue.string(source.name),
          }),
          errorAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
            'operation': DiagnosticValue.string('transaction'),
            'source': DiagnosticValue.string(source.name),
            'errorCode': DiagnosticValue.string('mutation_rejected'),
          }),
        );
      }
      return Future<void>.value();
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
  }

  Future<SettingsFlushResult> flush() {
    final completer = Completer<SettingsFlushResult>();
    _flushTail = _flushTail.then((_) async {
      try {
        completer.complete(await _performFlush());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<SettingsFlushResult> retryPendingWrites() => flush();

  Future<void> close() => _closeFuture ??= _close();

  Future<void> dispose() => close();

  void _loadDocument(_RuntimeDocument runtime, SettingsDocument document) {
    runtime.revision = document.revision;
    runtime.persistedValues = Map<String, Object?>.of(document.values);
    runtime.values = Map<String, Object?>.of(document.values);
    if (document.problem case final problem?) {
      runtime.permanentErrorCode = switch (problem) {
        SettingsDocumentProblem.futureVersion => 'future_document_version',
        SettingsDocumentProblem.corruption => 'corrupt_document',
      };
      runtime.decodedValues = {};
      return;
    }
    try {
      runtime.decodedValues = _decodeDocument(runtime);
    } catch (_) {
      runtime.permanentErrorCode = 'invalid_setting_value';
      runtime.decodedValues = {};
    }
  }

  Map<String, Object?> _decodeDocument(_RuntimeDocument document) {
    validateSettingsEncodedValue(document.values);
    final decoded = <String, Object?>{};
    for (final key in _registry.keysForDocument(document.definition.kind)) {
      if (!document.values.containsKey(key.id)) {
        continue;
      }
      final value = key.decodeValue(document.values[key.id]);
      key.validateValue(value);
      decoded[key.id] = key.freezeValue(value);
    }
    return decoded;
  }

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

  Future<void> _close() async {
    if (_state == SettingsState.closed) {
      return;
    }
    _state = SettingsState.closing;
    _commandReceiver.close();
    _emitStatus(recomputeState: false);
    final initializing = _initializeFuture;
    if (initializing != null) {
      try {
        await initializing.timeout(_policy.closeTimeout);
      } on TimeoutException {
        _globalErrorCode = 'close_initialize_timeout';
      } catch (_) {
        _globalErrorCode = 'close_initialize_failed';
      }
    }
    try {
      await flush().timeout(_policy.closeTimeout);
    } on TimeoutException {
      _globalErrorCode = 'close_flush_timeout';
    } catch (_) {
      _globalErrorCode = 'close_flush_failed';
    }
    for (final document in _documents.values) {
      document.timer?.cancel();
      document.timer = null;
    }
    try {
      await _store?.close().timeout(_policy.closeTimeout);
    } on TimeoutException {
      _globalErrorCode = 'close_store_timeout';
    } catch (_) {
      _globalErrorCode = 'close_store_failed';
    }
    _state = SettingsState.closed;
    _emitStatus(recomputeState: false);
    _streamsClosed = true;
    try {
      await Future.wait([_changes.close(), _changeEvents.close(), _statusChanges.close()]).timeout(_policy.closeTimeout);
    } on TimeoutException {
      _globalErrorCode = 'close_stream_timeout';
      _status = _buildStatus();
    } catch (_) {
      _globalErrorCode = 'close_stream_failed';
      _status = _buildStatus();
    }
  }

  bool get _isClosingOrClosed => _state == SettingsState.closing || _state == SettingsState.closed;

  Future<void> _closeLateStore(SettingsStore store) async {
    try {
      await store.close().timeout(_policy.closeTimeout);
    } catch (_) {
      // The manager is already closing. This is best-effort cleanup of a
      // factory result that arrived after the ownership window ended.
    }
  }

  void _handleBackgroundCommand(Object? message) {
    SendPort? reply;
    try {
      if (message is! List ||
          message.length != 3 ||
          message[0] != SettingsCommandProtocol.operation ||
          message[1] is! List ||
          message[2] is! SendPort) {
        return;
      }
      reply = message[2] as SendPort;
      _ensureWritable();
      final mutations = <_SettingsMutation>[];
      for (final rawOperation in message[1] as List) {
        if (rawOperation is! List || rawOperation.length < 2) {
          throw ArgumentError('Invalid settings command.');
        }
        final operation = rawOperation[0];
        final id = rawOperation[1];
        if (id is! String) {
          throw ArgumentError('Invalid settings command ID.');
        }
        switch (operation) {
          case 'set':
            if (rawOperation.length != 3) {
              throw ArgumentError('Invalid set command.');
            }
            final key = _registry.requireKey(id);
            final encoded = freezeSettingsJsonValue(rawOperation[2]);
            validateSettingsEncodedValue(encoded);
            final value = key.decodeValue(encoded);
            key.validateValue(value);
            mutations.add(_SetMutation(key, key.freezeValue(value), encoded));
          case 'reset':
            if (rawOperation.length != 2) {
              throw ArgumentError('Invalid reset command.');
            }
            mutations.add(_ResetMutation(_registry.requireKey(id)));
          case 'resetGroup':
            if (rawOperation.length != 2) {
              throw ArgumentError('Invalid reset-group command.');
            }
            _registry.requireDocument(id);
            mutations.add(_ResetGroupMutation(id));
          default:
            throw ArgumentError('Unknown settings command.');
        }
      }
      _applyMutations(mutations, source: SettingsChangeSource.backgroundIsolate);
      reply.send(const <Object?>[true]);
    } catch (error) {
      reply?.send(<Object?>[false, _safeCommandErrorCode(error)]);
    }
  }

  String _safeCommandErrorCode(Object error) => switch (error) {
    SettingsReadOnlyException() => 'read_only_document',
    StateError() => 'settings_not_writable',
    ArgumentError() => 'invalid_command',
    _ => 'command_failed',
  };

  String _safeWriteErrorCode(Object error) => switch (error) {
    SettingsStoreException(:final code) => code,
    TimeoutException() => 'write_timeout',
    _ => 'write_failed',
  };

  void _ensureWritable() {
    if (_state != SettingsState.ready && _state != SettingsState.degraded) {
      throw StateError('Settings are not writable in state $_state.');
    }
  }

  SettingKey<T> _requireRegisteredKey<T>(SettingKey<T> key) {
    final registered = _registry.requireKey(key.id);
    if (!identical(registered, key)) {
      throw ArgumentError.value(key.id, 'key', 'Use the registered key.');
    }
    return registered as SettingKey<T>;
  }

  void _recomputeOperationalState() {
    if (_state == SettingsState.loading ||
        _state == SettingsState.failed ||
        _state == SettingsState.closing ||
        _state == SettingsState.closed) {
      return;
    }
    _state = _documents.values.any((document) => document.degraded) ? SettingsState.degraded : SettingsState.ready;
  }

  void _emitStatus({bool recomputeState = true}) {
    if (recomputeState) {
      _recomputeOperationalState();
    }
    _status = _buildStatus();
    if (!_streamsClosed) {
      _statusChanges.add(_status);
    }
  }

  SettingsStatus _buildStatus() => SettingsStatus(
    state: _state,
    documents: {
      for (final entry in _documents.entries)
        entry.key: SettingsDocumentStatus(
          kind: entry.key,
          dirty: entry.value.dirty,
          persisted: entry.value.persisted,
          degraded: entry.value.degraded,
          readOnly: entry.value.readOnly,
          inFlight: entry.value.inFlight,
          revision: entry.value.revision,
          generation: entry.value.generation,
          persistedGeneration: entry.value.persistedGeneration,
          retryCount: entry.value.retryCount,
          lastErrorCode: entry.value.lastErrorCode,
        ),
    },
    updatedAtUtc: _clock().toUtc(),
    lastErrorCode: _globalErrorCode,
  );
}
