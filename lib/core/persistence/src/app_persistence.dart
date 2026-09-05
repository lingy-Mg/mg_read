/// 应用持久化与内容对象存储。
///
/// 职责：
/// - 编排主应用元数据、内容对象和文件对象存储的生命周期。
/// - 为持久化操作提供受控的诊断与关闭边界。
/// - 为两个 SQLite 存储统一启用 WAL/NORMAL，并提供显式空间统计与压缩原语。
///
/// 注意：
/// - 业务调用方只能经强类型仓储访问，不得取得数据库或文件绝对路径。
/// - 文件对象实现位于分部模块，仍受本库的生命周期与诊断约束。
/// - 启动和普通读写不自动执行完整性检查、checkpoint 或 VACUUM。
///
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
  final LazyContentObjectStore contentObjects;
  final LazyFileObjectStore fileObjects;
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
      final metadata = await Future<PersistenceRecordStore>.sync(
        metadataOpener ?? () => PersistenceRecordStore.open(dataRoot: dataRoot, registry: registry, diagnostics: diagnostics),
      );
      final content = LazyContentObjectStore._(
        _RetryableSharedOpener<ContentObjectStore>(
          storeName: 'contentObjects',
          diagnostics: diagnostics,
          opener: contentOpener ?? () => ContentObjectStore.open(dataRoot, diagnostics: diagnostics),
        ),
      );
      final files = LazyFileObjectStore._(
        _RetryableSharedOpener<FileObjectStore>(
          storeName: 'fileObjects',
          diagnostics: diagnostics,
          opener: fileOpener ?? () => FileObjectStore.open(dataRoot, diagnostics: diagnostics),
        ),
      );
      final persistence = AppPersistence._(dataRoot, metadata, content, files, diagnostics);
      content.prewarm();
      files.prewarm();
      return persistence;
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
      Object? firstError;
      StackTrace? firstStack;
      for (final close in <Future<void> Function()>[contentObjects.close, fileObjects.close, metadataRecords.close]) {
        try {
          await close();
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
      if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
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

final class _RetryableSharedOpener<T> {
  _RetryableSharedOpener({required this.storeName, required this.diagnostics, required this.opener});

  final String storeName;
  final DiagnosticsManager? diagnostics;
  final Future<T> Function() opener;
  Future<T>? _opening;
  T? _value;
  bool _closed = false;

  Future<T> open() {
    if (_closed) return Future<T>.error(StateError('$storeName is closed.'));
    final value = _value;
    if (value != null) return Future<T>.value(value);
    final pending = _opening;
    if (pending != null) return pending;
    final future = _instrumentedOpen();
    _opening = future;
    future.then<void>(
      (opened) {
        _value = opened;
      },
      onError: (Object _, StackTrace stack) {
        _opening = null;
      },
    );
    return future;
  }

  Future<T> _instrumentedOpen() {
    final manager = diagnostics;
    if (manager == null || manager.isClosed) return Future<T>.sync(opener);
    return manager.runSpan<T>(
      AppDiagnosticEvents.persistenceOpen,
      (_) => Future<T>.sync(opener),
      startAttributes: () => _storeAttributes(storeName),
      successAttributes: (_) => _storeAttributes(storeName),
      errorAttributes: (_) => _storeAttributes(storeName, errorCode: 'open_failed'),
    );
  }

  void prewarm() {
    unawaited(open().then<void>((_) {}, onError: (Object _, StackTrace stack) {}));
  }

  Future<void> close(Future<void> Function(T value) closer) async {
    if (_closed) return;
    _closed = true;
    final pending = _opening;
    if (pending != null) {
      try {
        await pending;
      } on Object {
        return;
      }
    }
    final value = _value;
    if (value != null) await closer(value);
  }
}

/// Retryable single-flight facade for the lazily opened immutable content DB.
final class LazyContentObjectStore {
  LazyContentObjectStore._(this._opener);
  final _RetryableSharedOpener<ContentObjectStore> _opener;
  bool get usesBackgroundExecutor => true;
  void prewarm() => _opener.prewarm();
  Future<StoredContentObject> put({
    required String objectId,
    required String contentKind,
    required String objectType,
    required int generation,
    required String payload,
  }) async => (await _opener.open()).put(
    objectId: objectId,
    contentKind: contentKind,
    objectType: objectType,
    generation: generation,
    payload: payload,
  );
  Future<StoredContentObject?> read(String objectId) async => (await _opener.open()).read(objectId);
  Future<ContentObjectPage> listInfo({String? afterObjectId, int limit = 500}) async =>
      (await _opener.open()).listInfo(afterObjectId: afterObjectId, limit: limit);
  Future<int> deleteMany(Iterable<String> objectIds) async => (await _opener.open()).deleteMany(objectIds);
  Future<DatabaseStorageStats> storageStats() async => (await _opener.open()).storageStats();
  Future<void> compact() async => (await _opener.open()).compact();
  Future<Object?> debugPragmaForTest(String pragma) async => (await _opener.open()).debugPragmaForTest(pragma);
  Future<void> close() => _opener.close((value) => value.close());
}

/// Retryable single-flight facade for the lazily opened controlled file store.
final class LazyFileObjectStore {
  LazyFileObjectStore._(this._opener);
  final _RetryableSharedOpener<FileObjectStore> _opener;
  bool get usesBackgroundExecutor => true;
  void prewarm() => _opener.prewarm();
  Future<StoredFileObject> commitBytes({
    required String mangaId,
    required String assetId,
    required List<int> bytes,
    required String mimeType,
  }) async => (await _opener.open()).commitBytes(mangaId: mangaId, assetId: assetId, bytes: bytes, mimeType: mimeType);
  Future<StoredFileObject> commitCoverBytes({required String itemId, required List<int> bytes, required String mimeType}) async =>
      (await _opener.open()).commitCoverBytes(itemId: itemId, bytes: bytes, mimeType: mimeType);
  Future<StoredFileObject> commitGlobalCoverBytes({
    required String coverKey,
    required List<int> bytes,
    required String mimeType,
    required int maxBytes,
  }) async => (await _opener.open()).commitGlobalCoverBytes(coverKey: coverKey, bytes: bytes, mimeType: mimeType, maxBytes: maxBytes);
  Future<List<int>?> readCoverBytes(String itemId) async => (await _opener.open()).readCoverBytes(itemId);
  Future<List<int>?> readGlobalCoverBytes(String coverKey) async => (await _opener.open()).readGlobalCoverBytes(coverKey);
  Future<void> deleteGlobalCover(String coverKey) async => (await _opener.open()).deleteGlobalCover(coverKey);
  Future<void> deleteCover(String itemId) async => (await _opener.open()).deleteCover(itemId);
  Future<void> pruneGlobalCovers({required int maxBytes}) async => (await _opener.open()).pruneGlobalCovers(maxBytes: maxBytes);
  Future<int> coverCacheUsageBytes() async => (await _opener.open()).coverCacheUsageBytes();
  Future<int> clearCoverCache() async => (await _opener.open()).clearCoverCache();
  Future<StoredFileObject> commitMangaImage({
    required String itemId,
    required String chapterId,
    required String pageId,
    required int contentVersion,
    required List<int> bytes,
    required String mimeType,
  }) async => (await _opener.open()).commitMangaImage(
    itemId: itemId,
    chapterId: chapterId,
    pageId: pageId,
    contentVersion: contentVersion,
    bytes: bytes,
    mimeType: mimeType,
  );
  Future<List<int>?> readMangaImage({
    required String itemId,
    required String chapterId,
    required String pageId,
    required int contentVersion,
  }) async => (await _opener.open()).readMangaImage(itemId: itemId, chapterId: chapterId, pageId: pageId, contentVersion: contentVersion);
  Future<int> mangaImageCacheUsageBytes() async => (await _opener.open()).mangaImageCacheUsageBytes();
  Future<({int totalBytes, Map<String, int> bytesByItem})> mangaImageCacheUsage() async => (await _opener.open()).mangaImageCacheUsage();
  Future<int> clearMangaImageCache() async => (await _opener.open()).clearMangaImageCache();
  Future<void> deleteMangaAssets(String mangaId) async => (await _opener.open()).deleteMangaAssets(mangaId);
  Future<void> close() => _opener.close((value) => value.close());
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
    await db.customStatement('PRAGMA journal_mode=WAL');
    await db.customStatement('PRAGMA synchronous=NORMAL');
    await db.customStatement('PRAGMA busy_timeout=2000');
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

  Future<ContentObjectPage> listInfo({String? afterObjectId, int limit = 500}) => _instrument(
    operation: 'listInfo',
    count: limit,
    action: () => _listInfo(afterObjectId: afterObjectId, limit: limit),
    countResult: (result) => result.objects.length,
  );

  Future<int> deleteMany(Iterable<String> objectIds) {
    final copied = objectIds.toSet();
    return _instrument(operation: 'deleteMany', count: copied.length, action: () => _deleteMany(copied), countResult: (result) => result);
  }

  Future<DatabaseStorageStats> storageStats() => _instrument(operation: 'storageStats', action: _storageStats);

  Future<void> compact() => _instrument(operation: 'compact', action: _compact);

  /// Test-only evidence for connection-level SQLite configuration.
  Future<Object?> debugPragmaForTest(String pragma) => _lifecycle.run(() async {
    _ensureOpen();
    if (!RegExp(r'^[a-z_]+$').hasMatch(pragma)) {
      throw ArgumentError.value(pragma, 'pragma');
    }
    final row = await _database.customSelect('PRAGMA $pragma').getSingle();
    return row.data.values.single;
  });

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

  Future<ContentObjectPage> _listInfo({required String? afterObjectId, required int limit}) async {
    _ensureOpen();
    if (limit < 1 || limit > 1000) throw ArgumentError.value(limit, 'limit');
    final rows = await _database
        .customSelect(
          'SELECT object_id, byte_length FROM content_objects '
          '${afterObjectId == null ? '' : 'WHERE object_id > ? '}ORDER BY object_id ASC LIMIT ?',
          variables: <Variable<Object>>[if (afterObjectId != null) Variable.withString(afterObjectId), Variable.withInt(limit + 1)],
        )
        .get();
    final hasMore = rows.length > limit;
    final objects = <StoredContentObjectInfo>[
      for (final row in rows.take(limit))
        StoredContentObjectInfo(objectId: row.data['object_id'] as String, byteLength: row.data['byte_length'] as int),
    ];
    return ContentObjectPage(
      objects: List<StoredContentObjectInfo>.unmodifiable(objects),
      nextObjectId: hasMore && objects.isNotEmpty ? objects.last.objectId : null,
    );
  }

  Future<int> _deleteMany(Set<String> objectIds) async {
    _ensureOpen();
    if (objectIds.isEmpty) return 0;
    if (objectIds.length > 500 || objectIds.any((id) => id.isEmpty)) {
      throw ArgumentError.value(objectIds.length, 'objectIds');
    }
    final placeholders = List<String>.filled(objectIds.length, '?').join(', ');
    return _database.customUpdate(
      'DELETE FROM content_objects WHERE object_id IN ($placeholders)',
      variables: <Variable<Object>>[for (final id in objectIds) Variable.withString(id)],
      updates: {},
    );
  }

  Future<DatabaseStorageStats> _storageStats() async {
    _ensureOpen();
    final pageCount = await _pragmaInt('page_count');
    final freePages = await _pragmaInt('freelist_count');
    final pageSize = await _pragmaInt('page_size');
    return DatabaseStorageStats(allocatedBytes: pageCount * pageSize, reclaimableBytes: freePages * pageSize);
  }

  Future<void> _compact() async {
    _ensureOpen();
    await _database.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await _database.customStatement('VACUUM');
    await _database.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  }

  Future<int> _pragmaInt(String pragma) async {
    final row = await _database.customSelect('PRAGMA $pragma').getSingle();
    return row.data.values.single as int;
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

final class StoredContentObjectInfo {
  const StoredContentObjectInfo({required this.objectId, required this.byteLength});

  final String objectId;
  final int byteLength;
}

final class ContentObjectPage {
  const ContentObjectPage({required this.objects, this.nextObjectId});

  final List<StoredContentObjectInfo> objects;
  final String? nextObjectId;
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
