/// 应用持久化与内容对象存储。
///
/// 职责：
/// - 编排主应用元数据、内容对象和文件对象存储的生命周期。
/// - 为持久化操作提供受控的诊断与关闭边界。
///
/// 注意：
/// - 业务调用方只能经强类型仓储访问，不得取得数据库或文件绝对路径。
/// - 文件对象实现位于分部模块，仍受本库的生命周期与诊断约束。
///
/// TODO:
/// - 无。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
// ignore: depend_on_referenced_packages
import 'package:crypto/crypto.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

import 'json_codec.dart';
import 'persistence_error.dart';
import 'record_store.dart';

part 'file_object_store.dart';

/// The only owner of app database and object-store lifecycles.
final class AppPersistence {
  AppPersistence._(this.dataRoot, this.metadataRecords, this.contentObjects, this.fileObjects, this._diagnostics);
  final Directory dataRoot;
  final PersistenceRecordStore metadataRecords;
  final ContentObjectStore contentObjects;
  final FileObjectStore fileObjects;
  final DiagnosticsManager? _diagnostics;
  Future<void>? _closeFuture;

  static Future<AppPersistence> open({
    required Directory dataRoot,
    required RecordDocumentRegistry registry,
    DiagnosticsManager? diagnostics,
  }) => _open(dataRoot: dataRoot, registry: registry, diagnostics: diagnostics);

  /// Opens the stores through supplied openers for persistence lifecycle tests.
  ///
  /// The openers are intentionally narrow: they only replace store creation;
  /// ownership, failure cleanup, diagnostics, and close ordering remain the
  /// same as [open].
  static Future<AppPersistence> openForTesting({
    required Directory dataRoot,
    required RecordDocumentRegistry registry,
    DiagnosticsManager? diagnostics,
    Future<PersistenceRecordStore> Function()? metadataOpener,
    Future<ContentObjectStore> Function()? contentOpener,
    Future<FileObjectStore> Function()? fileOpener,
  }) => _open(
    dataRoot: dataRoot,
    registry: registry,
    diagnostics: diagnostics,
    metadataOpener: metadataOpener,
    contentOpener: contentOpener,
    fileOpener: fileOpener,
  );

  static Future<AppPersistence> _open({
    required Directory dataRoot,
    required RecordDocumentRegistry registry,
    DiagnosticsManager? diagnostics,
    Future<PersistenceRecordStore> Function()? metadataOpener,
    Future<ContentObjectStore> Function()? contentOpener,
    Future<FileObjectStore> Function()? fileOpener,
  }) {
    Future<AppPersistence> openStores() async {
      PersistenceRecordStore? metadata;
      ContentObjectStore? content;
      FileObjectStore? files;
      Object? firstError;
      StackTrace? firstStack;

      void captureError(Object error, StackTrace stack) {
        if (firstError != null) return;
        firstError = error;
        firstStack = stack;
      }

      Future<T> start<T>(Future<T> Function() opener, void Function(T) onSuccess) async {
        try {
          final value = await Future<T>.sync(opener);
          onSuccess(value);
          return value;
        } catch (error, stack) {
          captureError(error, stack);
          rethrow;
        }
      }

      final metadataFuture = start(
        metadataOpener ?? () => PersistenceRecordStore.open(dataRoot: dataRoot, registry: registry, diagnostics: diagnostics),
        (value) => metadata = value,
      );
      final contentFuture = start(
        contentOpener ?? () => ContentObjectStore.open(dataRoot, diagnostics: diagnostics),
        (value) => content = value,
      );
      final fileFuture = start(fileOpener ?? () => FileObjectStore.open(dataRoot, diagnostics: diagnostics), (value) => files = value);

      try {
        await Future.wait<Object>(<Future<Object>>[metadataFuture, contentFuture, fileFuture], eagerError: false);
      } catch (error, stack) {
        // Future.wait(eagerError: false) has already awaited every started
        // branch. Close in the same order as normal AppPersistence.close,
        // while preserving the first branch error and its original stack.
        for (final close in <Future<void> Function()>[
          if (content != null) content!.close,
          if (files != null) files!.close,
          if (metadata != null) metadata!.close,
        ]) {
          try {
            await close();
          } catch (_) {
            // The initiating open error is the public failure. Remaining
            // resources must still be attempted even if one close fails.
          }
        }
        Error.throwWithStackTrace(firstError ?? error, firstStack ?? stack);
      }

      return AppPersistence._(dataRoot, metadata!, content!, files!, diagnostics);
    }

    if (diagnostics == null || diagnostics.isClosed) return openStores();
    return diagnostics.runSpan<AppPersistence>(
      AppDiagnosticEvents.persistenceOpen,
      (_) => openStores(),
      startAttributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('app'),
        'schemaVersion': DiagnosticValue.int64(1),
      }),
      successAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('app'),
        'schemaVersion': DiagnosticValue.int64(1),
      }),
      errorAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('app'),
        'schemaVersion': DiagnosticValue.int64(1),
        'errorCode': DiagnosticValue.string('open_failed'),
      }),
    );
  }

  Future<void> close() => _closeFuture ??= _beginClose();

  Future<void> _beginClose() async {
    Future<void> closeStores() async {
      await contentObjects.close();
      await fileObjects.close();
      await metadataRecords.close();
    }

    final diagnostics = _diagnostics;
    if (diagnostics == null || diagnostics.isClosed) {
      await closeStores();
      return;
    }
    await diagnostics.runSpan<void>(
      AppDiagnosticEvents.persistenceClose,
      (_) => closeStores(),
      startAttributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{'store': DiagnosticValue.string('app')}),
      successAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{'store': DiagnosticValue.string('app')}),
      errorAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('app'),
        'errorCode': DiagnosticValue.string('close_failed'),
      }),
    );
  }
}

