/// Generation-pinned, path-free local reading sessions. Old sessions may keep
/// reading immutable content but cannot overwrite positions in a newer parse.
part of 'content_library.dart';

final class LocalDocumentReadingSession {
  LocalDocumentReadingSession._(this._library, this.item, this.generation, this._document, this.options, this.rawSha256);
  final ContentLibrary _library;
  final LibraryItem item;
  final String generation, rawSha256;
  final ParsedLocalDocument _document;
  final LocalDocumentParseOptions options;
  bool _closed = false;
  int get chapterCount => _document.chapters.length;
  int get logicalChapterCount => _document.logicalChapterCount;
  LocalDocumentReadingKind? get readingKind => _document.readingKind;
  bool isChapterContinuation(String id) =>
      _document.attributes['logicalChapterStarts'] is List && !(_document.attributes['logicalChapterStarts']! as List).contains(id);
  LocalDocumentFormat get format => _document.format;
  List<LocalDocumentNavigation> get navigation => _document.navigation;
  List<String> get warnings => _document.warnings;
  LocalDocumentChapter? chapterAt(int index) => index < 0 || index >= chapterCount ? null : _document.chapters[index];
  LocalDocumentChapter? chapterById(String id) => _document.chapters.where((chapter) => chapter.id == id).firstOrNull;
  List<LocalDocumentChapter> chapters({int afterIndex = -1, int limit = 100}) =>
      _document.chapters.skip(afterIndex + 1).take(limit.clamp(1, 500)).toList(growable: false);

  /// Structured parser DTO consumed only by the host reader adapter, never by
  /// presentation widgets. The adapter validates into reader-package types.
  Future<Map<String, Object?>> readChapter(String chapterId) async {
    _ensureOpen();
    final chapter = chapterById(chapterId);
    if (chapter == null) throw const LocalDocumentException('chapter_missing');
    return _library._localFiles.readJson(generation, chapter.contentFile);
  }

  Future<List<int>?> readResource(String resourceId) async {
    _ensureOpen();
    final resource = _document.resources.where((resource) => resource.id == resourceId).firstOrNull;
    if (resource == null) return null;
    return _library._localFiles.readResource(generation, resource.file);
  }

  /// Encoded image adapters use parser-owned MIME metadata without opening paths.
  String? resourceMimeType(String resourceId) => _document.resources.where((resource) => resource.id == resourceId).firstOrNull?.mimeType;

  Future<List<int>?> readCover() => item.source.coverHash != null
      ? _library._localFiles.readSmallOriginal(item.source.coverHash!)
      : _document.coverResourceId == null
      ? Future.value(null)
      : readResource(_document.coverResourceId!);

  Future<({String chapterId, String? anchor})?> resolveLink(String currentChapterId, String href) async {
    _ensureOpen();
    final target = Uri.tryParse(href);
    if (target == null || target.hasScheme || target.hasAuthority) return null;
    final current = chapterById(currentChapterId);
    if (current == null) return null;
    final base = Uri(path: current.href ?? '');
    final resolved = base.resolveUri(target).normalizePath();
    final chapter = target.path.isEmpty
        ? current
        : _document.chapters.where((chapter) {
            final chapterPath = Uri.tryParse(chapter.href ?? '')?.path;
            return chapterPath == target.path.replaceFirst(RegExp(r'^/+'), '') ||
                chapterPath == resolved.path.replaceFirst(RegExp(r'^/+'), '') ||
                chapter.id == target.path;
          }).firstOrNull;
    if (chapter == null) return null;
    final anchor = target.fragment.isEmpty ? null : target.fragment;
    if (anchor != null) {
      // Oversized spine documents have internal reading segments. Fragments
      // may belong to a later segment rather than the first one in the spine.
      final siblings = _document.chapters.where((entry) => entry.href == chapter.href);
      for (final candidate in siblings) {
        final content = await readChapter(candidate.id);
        if (_containsLocalAnchor(content['blocks'], anchor)) return (chapterId: candidate.id, anchor: anchor);
      }
    }
    return (chapterId: chapter.id, anchor: anchor);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _library._localFiles.release(generation, coverHash: item.source.coverHash);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Local document session is closed');
  }
}

bool _containsLocalAnchor(Object? blocks, String anchor) {
  if (blocks is! List) return false;
  for (final block in blocks) {
    if (block is! Map) continue;
    if (block['id'] == anchor || block['anchor'] == anchor || (block['anchors'] is List && (block['anchors'] as List).contains(anchor))) {
      return true;
    }
    if (_containsLocalAnchor(block['children'], anchor)) return true;
  }
  return false;
}

