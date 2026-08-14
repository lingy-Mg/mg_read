import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'json_codec.dart';
import 'record_store.dart';

/// The only owner of app database and object-store lifecycles.
final class AppPersistence {
  AppPersistence._(
    this.dataRoot,
    this.metadataRecords,
    this.contentObjects,
    this.fileObjects,
  );
  final Directory dataRoot;
  final PersistenceRecordStore metadataRecords;
  final ContentObjectStore contentObjects;
  final FileObjectStore fileObjects;

  static Future<AppPersistence> open({
    required Directory dataRoot,
    required RecordDocumentRegistry registry,
  }) async {
    final metadata = await PersistenceRecordStore.open(
      dataRoot: dataRoot,
      registry: registry,
    );
    final content = await ContentObjectStore.open(dataRoot);
    final files = await FileObjectStore.open(dataRoot);
    return AppPersistence._(dataRoot, metadata, content, files);
  }

  Future<void> close() async {
    await contentObjects.close();
    await fileObjects.close();
    await metadataRecords.close();
  }
}

/// Immutable UTF-8 text/manifest objects; arbitrary files and SQLite BLOBs are excluded.
final class ContentObjectStore {
  ContentObjectStore._(this._database, this.databasePath);
  final _ContentDatabase _database;
  final String databasePath;
  bool _closed = false;
  bool get usesBackgroundExecutor => true;
  static Future<ContentObjectStore> open(Directory root) async {
    await root.create(recursive: true);
    final path = '${root.path}${Platform.pathSeparator}content.sqlite';
    final db = _ContentDatabase(NativeDatabase.createInBackground(File(path)));
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS content_objects (object_id TEXT PRIMARY KEY NOT NULL, content_kind TEXT NOT NULL, object_type TEXT NOT NULL, generation INTEGER NOT NULL, payload TEXT NOT NULL, byte_length INTEGER NOT NULL, sha256 TEXT NOT NULL, created_at_utc INTEGER NOT NULL)',
    );
    return ContentObjectStore._(db, path);
  }

  Future<StoredContentObject> put({
    required String objectId,
    required String contentKind,
    required String objectType,
    required int generation,
    required String payload,
  }) async {
    _ensureOpen();
    final bytes = utf8.encode(payload);
    final digest = sha256.convert(bytes).toString();
    await _database.customStatement(
      'INSERT INTO content_objects (object_id, content_kind, object_type, generation, payload, byte_length, sha256, created_at_utc) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        objectId,
        contentKind,
        objectType,
        generation,
        payload,
        bytes.length,
        digest,
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
      sha256: digest,
    );
  }

  Future<StoredContentObject?> read(String objectId) async {
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
      sha256: r['sha256'] as String,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _database.close();
  }

  void _ensureOpen() {
    if (_closed) throw StateError('ContentObjectStore is closed.');
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
    required this.sha256,
  });
  final String objectId, contentKind, objectType, payload, sha256;
  final int generation, byteLength;
}

/// Files are staged then atomically renamed under an app-private relative path.
final class FileObjectStore {
  FileObjectStore._(this._root);
  final Directory _root;
  bool _closed = false;
  bool get usesBackgroundExecutor => true;
  static Future<FileObjectStore> open(Directory root) async {
    final files = Directory(
      '${root.path}${Platform.pathSeparator}files${Platform.pathSeparator}content-assets',
    );
    await files.create(recursive: true);
    return FileObjectStore._(files);
  }

  Future<StoredFileObject> commitBytes({
    required String assetId,
    required List<int> bytes,
    required String mimeType,
  }) async {
    _ensureOpen();
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(assetId))
      throw ArgumentError.value(assetId, 'assetId');
    final temp = File('${_root.path}${Platform.pathSeparator}.$assetId.part');
    final target = File('${_root.path}${Platform.pathSeparator}$assetId.asset');
    await temp.writeAsBytes(bytes, flush: true);
    final digest = sha256.convert(bytes).toString();
    if (await target.exists()) {
      await temp.delete();
    } else {
      await temp.rename(target.path);
    }
    return StoredFileObject(
      assetId: assetId,
      relativePath: '$assetId.asset',
      byteLength: bytes.length,
      sha256: digest,
      mimeType: mimeType,
    );
  }

  Future<bool> exists(String assetId) =>
      File('${_root.path}${Platform.pathSeparator}$assetId.asset').exists();
  Future<void> close() async {
    _closed = true;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('FileObjectStore is closed.');
  }
}

final class StoredFileObject {
  const StoredFileObject({
    required this.assetId,
    required this.relativePath,
    required this.byteLength,
    required this.sha256,
    required this.mimeType,
  });
  final String assetId, relativePath, sha256, mimeType;
  final int byteLength;
}

final class _ContentDatabase extends GeneratedDatabase {
  _ContentDatabase(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];
}
