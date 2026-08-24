import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';

import 'json_codec.dart';
import 'persistence_error.dart';
import 'record_store.dart';

/// The only owner of app database and object-store lifecycles.
final class AppPersistence {
  AppPersistence._(
    this.dataRoot,
    this.metadataRecords,
    this.contentObjects,
    this.fileObjects,
    this._diagnostics,
  );
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
  }) {
    Future<AppPersistence> openStores() async {
      final metadata = await PersistenceRecordStore.open(
        dataRoot: dataRoot,
        registry: registry,
        diagnostics: diagnostics,
      );
      try {
        final content = await ContentObjectStore.open(
          dataRoot,
          diagnostics: diagnostics,
        );
        try {
          final files = await FileObjectStore.open(
            dataRoot,
            diagnostics: diagnostics,
          );
          return AppPersistence._(
            dataRoot,
            metadata,
            content,
            files,
            diagnostics,
          );
        } catch (_) {
          await content.close();
          rethrow;
        }
      } catch (_) {
        await metadata.close();
        rethrow;
      }
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
      startAttributes: () => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('app'),
      }),
      successAttributes: (_) => DiagnosticObjectValue(<String, DiagnosticValue>{
        'store': DiagnosticValue.string('app'),
      }),
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
  static Future<ContentObjectStore> open(
    Directory root, {
    DiagnosticsManager? diagnostics,
  }) async {
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
    action: () => _put(
      objectId: objectId,
      contentKind: contentKind,
      objectType: objectType,
      generation: generation,
      payload: payload,
    ),
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
      errorAttributes: (_) =>
          _storeAttributes('contentObjects', errorCode: 'close_failed'),
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
      [
        objectId,
        contentKind,
        objectType,
        generation,
        payload,
        bytes.length,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
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
        .customSelect(
          'SELECT * FROM content_objects WHERE object_id = ?',
          variables: [Variable.withString(objectId)],
        )
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
        (span) => _runMeasuredPersistenceAction(
          diagnostics: diagnostics,
          span: span,
          operation: operation,
          action: action,
        ),
        startAttributes: () => _persistenceOperationAttributes(
          store: 'contentObjects',
          operation: operation,
          recordKind: recordKind,
          count: count,
        ),
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

/// Files are staged then atomically renamed under an app-private relative path.
final class FileObjectStore {
  FileObjectStore._(this._root, this._diagnostics);
  final Directory _root;
  final DiagnosticsManager? _diagnostics;
  final _StoreLifecycleGate _lifecycle = _StoreLifecycleGate();
  bool get usesBackgroundExecutor => true;
  static Future<FileObjectStore> open(
    Directory root, {
    DiagnosticsManager? diagnostics,
  }) async {
    final files = Directory(
      '${root.path}${Platform.pathSeparator}files${Platform.pathSeparator}content-assets',
    );
    await files.create(recursive: true);
    return FileObjectStore._(files, diagnostics);
  }

  Future<StoredFileObject> commitBytes({
    required String mangaId,
    required String assetId,
    required List<int> bytes,
    required String mimeType,
  }) => _instrument(
    operation: 'commitBytes',
    recordKind: 'mangaAsset',
    count: 1,
    byteCount: bytes.length,
    action: () => _commitBytes(
      mangaId: mangaId,
      assetId: assetId,
      bytes: bytes,
      mimeType: mimeType,
    ),
  );

  /// Commits one bookshelf cover below the app-owned file object root.
  Future<StoredFileObject> commitCoverBytes({
    required String itemId,
    required List<int> bytes,
    required String mimeType,
  }) => _instrument(
    operation: 'commitCoverBytes',
    recordKind: 'bookshelfCover',
    count: 1,
    byteCount: bytes.length,
    action: () =>
        _commitCoverBytes(itemId: itemId, bytes: bytes, mimeType: mimeType),
  );

  /// Commits a regenerable global cover under a hashed, path-safe key.
  Future<StoredFileObject> commitGlobalCoverBytes({
    required String coverKey,
    required List<int> bytes,
    required String mimeType,
  }) => _instrument(
    operation: 'commitGlobalCoverBytes',
    recordKind: 'globalCover',
    count: 1,
    byteCount: bytes.length,
    action: () => _commitGlobalCoverBytes(
      coverKey: coverKey,
      bytes: bytes,
      mimeType: mimeType,
    ),
  );

  /// Reads a previously committed bookshelf cover without exposing its path.
  Future<List<int>?> readCoverBytes(String itemId) => _instrument(
    operation: 'readCoverBytes',
    recordKind: 'bookshelfCover',
    count: 1,
    action: () => _readCoverBytes(itemId),
  );

  /// Reads and touches a global cover for LRU purposes.
  Future<List<int>?> readGlobalCoverBytes(String coverKey) => _instrument(
    operation: 'readGlobalCoverBytes',
    recordKind: 'globalCover',
    count: 1,
    action: () => _readGlobalCoverBytes(coverKey),
  );

  /// Removes the cover owned by one bookshelf item.
  Future<void> deleteCover(String itemId) => _instrument(
    operation: 'deleteCover',
    recordKind: 'bookshelfCover',
    count: 1,
    action: () => _deleteCover(itemId),
  );

  /// Evicts the oldest global cover files until [maxBytes] is respected.
  Future<void> pruneGlobalCovers({required int maxBytes}) => _instrument(
    operation: 'pruneGlobalCovers',
    recordKind: 'globalCover',
    action: () => _pruneGlobalCovers(maxBytes),
  );

  Future<void> deleteMangaAssets(String mangaId) => _instrument(
    operation: 'deleteMangaAssets',
    recordKind: 'mangaAsset',
    count: 1,
    action: () => _deleteMangaAssets(mangaId),
  );

  Future<void> close() => _lifecycle.close(() {
    final diagnostics = _diagnostics;
    if (diagnostics == null || diagnostics.isClosed) return _close();
    return diagnostics.runSpan<void>(
      AppDiagnosticEvents.persistenceClose,
      (_) => _close(),
      startAttributes: () => _storeAttributes('fileObjects'),
      successAttributes: (_) => _storeAttributes('fileObjects'),
      errorAttributes: (_) =>
          _storeAttributes('fileObjects', errorCode: 'close_failed'),
    );
  });

  Future<StoredFileObject> _commitBytes({
    required String mangaId,
    required String assetId,
    required List<int> bytes,
    required String mimeType,
  }) async {
    _ensureOpen();
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(assetId)) {
      throw ArgumentError.value(assetId, 'assetId');
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(mangaId)) {
      throw ArgumentError.value(mangaId, 'mangaId');
    }
    final folder = Directory('${_root.path}${Platform.pathSeparator}$mangaId');
    await folder.create(recursive: true);
    final temp = File('${folder.path}${Platform.pathSeparator}.$assetId.part');
    final target = File(
      '${folder.path}${Platform.pathSeparator}$assetId.asset',
    );
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await temp.delete();
    } else {
      await temp.rename(target.path);
    }
    return StoredFileObject(
      assetId: assetId,
      relativePath: '$mangaId/$assetId.asset',
      byteLength: bytes.length,
      mimeType: mimeType,
    );
  }

  Future<StoredFileObject> _commitCoverBytes({
    required String itemId,
    required List<int> bytes,
    required String mimeType,
  }) async {
    _ensureOpen();
    _validateOwnerId(itemId);
    final folder = Directory(
      '${_root.path}${Platform.pathSeparator}covers${Platform.pathSeparator}$itemId',
    );
    await folder.create(recursive: true);
    final temp = File('${folder.path}${Platform.pathSeparator}.cover.part');
    final target = File('${folder.path}${Platform.pathSeparator}cover.asset');
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await temp.delete();
    } else {
      await temp.rename(target.path);
    }
    return StoredFileObject(
      assetId: 'cover',
      relativePath: 'covers/$itemId/cover.asset',
      byteLength: bytes.length,
      mimeType: mimeType,
    );
  }

  Future<StoredFileObject> _commitGlobalCoverBytes({
    required String coverKey,
    required List<int> bytes,
    required String mimeType,
  }) async {
    _ensureOpen();
    _validateCoverKey(coverKey);
    final folder = Directory(
      '${_root.path}${Platform.pathSeparator}global${Platform.pathSeparator}$coverKey',
    );
    await folder.create(recursive: true);
    final temp = File('${folder.path}${Platform.pathSeparator}.cover.part');
    final target = File('${folder.path}${Platform.pathSeparator}cover.asset');
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await temp.delete();
    } else {
      await temp.rename(target.path);
    }
    return StoredFileObject(
      assetId: coverKey,
      relativePath: 'global/$coverKey/cover.asset',
      byteLength: bytes.length,
      mimeType: mimeType,
    );
  }

  Future<List<int>?> _readCoverBytes(String itemId) async {
    _ensureOpen();
    _validateOwnerId(itemId);
    final file = File(
      '${_root.path}${Platform.pathSeparator}covers${Platform.pathSeparator}$itemId${Platform.pathSeparator}cover.asset',
    );
    if (!await file.exists() || await file.length() > 5 * 1024 * 1024) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<List<int>?> _readGlobalCoverBytes(String coverKey) async {
    _ensureOpen();
    _validateCoverKey(coverKey);
    final file = File(
      '${_root.path}${Platform.pathSeparator}global${Platform.pathSeparator}$coverKey${Platform.pathSeparator}cover.asset',
    );
    if (!await file.exists() || await file.length() > 5 * 1024 * 1024) {
      return null;
    }
    final bytes = await file.readAsBytes();
    await file.setLastModified(DateTime.now());
    return bytes;
  }

  Future<void> _deleteCover(String itemId) async {
    _ensureOpen();
    _validateOwnerId(itemId);
    final folder = Directory(
      '${_root.path}${Platform.pathSeparator}covers${Platform.pathSeparator}$itemId',
    );
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<void> _pruneGlobalCovers(int maxBytes) async {
    _ensureOpen();
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final root = Directory('${_root.path}${Platform.pathSeparator}global');
    if (!await root.exists()) return;
    final entries = <_GlobalCoverFile>[];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final key = entity.path.split(Platform.pathSeparator).last;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) continue;
      final file = File('${entity.path}${Platform.pathSeparator}cover.asset');
      if (!await file.exists()) continue;
      entries.add(
        _GlobalCoverFile(
          file: file,
          length: await file.length(),
          modified: await file.lastModified(),
        ),
      );
    }
    var total = entries.fold<int>(0, (sum, entry) => sum + entry.length);
    if (total <= maxBytes) return;
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries) {
      if (total <= maxBytes) break;
      await entry.file.parent.delete(recursive: true);
      total -= entry.length;
    }
  }

  Future<void> _deleteMangaAssets(String mangaId) async {
    _ensureOpen();
    final folder = Directory('${_root.path}${Platform.pathSeparator}$mangaId');
    if (await folder.exists()) {
      await folder.delete(recursive: true);
    }
  }

  void _validateOwnerId(String ownerId) {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(ownerId)) {
      throw ArgumentError.value(ownerId, 'ownerId');
    }
  }

  void _validateCoverKey(String coverKey) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(coverKey)) {
      throw ArgumentError.value(coverKey, 'coverKey');
    }
  }

  Future<void> _close() async {
    return;
  }

  void _ensureOpen() {
    _lifecycle.ensureOpen();
  }

  Future<T> _instrument<T>({
    required String operation,
    String? recordKind,
    int? count,
    int? byteCount,
    required Future<T> Function() action,
  }) {
    return _lifecycle.run(() {
      final diagnostics = _diagnostics;
      if (diagnostics == null || diagnostics.isClosed) return action();
      return diagnostics.runSpan<T>(
        AppDiagnosticEvents.persistenceOperation,
        (span) => _runMeasuredPersistenceAction(
          diagnostics: diagnostics,
          span: span,
          operation: operation,
          action: action,
        ),
        startAttributes: () => _persistenceOperationAttributes(
          store: 'fileObjects',
          operation: operation,
          recordKind: recordKind,
          count: count,
          bytes: byteCount,
        ),
        successAttributes: (_) => _persistenceOperationAttributes(
          store: 'fileObjects',
          operation: operation,
          recordKind: recordKind,
          count: count,
          bytes: byteCount,
        ),
        errorAttributes: (error) => _persistenceOperationAttributes(
          store: 'fileObjects',
          operation: operation,
          recordKind: recordKind,
          count: count,
          bytes: byteCount,
          errorCode: _appPersistenceErrorCode(error),
        ),
      );
    });
  }
}

final class StoredFileObject {
  const StoredFileObject({
    required this.assetId,
    required this.relativePath,
    required this.byteLength,
    required this.mimeType,
  });
  final String assetId, relativePath, mimeType;
  final int byteLength;
}

final class _GlobalCoverFile {
  const _GlobalCoverFile({
    required this.file,
    required this.length,
    required this.modified,
  });

  final File file;
  final int length;
  final DateTime modified;
}

DiagnosticObjectValue _storeAttributes(String store, {String? errorCode}) =>
    DiagnosticObjectValue(<String, DiagnosticValue>{
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
  'thresholdMicros': DiagnosticValue.int64(
    AppDiagnosticThresholds.persistenceOperation.inMicroseconds,
  ),
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

  Future<void> close(Future<void> Function() action) =>
      _closeFuture ??= _beginClose(action);

  Future<void> _beginClose(Future<void> Function() action) async {
    _closing = true;
    if (_activeOperations != 0) {
      await (_idleOperations ??= Completer<void>()).future;
    }
    await action();
    _closed = true;
  }

  void ensureOpen() {
    if (_closed ||
        (_closing && !identical(Zone.current[#storeLifecycleGate], this))) {
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