extension LocalDocumentSessions on ContentLibrary {
  Future<LocalDocumentReadingSession?> openLocalDocumentSession(LibraryItemId itemId) => _withStorageMaintenance(() async {
    final row = await _persistence.metadataRecords.contentLibrary.readItem(itemId.value);
    if (row == null || row.values['origin_kind'] != 'local') return null;
    final generation = row.values['active_generation']! as String;
    final item = _storedItem(row);
    _localFiles.acquire(generation, coverHash: item.source.coverHash);
    try {
      final manifest = await _localFiles.readGeneration(generation);
      final document = ParsedLocalDocument.fromJson({
        ...Map<String, Object?>.from(manifest['document']! as Map),
        if (manifest['warnings'] is List) 'warnings': manifest['warnings'],
      });
      return LocalDocumentReadingSession._(
        this,
        item,
        generation,
        document,
        LocalDocumentParseOptions.fromJson(Map<String, Object?>.from(manifest['options'] as Map? ?? const {})),
        row.values['raw_sha256']! as String,
      );
    } on Object {
      _localFiles.release(generation, coverHash: item.source.coverHash);
      rethrow;
    }
  });

  Future<List<LibraryItem>> listLocalDocuments({bool includeRetained = true}) async =>
      (await _persistence.metadataRecords.contentLibrary.localItems(
        includeRetained: includeRetained,
      )).map(_storedItem).toList(growable: false);

  Future<LocalDocumentDetails?> localDocumentDetails(LibraryItemId id) async {
    final session = await openLocalDocumentSession(id);
    if (session == null) return null;
    try {
      return LocalDocumentDetails(
        item: session.item,
        documentId: session.item.source.documentId!,
        generation: session.generation,
        rawSha256: session.rawSha256,
        originalBytes: await _localFiles.originalLength(session.rawSha256),
        format: session.format,
        options: session.options,
        navigation: session.navigation,
        warnings: session.warnings,
        chapterCount: session.logicalChapterCount,
        encoding: session._document.encoding,
      );
    } finally {
      await session.close();
    }
  }

  Future<bool> saveLocalReadingProgress(LibraryReadingProgress progress, String generation) => _withStorageMaintenance(
    () => _persistence.metadataRecords.contentLibrary.saveLocalProgress(progress.itemId.value, generation, _progressValues(progress)),
  );

  Future<bool> saveLocalReadingBookmark(LibraryBookmark bookmark, String generation) => _withStorageMaintenance(
    () => _persistence.metadataRecords.contentLibrary.saveLocalBookmark(bookmark.itemId.value, generation, _bookmarkValues(bookmark)),
  );

  Future<bool> saveLocalMangaReadingProgress(LibraryMangaReadingProgress progress, String generation) => _withStorageMaintenance(
    () => _persistence.metadataRecords.contentLibrary.saveLocalProgress(progress.itemId.value, generation, _progressValues(progress)),
  );

  Future<bool> saveLocalMangaBookmark(LibraryMangaBookmark bookmark, String generation) => _withStorageMaintenance(
    () => _persistence.metadataRecords.contentLibrary.saveLocalBookmark(bookmark.itemId.value, generation, _bookmarkValues(bookmark)),
  );

  /// Lease lifetime is tied to the returned stream subscription, including an
  /// early cancellation by backup or LAN transfer.
  Stream<List<int>> openLocalDocumentOriginal(LibraryItemId id) async* {
    final session = await openLocalDocumentSession(id);
    if (session == null) throw const LocalDocumentException('item_missing');
    try {
      yield* _localFiles.openOriginal(session.rawSha256);
    } finally {
      await session.close();
    }
  }

  Future<List<int>?> readLocalDocumentCover(LibraryItemId id) async {
    final session = await openLocalDocumentSession(id);
    if (session == null) return null;
    try {
      return await session.readCover();
    } finally {
      await session.close();
    }
  }

  Future<bool> deleteLocalReadingBookmark(LibraryItemId id, String bookmarkId, String generation) => _withStorageMaintenance(() async {
    final row = await _persistence.metadataRecords.contentLibrary.readItem(id.value);
    if (row?.values['active_generation'] != generation) return false;
    await deleteBookmark(id, bookmarkId);
    return true;
  });

  Future<int> localDocumentUsageBytes() => _localFiles.usageBytes();

  Future<int> collectLocalDocumentGarbage() => _withStorageMaintenance(
    () async => _localFiles.collect(
      generations: await _persistence.metadataRecords.contentLibrary.referencedLocalGenerations(),
      hashes: await _persistence.metadataRecords.contentLibrary.referencedLocalHashes(),
      activeTasks: _localImports.keys.toSet(),
    ),
  );
}
