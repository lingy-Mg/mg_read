import 'dart:typed_data';

import 'document_models.dart';
import 'models.dart';

/// Host boundary for a parsed EPUB/document; all archive and resource IO stays in the host.
abstract interface class ReaderDocumentDataSource {
  Future<ReaderBookInfo> loadBookInfo(String bookId);
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  });
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index);
  Future<ReaderDocumentChapter> loadChapter(String bookId, String chapterId);
  Future<Uint8List?> loadResourceBytes(String resourceId);
  Future<ReaderDocumentLinkTarget?> resolveLink(
    String currentChapterId,
    String href,
  );
}
