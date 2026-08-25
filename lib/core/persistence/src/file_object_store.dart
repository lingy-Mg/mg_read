/// 应用私有文件对象存储。
///
/// 职责：
/// - 原子提交、读取和删除受控文件对象。
/// - 维护全局封面缓存的进程内索引与严格 LRU 字节上限。
///
/// 注意：
/// - 不向调用方泄漏绝对路径或绕过 [AppPersistence] 生命周期。
/// - 全局封面索引仅在首次维护时扫描；命中读取不触发扫描。
///
/// TODO:
/// - 无。
part of 'app_persistence.dart';

/// Files are staged then atomically renamed under an app-private relative path.
final class FileObjectStore {
  FileObjectStore._(this._root, this._diagnostics);

  static final RegExp _coverKeyPattern = RegExp(r'^[a-f0-9]{64}$');

  final Directory _root;
  final DiagnosticsManager? _diagnostics;
  final _StoreLifecycleGate _lifecycle = _StoreLifecycleGate();
  Future<Map<String, _GlobalCoverFile>>? _globalCoverFilesFuture;

  bool get usesBackgroundExecutor => true;

  static Future<FileObjectStore> open(Directory root, {DiagnosticsManager? diagnostics}) async {
    final files = Directory('${root.path}${Platform.pathSeparator}files${Platform.pathSeparator}content-assets');
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
    action: () => _commitBytes(mangaId: mangaId, assetId: assetId, bytes: bytes, mimeType: mimeType),
  );

  /// Commits one bookshelf cover below the app-owned file object root.
  Future<StoredFileObject> commitCoverBytes({required String itemId, required List<int> bytes, required String mimeType}) => _instrument(
    operation: 'commitCoverBytes',
    recordKind: 'bookshelfCover',
    count: 1,
    byteCount: bytes.length,
    action: () => _commitCoverBytes(itemId: itemId, bytes: bytes, mimeType: mimeType),
  );

  /// Commits one global cover and evicts only when [maxBytes] is exceeded.
  Future<StoredFileObject> commitGlobalCoverBytes({
    required String coverKey,
    required List<int> bytes,
    required String mimeType,
    required int maxBytes,
  }) => _instrument(
    operation: 'commitGlobalCoverBytes',
    recordKind: 'globalCover',
    count: 1,
    byteCount: bytes.length,
    action: () => _commitGlobalCoverBytes(coverKey: coverKey, bytes: bytes, mimeType: mimeType, maxBytes: maxBytes),
  );

  /// Reads a previously committed bookshelf cover without exposing its path.
  Future<List<int>?> readCoverBytes(String itemId) =>
      _instrument(operation: 'readCoverBytes', recordKind: 'bookshelfCover', count: 1, action: () => _readCoverBytes(itemId));

  /// Reads and touches a global cover for LRU purposes.
  Future<List<int>?> readGlobalCoverBytes(String coverKey) =>
      _instrument(operation: 'readGlobalCoverBytes', recordKind: 'globalCover', count: 1, action: () => _readGlobalCoverBytes(coverKey));

  /// Removes the cover owned by one bookshelf item.
  Future<void> deleteCover(String itemId) =>
      _instrument(operation: 'deleteCover', recordKind: 'bookshelfCover', count: 1, action: () => _deleteCover(itemId));

  /// Enforces the global-cover byte limit from the maintained cache index.
  Future<void> pruneGlobalCovers({required int maxBytes}) =>
      _instrument(operation: 'pruneGlobalCovers', recordKind: 'globalCover', action: () => _pruneGlobalCovers(maxBytes));

  Future<void> deleteMangaAssets(String mangaId) =>
      _instrument(operation: 'deleteMangaAssets', recordKind: 'mangaAsset', count: 1, action: () => _deleteMangaAssets(mangaId));

  Future<void> close() => _lifecycle.close(() {
    final diagnostics = _diagnostics;
    if (diagnostics == null || diagnostics.isClosed) return _close();
    return diagnostics.runSpan<void>(
      AppDiagnosticEvents.persistenceClose,
      (_) => _close(),
      startAttributes: () => _storeAttributes('fileObjects'),
      successAttributes: (_) => _storeAttributes('fileObjects'),
      errorAttributes: (_) => _storeAttributes('fileObjects', errorCode: 'close_failed'),
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
    final target = File('${folder.path}${Platform.pathSeparator}$assetId.asset');
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await temp.delete();
    } else {
      await temp.rename(target.path);
    }
    return StoredFileObject(assetId: assetId, relativePath: '$mangaId/$assetId.asset', byteLength: bytes.length, mimeType: mimeType);
  }

  Future<StoredFileObject> _commitCoverBytes({required String itemId, required List<int> bytes, required String mimeType}) async {
    _ensureOpen();
    _validateOwnerId(itemId);
    final folder = Directory('${_root.path}${Platform.pathSeparator}covers${Platform.pathSeparator}$itemId');
    await folder.create(recursive: true);
    final temp = File('${folder.path}${Platform.pathSeparator}.cover.part');
    final target = File('${folder.path}${Platform.pathSeparator}cover.asset');
    await temp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await temp.delete();
    } else {
      await temp.rename(target.path);
    }
    return StoredFileObject(assetId: 'cover', relativePath: 'covers/$itemId/cover.asset', byteLength: bytes.length, mimeType: mimeType);
  }

