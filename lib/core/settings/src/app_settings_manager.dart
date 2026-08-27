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
part 'app_settings_background_execution.dart';
part 'app_settings_transaction_queue.dart';

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

  /// Reopens settings after a failed first initialization.
  ///
  /// Initialization is single-flight: callers while the retry is loading
  /// receive the same future. A successfully initialized manager has nothing
  /// to retry, while a closing manager rejects the request.
  Future<void> retryInitialization() {
    switch (_state) {
      case SettingsState.loading:
        return _initializeFuture ??= _initialize();
      case SettingsState.ready:
      case SettingsState.degraded:
        return Future<void>.value();
      case SettingsState.failed:
        final retry = _retryInitialization();
        _initializeFuture = retry;
        return retry;
      case SettingsState.closing:
      case SettingsState.closed:
        return Future<void>.error(StateError('Settings initialization cannot be retried in state $_state.'));
    }
  }

  Future<void> _retryInitialization() async {
    final failedStore = _store;
    _store = null;
    _resetInitializationState();
    _state = SettingsState.loading;
    _emitStatus(recomputeState: false);

    if (failedStore != null) {
      try {
        await failedStore.close().timeout(_policy.closeTimeout);
      } catch (_) {
        // The failed store is no longer owned by the manager. A factory retry
        // can proceed even when best-effort cleanup does not complete.
      }
    }
    if (_isClosingOrClosed) {
      return;
    }
    if (_storeFactory == null) {
      _state = SettingsState.failed;
      _globalErrorCode = 'initialization_retry_unavailable';
      _emitStatus(recomputeState: false);
      return;
    }
    await _initialize();
  }

  void _resetInitializationState() {
    _globalErrorCode = null;
    _snapshot = SettingsSnapshot.withDefaults(_registry.defaultValues);
    for (final document in _documents.values) {
      document.timer?.cancel();
      document.timer = null;
      document.persistedValues = {};
      document.values = {};
      document.decodedValues = {};
      document.patch = {};
      document.revision = null;
      document.generation = 0;
      document.persistedGeneration = 0;
      document.retryCount = 0;
      document.inFlight = false;
      document.permanentErrorCode = null;
      document.transientErrorCode = null;
    }
  }

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
