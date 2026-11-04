/// Adapts generation-pinned Content Library document leases to the reader APIs.
///
/// It owns exactly one local session lease and never opens paths or performs
/// network access. The entry transition releases the source after the route.
library;

import 'dart:typed_data';

import 'package:novel_reader_ui/novel_reader_ui.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/core/local_documents/local_document_models.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_failure.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/data/content_library_text_reader_state_store.dart';

/// Opens a local TXT or EPUB item through a generation-pinned library lease.
final class ContentLibraryLocalReader implements LibraryReaderLauncher {
  const ContentLibraryLocalReader(this._library, [this._settings]);

  final ContentLibrary _library;
  final AppSettingsManager? _settings;

  @override
  Future<ReaderLaunchRequest> launch(String id) async {
    final itemId = LibraryItemId(id);
    final session = await _library.openLocalDocumentSession(itemId);
    if (session == null) {
      final item = await _library.getLibraryItem(itemId);
      final reason = item == null ? ReaderLaunchFailureReason.shelfItemMissing : ReaderLaunchFailureReason.unsupportedContentKind;
      throw ReaderLaunchFailure(reason: reason, error: AppError.fromUnknown(StateError('Local document is unavailable.')));
    }
    try {
      final durable = await _library.loadProgress(itemId);
      final initialProgress = durable is LibraryReadingProgress ? durable : null;
      final store = ContentLibraryTextReaderStateStore(
        _library,
        itemId: itemId,
        settings: _settings,
        localGeneration: session.generation,
        initialProgress: initialProgress,
        progressAlreadyLoaded: true,
      );
      final source = _ContentLibraryLocalDocumentSource(session);
      final cover = await session.readCover();
      final observer = _LocalDocumentObserver(store);
      final int warmBytes = session.chapterAt(0)?.wordCount.clamp(0, 1 << 18).toInt() ?? 0;
      if (session.format == LocalDocumentFormat.epub) {
        return DocumentReaderLaunchRequest(
          bookId: id,
          dataSource: source,
          stateStore: store,
          navigationEntries: _flattenNavigation(session.navigation),
          observer: observer,
          entryCoverBytes: cover,
          estimatedWarmBytes: warmBytes * 2,
          preparationKind: ReaderLaunchPreparationKind.persistent,
        );
      }
      final progress = await store.loadProgress(id);
      var index = progress?.chapterIndex ?? 0;
      if (progress != null) {
        final byId = session.chapterById(progress.chapterId);
        if (byId != null) index = byId.index;
      }
      index = index.clamp(0, session.chapterCount - 1);
      final entry = (await source.loadChapterAtIndex(id, index));
      final content = await source.loadChapterContent(id, entry.id);
      return NovelReaderLaunchRequest(
        bookId: id,
        dataSource: source,
        stateStore: store,
        seed: ReaderSessionSeed(
          book: await source.loadBookInfo(id),
          initialChapter: entry,
          initialContent: content,
          catalogTotal: session.chapterCount,
        ),
        observer: observer,
        entryCoverBytes: cover,
        estimatedWarmBytes: warmBytes * 2,
        preparationKind: ReaderLaunchPreparationKind.persistent,
      );
    } on Object catch (error) {
      await session.close();
      throw ReaderLaunchFailure.fromError(error);
    }
  }
}

List<ReaderDocumentNavigationEntry> _flattenNavigation(List<LocalDocumentNavigation> navigation) {
  final result = <ReaderDocumentNavigationEntry>[];
  void visit(List<LocalDocumentNavigation> entries, int depth) {
    for (final entry in entries) {
      result.add(ReaderDocumentNavigationEntry(title: entry.label, chapterId: entry.chapterId, anchor: entry.fragment, depth: depth));
      visit(entry.children, depth + 1);
    }
  }

  visit(navigation, 0);
  return List.unmodifiable(result);
}

final class _ContentLibraryLocalDocumentSource implements ReaderDocumentDataSource, TextReaderDataSource, DisposableReaderDataSource {
  _ContentLibraryLocalDocumentSource(this._session);

  final LocalDocumentReadingSession _session;
  Future<void>? _disposing;

  @override
  Future<ReaderBookInfo> loadBookInfo(String bookId) async {
    _requireBook(bookId);
    final item = _session.item;
    return ReaderBookInfo(
      id: item.id.value,
      title: item.title,
      author: item.author,
      description: item.description,
      sourceName: '本地文档',
      wordCount: item.wordCount,
      chapterCount: _session.logicalChapterCount,
      statusLabel: item.statusLabel,
      latestChapterTitle: item.latestChapterTitle,
      labels: item.labels,
      sourceKind: ReaderBookSourceKind.local,
    );
  }