/// Immutable UTF-8 text/manifest objects; arbitrary files and SQLite BLOBs are excluded.
final class ContentObjectStore {
  ContentObjectStore._(this._database, this.databasePath, this._diagnostics);
  final _ContentDatabase _database;
  final String databasePath;
  final DiagnosticsManager? _diagnostics;
  final _StoreLifecycleGate _lifecycle = _StoreLifecycleGate();
  bool get usesBackgroundExecutor => true;
  static Future<ContentObjectStore> open(Directory root, {DiagnosticsManager? diagnostics}) async {
    await root.create(recursive: true);
    final path = '${root.path}${Platform.pathSeparator}content.sqlite';
    final db = _ContentDatabase(NativeDatabase.createInBackground(File(path)));
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS content_objects (object_id TEXT PRIMARY KEY NOT NULL, content_kind TEXT NOT NULL, object_type TEXT NOT NULL, generation INTEGER NOT NULL, payload TEXT NOT NULL, byte_length INTEGER NOT NULL, created_at_utc INTEGER NOT NULL)',
    );
    return ContentObjectStore._(db, path, diagnostics);
  }

  Future<StoredContentObject> put({
    required String objectId,
    required String contentKind,
    required String objectType,
    required int generation,
    required String payload,
  }) => _instrument(
    operation: 'put',
    recordKind: contentKind,
    count: 1,
    action: () => _put(objectId: objectId, contentKind: contentKind, objectType: objectType, generation: generation, payload: payload),
    bytes: (result) => result.byteLength,
  );

  Future<StoredContentObject?> read(String objectId) => _instrument(
    operation: 'read',
    action: () => _read(objectId),
    countResult: (result) => result == null ? 0 : 1,
    bytes: (result) => result?.byteLength,
  );

  Future<void> close() => _lifecycle.close(() {
    final diagnostics = _diagnostics;
    if (diagnostics == null || diagnostics.isClosed) return _close();
    return diagnostics.runSpan<void>(
      AppDiagnosticEvents.persistenceClose,
      (_) => _close(),
      startAttributes: () => _storeAttributes('contentObjects'),
      successAttributes: (_) => _storeAttributes('contentObjects'),
      errorAttributes: (_) => _storeAttributes('contentObjects', errorCode: 'close_failed'),
    );
  });

  Future<StoredContentObject> _put({
    required String objectId,
    required String contentKind,
    required String objectType,
    required int generation,
    required String payload,
  }) async {
    _ensureOpen();
    final bytes = utf8.encode(payload);
    await _database.customStatement(
      'INSERT INTO content_objects (object_id, content_kind, object_type, generation, payload, byte_length, created_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [objectId, contentKind, objectType, generation, payload, bytes.length, DateTime.now().toUtc().millisecondsSinceEpoch],
    );
    return StoredContentObject(
      objectId: objectId,
      contentKind: contentKind,
      objectType: objectType,
      generation: generation,
      payload: payload,
      byteLength: bytes.length,
    );
  }

  Future<StoredContentObject?> _read(String objectId) async {
    _ensureOpen();
    final rows = await _database
        .customSelect('SELECT * FROM content_objects WHERE object_id = ?', variables: [Variable.withString(objectId)])
        .get();
    if (rows.isEmpty) return null;
    final r = rows.single.data;
    return StoredContentObject(
      objectId: r['object_id'] as String,
      contentKind: r['content_kind'] as String,
      objectType: r['object_type'] as String,
      generation: r['generation'] as int,
      payload: r['payload'] as String,
      byteLength: r['byte_length'] as int,
    );
  }

  Future<void> _close() async {
    await _database.close();
  }

  void _ensureOpen() {
    _lifecycle.ensureOpen();
  }

  Future<T> _instrument<T>({
    required String operation,
    String? recordKind,
    int? count,
    required Future<T> Function() action,
    int? Function(T result)? countResult,
    int? Function(T result)? bytes,
  }) {
    return _lifecycle.run(() {
      final diagnostics = _diagnostics;
      if (diagnostics == null || diagnostics.isClosed) return action();
      return diagnostics.runSpan<T>(
        AppDiagnosticEvents.persistenceOperation,
        (span) => _runMeasuredPersistenceAction(diagnostics: diagnostics, span: span, operation: operation, action: action),
        startAttributes: () =>
            _persistenceOperationAttributes(store: 'contentObjects', operation: operation, recordKind: recordKind, count: count),
        successAttributes: (result) => _persistenceOperationAttributes(
          store: 'contentObjects',
          operation: operation,
          recordKind: recordKind,
          count: countResult?.call(result) ?? count,
          bytes: bytes?.call(result),
        ),
        errorAttributes: (error) => _persistenceOperationAttributes(
          store: 'contentObjects',
          operation: operation,
          recordKind: recordKind,
          count: count,
          errorCode: _appPersistenceErrorCode(error),
        ),
      );
    });
  }
}

