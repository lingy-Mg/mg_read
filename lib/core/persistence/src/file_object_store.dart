/// 应用私有文件对象存储。
///
/// 职责：
/// - 原子提交、读取和删除受控文件对象。
/// - 维护全局封面缓存的进程内索引与严格 LRU 字节上限。
/// - 统计漫画正文图片缓存总量，并按书架漫画归属聚合新写入的缓存。
///
/// 注意：
/// - 不向调用方泄漏绝对路径或绕过 [AppPersistence] 生命周期。
/// - 全局封面索引仅在首次维护时扫描；命中读取不触发扫描。
/// - 封面读写、淘汰与清理共用串行队列；下载与非阻塞 LRU 时间戳触碰不占队列。
/// - 漫画图片不设全局容量上限；每本漫画以 100 MiB 为 LRU 软目标，允许滞回区间内临时超出。
///
part of 'app_persistence.dart';

/// Files are staged then atomically renamed under an app-private relative path.
final class FileObjectStore {
  FileObjectStore._(this._root, this._diagnostics, this._touchFileMtime, this._mangaImageMaxBytesPerItem);

  static final RegExp _coverKeyPattern = RegExp(r'^[a-f0-9]{64}$');
  static const int _maximumPendingGlobalCoverTouches = 32;
  static const int _defaultMangaImageMaxBytesPerItem = 100 * 1024 * 1024;
  static const int _mangaImagePruneTriggerNumerator = 5;
  static const int _mangaImagePruneTriggerDenominator = 4;
  static const Duration _mangaImageTouchInterval = Duration(minutes: 15);

  final Directory _root;
  final DiagnosticsManager? _diagnostics;
  final Future<void> Function(File file, DateTime modified) _touchFileMtime;
  final int _mangaImageMaxBytesPerItem;
  final _StoreLifecycleGate _lifecycle = _StoreLifecycleGate();
  Future<Map<String, _GlobalCoverFile>>? _globalCoverFilesFuture;
  Future<Map<String, _MangaImageFile>>? _mangaImageFilesFuture;
  Future<void> _coverOperations = Future<void>.value();
  Future<void> _mangaImageOperations = Future<void>.value();
  final Map<String, Future<void>> _pendingGlobalCoverTouches = <String, Future<void>>{};
  final Map<String, Future<void>> _pendingMangaImageTouches = <String, Future<void>>{};
  final Map<String, DateTime> _mangaImageLastTouches = <String, DateTime>{};
  final Map<String, int> _mangaImageBytesByItem = <String, int>{};

  bool get usesBackgroundExecutor => true;