  @override
  Future<ChapterCatalogPage> loadChapterCatalog(String bookId, {String? cursor, int pageSize = 100}) async {
    _requireBook(bookId);
    final after = cursor == null ? -1 : int.tryParse(cursor);
    if (cursor != null && after == null) {
      throw ArgumentError.value(cursor, 'cursor', 'Invalid local chapter cursor.');
    }
    final chapters = _session.chapters(afterIndex: after ?? -1, limit: pageSize);
    final hasMore = chapters.isNotEmpty && chapters.last.index + 1 < _session.chapterCount;
    return ChapterCatalogPage(
      items: [
        for (final chapter in chapters)
          ReaderChapterInfo(
            id: chapter.id,
            title: chapter.title,
            index: chapter.index,
            availability: ReaderChapterAvailability.downloaded,
            wordCount: chapter.wordCount,
            isContinuation: _session.isChapterContinuation(chapter.id),
          ),
      ],
      total: _session.chapterCount,
      hasMore: hasMore,
      nextCursor: hasMore ? '${chapters.last.index}' : null,
    );
  }

  @override
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index) async {
    _requireBook(bookId);
    final chapter = _session.chapterAt(index);
    if (chapter == null) throw RangeError.index(index, _session.chapters());
    return ReaderChapterInfo(
      id: chapter.id,
      title: chapter.title,
      index: chapter.index,
      availability: ReaderChapterAvailability.downloaded,
      wordCount: chapter.wordCount,
      isContinuation: _session.isChapterContinuation(chapter.id),
    );
  }

  @override
  Future<ReaderDocumentChapter> loadChapter(String bookId, String chapterId) async {
    _requireBook(bookId);
    final raw = await _session.readChapter(chapterId);
    final blocks = raw['blocks'] as List? ?? const [];
    return ReaderDocumentChapter(
      chapterId: raw['chapterId'] as String? ?? chapterId,
      title: raw['title'] as String? ?? _session.chapterById(chapterId)?.title ?? '',
      blocks: [
        for (final block in blocks)
          if (block is Map) ReaderDocumentBlock.fromJson(Map<String, Object?>.from(block)),
      ],
    );
  }

  @override
  Future<Uint8List?> loadResourceBytes(String resourceId) async {
    final bytes = await _session.readResource(resourceId);
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  @override
  Future<ReaderDocumentLinkTarget?> resolveLink(String currentChapterId, String href) async {
    final target = await _session.resolveLink(currentChapterId, href);
    return target == null ? null : ReaderDocumentLinkTarget(chapterId: target.chapterId, anchor: target.anchor);
  }

  @override
  Future<TextChapterContent> loadChapterContent(String bookId, String chapterId) async {
    _requireBook(bookId);
    if (_session.format != LocalDocumentFormat.txt) {
      throw StateError('EPUB content must use the document reader.');
    }
    final raw = await _session.readChapter(chapterId);
    final blocks = raw['blocks'] as List? ?? const [];
    return TextChapterContent(
      chapterId: raw['chapterId'] as String? ?? chapterId,
      title: raw['title'] as String? ?? _session.chapterById(chapterId)?.title ?? '',
      paragraphs: [
        for (final block in blocks)
          if (block is Map) TextParagraph(id: block['id'] as String? ?? '', text: block['text'] as String? ?? ''),
      ],
    );
  }

  void _requireBook(String bookId) {
    if (bookId != _session.item.id.value) {
      throw ArgumentError.value(bookId, 'bookId', 'Unexpected local book ID.');
    }
  }

  @override
  Future<void> dispose() => _disposing ??= _session.close();
}

final class _LocalDocumentObserver extends ReaderObserver {
  _LocalDocumentObserver(this._store);
  final ContentLibraryTextReaderStateStore _store;

  @override
  Future<void> onSessionStarted(String bookId) async {
    _store.startSession();
  }

  @override
  Future<void> onSessionEnded(String bookId, ReaderProgress? progress) async {
    _store.finishSession();
  }

  @override
  Future<void> onLifecycleChanged(ReaderLifecycleState state, ReaderProgress? progress) async {
    _store.onLifecycleChanged(state);
  }
}