  Future<StoredFileObject> _commitGlobalCoverBytes({
    required String coverKey,
    required List<int> bytes,
    required String mimeType,
    required int maxBytes,
  }) async {
    _ensureOpen();
    _validateCoverKey(coverKey);
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    final files = await _globalCoverFiles();
    final folder = Directory('${_root.path}${Platform.pathSeparator}global${Platform.pathSeparator}$coverKey');
    await folder.create(recursive: true);
    final temp = File('${folder.path}${Platform.pathSeparator}.cover.part');
    final target = File('${folder.path}${Platform.pathSeparator}cover.asset');
    await temp.writeAsBytes(bytes, flush: true);
    final targetExists = await target.exists();
    if (targetExists) {
      await temp.delete();
    } else {
      await temp.rename(target.path);
    }
    final storedLength = targetExists ? await target.length() : bytes.length;
    files[coverKey] = _GlobalCoverFile(file: target, length: storedLength, modified: await target.lastModified());
    await _pruneGlobalCoversFromIndex(files, maxBytes);
    return StoredFileObject(assetId: coverKey, relativePath: 'global/$coverKey/cover.asset', byteLength: storedLength, mimeType: mimeType);
  }

  Future<List<int>?> _readCoverBytes(String itemId) async {
    _ensureOpen();
    _validateOwnerId(itemId);
    final file = File('${_root.path}${Platform.pathSeparator}covers${Platform.pathSeparator}$itemId${Platform.pathSeparator}cover.asset');
    if (!await file.exists() || await file.length() > 5 * 1024 * 1024) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<List<int>?> _readGlobalCoverBytes(String coverKey) async {
    _ensureOpen();
    _validateCoverKey(coverKey);
    final file = File('${_root.path}${Platform.pathSeparator}global${Platform.pathSeparator}$coverKey${Platform.pathSeparator}cover.asset');
    if (!await file.exists() || await file.length() > 5 * 1024 * 1024) {
      return null;
    }
    final bytes = await file.readAsBytes();
    final modified = DateTime.now();
    await file.setLastModified(modified);
    final indexedFiles = _globalCoverFilesFuture;
    if (indexedFiles != null) {
      (await indexedFiles)[coverKey] = _GlobalCoverFile(file: file, length: bytes.length, modified: modified);
    }
    return bytes;
  }

  Future<void> _deleteCover(String itemId) async {
    _ensureOpen();
    _validateOwnerId(itemId);
    final folder = Directory('${_root.path}${Platform.pathSeparator}covers${Platform.pathSeparator}$itemId');
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<void> _pruneGlobalCovers(int maxBytes) async {
    _ensureOpen();
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    await _pruneGlobalCoversFromIndex(await _globalCoverFiles(), maxBytes);
  }

  Future<void> _pruneGlobalCoversFromIndex(Map<String, _GlobalCoverFile> files, int maxBytes) async {
    var total = files.values.fold<int>(0, (sum, entry) => sum + entry.length);
    if (total <= maxBytes) return;
    final entries = files.entries.toList()..sort((a, b) => a.value.modified.compareTo(b.value.modified));
    for (final entry in entries) {
      if (total <= maxBytes) break;
      await entry.value.file.parent.delete(recursive: true);
      files.remove(entry.key);
      total -= entry.value.length;
    }
  }

  Future<Map<String, _GlobalCoverFile>> _globalCoverFiles() => _globalCoverFilesFuture ??= _scanGlobalCoverFiles();

  Future<Map<String, _GlobalCoverFile>> _scanGlobalCoverFiles() async {
    final root = Directory('${_root.path}${Platform.pathSeparator}global');
    if (!await root.exists()) return <String, _GlobalCoverFile>{};
    final files = <String, _GlobalCoverFile>{};
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final key = entity.uri.pathSegments.where((segment) => segment.isNotEmpty).last;
      if (!_coverKeyPattern.hasMatch(key)) continue;
      final file = File('${entity.path}${Platform.pathSeparator}cover.asset');
      if (!await file.exists()) continue;
      files[key] = _GlobalCoverFile(file: file, length: await file.length(), modified: await file.lastModified());
    }
    return files;
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
    if (!_coverKeyPattern.hasMatch(coverKey)) {
      throw ArgumentError.value(coverKey, 'coverKey');
    }
  }

  Future<void> _close() async {}

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
        (span) => _runMeasuredPersistenceAction(diagnostics: diagnostics, span: span, operation: operation, action: action),
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
  const StoredFileObject({required this.assetId, required this.relativePath, required this.byteLength, required this.mimeType});

  final String assetId, relativePath, mimeType;
  final int byteLength;
}

final class _GlobalCoverFile {
  const _GlobalCoverFile({required this.file, required this.length, required this.modified});

  final File file;
  final int length;
  final DateTime modified;
}