  static Future<FileObjectStore> open(
    Directory root, {
    DiagnosticsManager? diagnostics,
    int mangaImageMaxBytesPerItem = _defaultMangaImageMaxBytesPerItem,

    /// Test-only seam for gating and observing non-blocking LRU touches.
    Future<void> Function(File file, DateTime modified)? touchFileMtime,
  }) async {
    if (mangaImageMaxBytesPerItem <= 0) {
      throw ArgumentError.value(mangaImageMaxBytesPerItem, 'mangaImageMaxBytesPerItem');
    }
    final files = Directory('${root.path}${Platform.pathSeparator}files${Platform.pathSeparator}content-assets');
    await files.create(recursive: true);
    return FileObjectStore._(files, diagnostics, touchFileMtime ?? _setFileMtime, mangaImageMaxBytesPerItem);
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

  /// Reads a global cover and schedules its LRU touch without waiting for the
  /// filesystem mtime update.
  Future<List<int>?> readGlobalCoverBytes(String coverKey) =>
      _instrument(operation: 'readGlobalCoverBytes', recordKind: 'globalCover', count: 1, action: () => _readGlobalCoverBytes(coverKey));

  /// Removes one regenerable global cover so its next use fetches fresh bytes.
  Future<void> deleteGlobalCover(String coverKey) =>
      _instrument(operation: 'deleteGlobalCover', recordKind: 'globalCover', count: 1, action: () => _deleteGlobalCover(coverKey));

  /// Removes the cover owned by one bookshelf item.
  Future<void> deleteCover(String itemId) =>
      _instrument(operation: 'deleteCover', recordKind: 'bookshelfCover', count: 1, action: () => _deleteCover(itemId));

  /// Enforces the global-cover byte limit from the maintained cache index.
  Future<void> pruneGlobalCovers({required int maxBytes}) =>
      _instrument(operation: 'pruneGlobalCovers', recordKind: 'globalCover', action: () => _pruneGlobalCovers(maxBytes));

  /// Returns bytes occupied by global and legacy bookshelf cover caches.
  Future<int> coverCacheUsageBytes() =>
      _instrument(operation: 'coverCacheUsageBytes', recordKind: 'coverCache', action: _coverCacheUsageBytes);

  /// Removes global and legacy bookshelf cover caches and returns released bytes.
  Future<int> clearCoverCache() => _instrument(operation: 'clearCoverCache', recordKind: 'coverCache', action: _clearCoverCache);

  Future<StoredFileObject> commitMangaImage({
    required String itemId,
    required String chapterId,
    required String pageId,
    required int contentVersion,
    required List<int> bytes,
    required String mimeType,
  }) => _instrument(
    operation: 'commitMangaImage',
    recordKind: 'mangaImageCache',
    byteCount: bytes.length,
    action: () => _commitMangaImage(
      itemId: itemId,
      chapterId: chapterId,
      pageId: pageId,
      contentVersion: contentVersion,
      bytes: bytes,
      mimeType: mimeType,
    ),
  );

  Future<List<int>?> readMangaImage({
    required String itemId,
    required String chapterId,
    required String pageId,
    required int contentVersion,
  }) => _instrument(
    operation: 'readMangaImage',
    recordKind: 'mangaImageCache',
    action: () => _readMangaImage(itemId, chapterId, pageId, contentVersion),
  );

  Future<int> mangaImageCacheUsageBytes() => _instrument(
    operation: 'mangaImageCacheUsageBytes',
    recordKind: 'mangaImageCache',
    action: () async => (await _mangaImageCacheUsage()).totalBytes,
  );

  Future<({int totalBytes, Map<String, int> bytesByItem})> mangaImageCacheUsage() =>
      _instrument(operation: 'mangaImageCacheUsage', recordKind: 'mangaImageCache', action: _mangaImageCacheUsage);

  Future<int> clearMangaImageCache() =>
      _instrument(operation: 'clearMangaImageCache', recordKind: 'mangaImageCache', action: _clearMangaImageCache);

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
    _scheduleGlobalCoverTouch(coverKey, file, bytes.length);
    return bytes;
  }

  Future<void> _deleteGlobalCover(String coverKey) async {
    _ensureOpen();
    _validateCoverKey(coverKey);
    final files = await _globalCoverFiles();
    final folder = Directory('${_root.path}${Platform.pathSeparator}global${Platform.pathSeparator}$coverKey');
    if (await folder.exists()) await folder.delete(recursive: true);
    files.remove(coverKey);
  }

  void _scheduleGlobalCoverTouch(String coverKey, File file, int length) {
    if (_pendingGlobalCoverTouches.containsKey(coverKey)) return;
    if (_pendingGlobalCoverTouches.length >= _maximumPendingGlobalCoverTouches) {
      return;
    }
    final touch = _touchGlobalCover(coverKey, file, length);
    _pendingGlobalCoverTouches[coverKey] = touch;
    unawaited(
      touch.whenComplete(() {
        if (identical(_pendingGlobalCoverTouches[coverKey], touch)) {
          _pendingGlobalCoverTouches.remove(coverKey);
        }
      }),
    );
  }