final class StoredContentObject {
  const StoredContentObject({
    required this.objectId,
    required this.contentKind,
    required this.objectType,
    required this.generation,
    required this.payload,
    required this.byteLength,
  });
  final String objectId, contentKind, objectType, payload;
  final int generation, byteLength;
}

DiagnosticObjectValue _storeAttributes(String store, {String? errorCode}) => DiagnosticObjectValue(<String, DiagnosticValue>{
  'store': DiagnosticValue.string(store),
  if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
});

DiagnosticObjectValue _persistenceOperationAttributes({
  required String store,
  required String operation,
  String? recordKind,
  int? count,
  int? bytes,
  String? errorCode,
}) => DiagnosticObjectValue(<String, DiagnosticValue>{
  'store': DiagnosticValue.string(store),
  'operation': DiagnosticValue.string(operation),
  if (recordKind != null) 'recordKind': DiagnosticValue.string(recordKind),
  if (count != null) 'count': DiagnosticValue.int64(count),
  if (bytes != null) 'bytes': DiagnosticValue.int64(bytes),
  if (errorCode != null) 'errorCode': DiagnosticValue.string(errorCode),
  'thresholdMicros': DiagnosticValue.int64(AppDiagnosticThresholds.persistenceOperation.inMicroseconds),
});

Future<T> _runMeasuredPersistenceAction<T>({
  required DiagnosticsManager diagnostics,
  required DiagnosticSpanHandle span,
  required String operation,
  required Future<T> Function() action,
}) async {
  final stopwatch = Stopwatch()..start();
  try {
    final result = await action();
    stopwatch.stop();
    reportSlowDiagnostic(
      diagnostics,
      subjectComponent: 'app.persistence',
      operation: operation,
      elapsed: stopwatch.elapsed,
      threshold: AppDiagnosticThresholds.persistenceOperation,
      outcome: DiagnosticOutcome.success,
      traceContext: span.traceContext,
    );
    return result;
  } catch (_) {
    stopwatch.stop();
    reportSlowDiagnostic(
      diagnostics,
      subjectComponent: 'app.persistence',
      operation: operation,
      elapsed: stopwatch.elapsed,
      threshold: AppDiagnosticThresholds.persistenceOperation,
      outcome: DiagnosticOutcome.error,
      traceContext: span.traceContext,
    );
    rethrow;
  }
}

String _appPersistenceErrorCode(Object error) => switch (error) {
  PersistenceError(:final code) => code,
  FileSystemException() => 'file_io_failed',
  _ => 'operation_failed',
};

/// Prevents a store from closing beneath an operation that already started.
final class _StoreLifecycleGate {
  bool _closing = false;
  bool _closed = false;
  int _activeOperations = 0;
  Completer<void>? _idleOperations;
  Future<void>? _closeFuture;

  Future<T> run<T>(Future<T> Function() action) {
    if (identical(Zone.current[#storeLifecycleGate], this)) {
      return action();
    }
    if (_closing || _closed) {
      return Future<T>.error(StateError('Persistence store is closed.'));
    }
    _activeOperations++;
    return runZoned<Future<T>>(
      () => Future<T>.sync(action).whenComplete(() {
        _activeOperations--;
        if (_closing && _activeOperations == 0) {
          _idleOperations?.complete();
        }
      }),
      zoneValues: <Object?, Object?>{#storeLifecycleGate: this},
    );
  }

  Future<void> close(Future<void> Function() action) => _closeFuture ??= _beginClose(action);

  Future<void> _beginClose(Future<void> Function() action) async {
    _closing = true;
    if (_activeOperations != 0) {
      await (_idleOperations ??= Completer<void>()).future;
    }
    await action();
    _closed = true;
  }

  void ensureOpen() {
    if (_closed || (_closing && !identical(Zone.current[#storeLifecycleGate], this))) {
      throw StateError('Persistence store is closed.');
    }
  }
}

final class _ContentDatabase extends GeneratedDatabase {
  _ContentDatabase(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];
}