  Future<void> _touchGlobalCover(String coverKey, File file, int length) async {
    try {
      final modified = DateTime.now();
      final indexedFiles = _globalCoverFilesFuture;
      if (indexedFiles != null) {
        final files = await indexedFiles;
        final current = files[coverKey];
        if (current != null) {
          files[coverKey] = _GlobalCoverFile(file: file, length: current.length, modified: modified);
        }
      }
      // Never resurrect an evicted entry after the asynchronous filesystem touch.
      await _touchFileMtime(file, modified);
    } catch (_) {
      // LRU metadata is best effort and must never make a valid cover read
      // fail. A later scan or commit repairs the in-memory index if needed.
    }
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

  Future<int> _coverCacheUsageBytes() async {
    _ensureOpen();
    final globalBytes = (await _globalCoverFiles()).values.fold<int>(0, (sum, entry) => sum + entry.length);
    return globalBytes + await _directoryFileBytes(Directory('${_root.path}${Platform.pathSeparator}covers'));
  }

  static const int _mangaImageMaxBytes = 8 * 1024 * 1024;
  Future<StoredFileObject> _commitMangaImage({
    required String itemId,
    required String chapterId,
    required String pageId,
    required int contentVersion,
    required List<int> bytes,
    required String mimeType,
  }) async {
    _ensureOpen();
    if (itemId.isEmpty || chapterId.isEmpty || pageId.isEmpty || contentVersion < 1) {
      throw ArgumentError('manga image identity is invalid');
    }
    if (bytes.isEmpty || bytes.length > _mangaImageMaxBytes) {
      throw ArgumentError('manga image exceeds limit');
    }
    if (!RegExp(r'^image/[A-Za-z0-9.+-]+$').hasMatch(mimeType)) {
      throw ArgumentError.value(mimeType, 'mimeType');
    }
    final files = await _mangaImageFiles();
    final key = _mangaImageKey(itemId, chapterId, pageId, contentVersion);
    final root = Directory('${_root.path}${Platform.pathSeparator}manga-image-cache${Platform.pathSeparator}$key');
    await root.create(recursive: true);
    final ownerTemp = File('${root.path}${Platform.pathSeparator}.owner.part');
    final owner = File('${root.path}${Platform.pathSeparator}owner.id');
    await ownerTemp.writeAsString(itemId, flush: true);
    if (await owner.exists()) await owner.delete();
    await ownerTemp.rename(owner.path);
    final temp = File('${root.path}${Platform.pathSeparator}.image.part');
    final target = File('${root.path}${Platform.pathSeparator}image.asset');
    await temp.writeAsBytes(bytes, flush: true);
    // Same-directory staged commit; Windows replacement has a tiny delete/rename gap.
    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
    final previous = files[key];
    if (previous?.ownerId != null) {
      _mangaImageBytesByItem.update(previous!.ownerId!, (value) => value - previous.length);
    }
    files[key] = _MangaImageFile(file: target, length: bytes.length, modified: await target.lastModified(), ownerId: itemId);
    _mangaImageBytesByItem.update(itemId, (value) => value + bytes.length, ifAbsent: () => bytes.length);
    await _pruneMangaImagesForItem(files, itemId);
    return StoredFileObject(assetId: key, relativePath: 'manga-image-cache/$key/image.asset', byteLength: bytes.length, mimeType: mimeType);
  }

  Future<List<int>?> _readMangaImage(String itemId, String chapterId, String pageId, int contentVersion) async {
    _ensureOpen();
    final key = _mangaImageKey(itemId, chapterId, pageId, contentVersion);
    final file = File(
      '${_root.path}${Platform.pathSeparator}manga-image-cache${Platform.pathSeparator}$key${Platform.pathSeparator}image.asset',
    );
    if (!await file.exists() || await file.length() > _mangaImageMaxBytes) return null;
    final bytes = await file.readAsBytes();
    _scheduleMangaImageTouch(key, file, itemId, bytes.length);
    return bytes;
  }

  Future<int> _clearMangaImageCache() async {
    _ensureOpen();
    final root = Directory('${_root.path}${Platform.pathSeparator}manga-image-cache');
    final files = await _mangaImageFiles();
    final bytes = files.values.fold<int>(0, (sum, f) => sum + f.length);
    if (await root.exists()) await root.delete(recursive: true);
    files.clear();
    _mangaImageLastTouches.clear();
    _mangaImageBytesByItem.clear();
    return bytes;
  }

  Future<Map<String, _MangaImageFile>> _mangaImageFiles() => _mangaImageFilesFuture ??= _scanMangaImageFiles();

  Future<({int totalBytes, Map<String, int> bytesByItem})> _mangaImageCacheUsage() async {
    final files = await _mangaImageFiles();
    var totalBytes = 0;
    final bytesByItem = <String, int>{};
    for (final file in files.values) {
      totalBytes += file.length;
      final ownerId = file.ownerId;
      if (ownerId != null) {
        bytesByItem[ownerId] = (bytesByItem[ownerId] ?? 0) + file.length;
      }
    }
    return (totalBytes: totalBytes, bytesByItem: Map<String, int>.unmodifiable(bytesByItem));
  }

  Future<Map<String, _MangaImageFile>> _scanMangaImageFiles() async {
    final root = Directory('${_root.path}${Platform.pathSeparator}manga-image-cache');
    final out = <String, _MangaImageFile>{};
    _mangaImageBytesByItem.clear();
    if (!await root.exists()) return out;
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final key = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(key)) continue;
      final staged = File('${e.path}${Platform.pathSeparator}.image.part');
      if (await staged.exists()) {
        try {
          await staged.delete();
        } on FileSystemException {
          // Best-effort crash recovery; clear still removes the whole root.
        }
      }
      final ownerStaged = File('${e.path}${Platform.pathSeparator}.owner.part');
      if (await ownerStaged.exists()) {
        try {
          await ownerStaged.delete();
        } on FileSystemException {
          // Best-effort crash recovery; an owner is optional for old entries.
        }
      }
      final file = File('${e.path}${Platform.pathSeparator}image.asset');
      if (await file.exists()) {
        String? ownerId;
        final owner = File('${e.path}${Platform.pathSeparator}owner.id');
        if (await owner.exists() && await owner.length() <= 4096) {
          try {
            final value = await owner.readAsString();
            if (value.isNotEmpty) ownerId = value;
          } on Object {
            // A corrupt or pre-index cache remains counted in the total.
          }
        }
        final entry = _MangaImageFile(file: file, length: await file.length(), modified: await file.lastModified(), ownerId: ownerId);
        out[key] = entry;
        if (ownerId != null) {
          _mangaImageBytesByItem.update(ownerId, (value) => value + entry.length, ifAbsent: () => entry.length);
        }
      }
    }
    return out;
  }

  void _scheduleMangaImageTouch(String key, File file, String itemId, int length) {
    final now = DateTime.now();
    final lastTouch = _mangaImageLastTouches[key];
    if (lastTouch != null && now.difference(lastTouch) < _mangaImageTouchInterval) return;
    if (_pendingMangaImageTouches.containsKey(key) || _pendingMangaImageTouches.length >= _maximumPendingGlobalCoverTouches) return;
    _mangaImageLastTouches[key] = now;
    final touch = _touchMangaImage(key, file, itemId, length, now);
    _pendingMangaImageTouches[key] = touch;
    unawaited(
      touch.whenComplete(() {
        if (identical(_pendingMangaImageTouches[key], touch)) _pendingMangaImageTouches.remove(key);
      }),
    );
  }

  Future<void> _touchMangaImage(String key, File file, String itemId, int length, DateTime modified) async {
    try {
      final indexedFiles = _mangaImageFilesFuture;
      if (indexedFiles != null) {
        final files = await indexedFiles;
        if (files.containsKey(key)) {
          files[key] = _MangaImageFile(file: file, length: length, modified: modified, ownerId: itemId);
        }
      }
      await _touchFileMtime(file, modified);
    } on Object {
      // LRU maintenance is best effort and never turns a valid cache hit into
      // an image failure. A later process scan recovers the filesystem time.
    }
  }

  Future<void> _pruneMangaImagesForItem(Map<String, _MangaImageFile> files, String itemId) async {
    var total = _mangaImageBytesByItem[itemId] ?? 0;
    final trigger = (_mangaImageMaxBytesPerItem * _mangaImagePruneTriggerNumerator) ~/ _mangaImagePruneTriggerDenominator;
    if (total <= trigger) return;
    final entries = files.entries.where((entry) => entry.value.ownerId == itemId).toList()
      ..sort((left, right) => left.value.modified.compareTo(right.value.modified));
    for (final entry in entries) {
      if (total <= _mangaImageMaxBytesPerItem) break;
      await entry.value.file.parent.delete(recursive: true);
      files.remove(entry.key);
      _mangaImageLastTouches.remove(entry.key);
      total -= entry.value.length;
    }
    _mangaImageBytesByItem[itemId] = total;
  }

  String _mangaImageKey(String item, String chapter, String page, int version) =>
      sha256.convert(utf8.encode('$item\u001f$chapter\u001f$page\u001f$version')).toString();

  Future<int> _clearCoverCache() async {
    _ensureOpen();
    final releasedBytes = await _coverCacheUsageBytes();
    final files = await _globalCoverFiles();
    for (final folderName in const <String>['global', 'covers']) {
      final folder = Directory('${_root.path}${Platform.pathSeparator}$folderName');
      if (await folder.exists()) await folder.delete(recursive: true);
    }
    files.clear();
    return releasedBytes;
  }

  Future<int> _directoryFileBytes(Directory root) async {
    if (!await root.exists()) return 0;
    var bytes = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) bytes += await entity.length();
    }
    return bytes;
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
    final cachedImages = await _mangaImageFiles();
    for (final entry in cachedImages.entries.where((entry) => entry.value.ownerId == mangaId).toList()) {
      await entry.value.file.parent.delete(recursive: true);
      cachedImages.remove(entry.key);
      _mangaImageLastTouches.remove(entry.key);
    }
    _mangaImageBytesByItem.remove(mangaId);
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

  Future<T> _withCoverOperation<T>(Future<T> Function() action) {
    final result = _coverOperations.then((_) => action());
    // A failed write must not poison subsequent cache operations.
    _coverOperations = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<T> _withMangaImageOperation<T>(Future<T> Function() action) {
    final result = _mangaImageOperations.then((_) => action());
    _mangaImageOperations = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<T> _instrument<T>({
    required String operation,
    String? recordKind,
    int? count,
    int? byteCount,
    required Future<T> Function() action,
  }) {
    return _lifecycle.run(() {
      final coordinatedAction = switch (recordKind) {
        'globalCover' || 'bookshelfCover' || 'coverCache' => () => _withCoverOperation(action),
        'mangaImageCache' when operation != 'readMangaImage' => () => _withMangaImageOperation(action),
        _ when operation == 'deleteMangaAssets' => () => _withMangaImageOperation(action),
        _ => action,
      };
      final diagnostics = _diagnostics;
      if (diagnostics == null || diagnostics.isClosed) return coordinatedAction();
      StackTrace? failureStack;
      return diagnostics.runSpan<T>(
        AppDiagnosticEvents.persistenceOperation,
        (span) => _runMeasuredPersistenceAction(
          diagnostics: diagnostics,
          span: span,
          operation: operation,
          action: () async {
            try {
              return await coordinatedAction();
            } catch (_, stack) {
              failureStack = stack;
              rethrow;
            }
          },
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
        errorAttributes: (error) => DiagnosticObjectValue({
          ..._persistenceOperationAttributes(
            store: 'fileObjects',
            operation: operation,
            recordKind: recordKind,
            count: count,
            bytes: byteCount,
            errorCode: _appPersistenceErrorCode(error),
          ).values,
          'errorLocation': DiagnosticValue.string('FileObjectStore.$operation'),
          'errorType': DiagnosticValue.string(error.runtimeType.toString()),
          'errorText': DiagnosticValue.string(error.toString()),
          if (error is FileSystemException && error.osError != null) 'osErrorCode': DiagnosticValue.int64(error.osError!.errorCode),
          if (failureStack != null) 'stackTrace': DiagnosticValue.string(failureStack.toString()),
        }),
      );
    });
  }
}

Future<void> _setFileMtime(File file, DateTime modified) => file.setLastModified(modified);

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

final class _MangaImageFile {
  const _MangaImageFile({required this.file, required this.length, required this.modified, this.ownerId});

  final File file;
  final int length;
  final DateTime modified;
  final String? ownerId;
}
