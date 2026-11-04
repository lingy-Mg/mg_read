import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/data/content_library_local_reader.dart';
import 'package:novel_reader_ui/novel_reader_ui.dart';

void main() {
  late Directory root;
  late ContentLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mgread-local-reader-');
    library = await ContentLibrary.open(dataRoot: root);
  });

  tearDown(() async {
    await library.close();
    await root.delete(recursive: true);
  });

  test('TXT launches through stable parser block IDs and generation-fenced state', () async {
    final imported = await _importText(library, '第一章 起点\n\n真实段落内容。\n\n第二章 远方\n\n下一章内容。');
    final request = await ContentLibraryLocalReader(library).launch(imported.itemId!.value);
    expect(request, isA<NovelReaderLaunchRequest>());
    final novel = request as NovelReaderLaunchRequest;
    final seed = novel.seed!;
    expect(seed.book.sourceKind, ReaderBookSourceKind.local);
    expect(seed.initialChapter.index, 0);
    expect(seed.initialContent.paragraphs, isNotEmpty);
    final paragraph = seed.initialContent.paragraphs.first;
    expect(paragraph.id, startsWith('p'));

    await novel.stateStore.saveProgress(
      novel.bookId,
      ReaderProgress(
        chapterId: seed.initialChapter.id,
        paragraphId: paragraph.id,
        characterOffset: 3,
        chapterIndex: 0,
        chapterFraction: .4,
        bookFraction: .2,
      ),
    );
    final reread = await library.loadProgress(imported.itemId!) as LibraryReadingProgress;
    expect(reread.paragraphId, paragraph.id);
    expect(reread.characterOffset, 3);
    await (novel.dataSource as DisposableReaderDataSource).dispose();
    await expectLater(novel.dataSource.loadChapterContent(novel.bookId, seed.initialChapter.id), throwsStateError);
  });

  test('TXT text adapter removes parser-only title and whitespace while preserving semantic IDs', () async {
    final imported = await _importText(library, '第一章 起点\n\n正文第一段。\n\n正文第二段。\n');
    final session = (await library.openLocalDocumentSession(imported.itemId!))!;
    final info = session.chapterAt(0)!;
    final raw = await session.readChapter(info.id);
    final rawBlocks = (raw['blocks'] as List).cast<Map>();
    final titleBlock = rawBlocks.firstWhere((block) => block['type'] == 'heading');
    final firstBody = rawBlocks.firstWhere((block) => (block['text'] as String).contains('正文第一段'));
    final secondBody = rawBlocks.firstWhere((block) => (block['text'] as String).contains('正文第二段'));
    await library.saveLocalReadingProgress(
      LibraryReadingProgress(
        itemId: imported.itemId!,
        chapterId: info.id,
        paragraphId: titleBlock['id'] as String,
        characterOffset: 4,
        chapterIndex: 0,
        chapterFraction: .3,
        bookFraction: .3,
        updatedAtUtc: DateTime.utc(2026, 11, 4),
      ),
      session.generation,
    );
    await library.saveLocalReadingBookmark(
      LibraryBookmark(
        id: 'heading-bookmark',
        itemId: imported.itemId!,
        chapterId: info.id,
        paragraphId: titleBlock['id'] as String,
        characterOffset: 4,
        chapterTitle: info.title,
        excerpt: '第一章 起点',
        createdAtUtc: DateTime.utc(2026, 11, 4),
      ),
      session.generation,
    );
    await session.close();

    final novel = await ContentLibraryLocalReader(library).launch(imported.itemId!.value) as NovelReaderLaunchRequest;
    addTearDown(() => (novel.dataSource as DisposableReaderDataSource).dispose());
    final paragraphs = novel.seed!.initialContent.paragraphs;
    expect(paragraphs.map((paragraph) => paragraph.id), [firstBody['id'], secondBody['id']]);
    expect(paragraphs.map((paragraph) => paragraph.text), ['正文第一段。', '正文第二段。']);
    expect(paragraphs.every((paragraph) => !paragraph.text.endsWith('\n')), isTrue);

    final resumed = await novel.stateStore.loadProgress(novel.bookId);
    expect(resumed?.paragraphId, firstBody['id']);
    expect(resumed?.characterOffset, 0);
    final bookmarks = await novel.stateStore.loadBookmarks(novel.bookId);
    expect(bookmarks.single.paragraphId, firstBody['id']);
    expect(bookmarks.single.characterOffset, 0);
  });

  test('text-only EPUB uses the existing novel request and text anchors', () async {
    final imported = await _importEpub(library, _epubBytes());
    final request = await ContentLibraryLocalReader(library).launch(imported.itemId!.value);
    expect(request, isA<NovelReaderLaunchRequest>());
    final novel = request as NovelReaderLaunchRequest;
    addTearDown(() => (novel.dataSource as DisposableReaderDataSource).dispose());
    expect(novel.seed!.initialContent.paragraphs.map((p) => p.text), ['A bold paragraph.']);
    expect(novel.entryCoverBytes, isNotEmpty);
    expect((await library.getLibraryItem(imported.itemId!))!.kind, ContentKind.novel);
  });

  test('image-only EPUB uses the existing comic request and typed image state', () async {
    final imported = await _importEpub(library, _epubBytes(imageOnly: true));
    final request = await ContentLibraryLocalReader(library).launch(imported.itemId!.value);
    expect(request, isA<ComicReaderLaunchRequest>());
    final comic = request as ComicReaderLaunchRequest;
    expect(comic.dataSource, isA<ComicReaderPreciseProgressDataSource>());
    addTearDown(() => (comic.dataSource as DisposableReaderDataSource).dispose());
    final catalog = await comic.dataSource.loadChapterCatalog(comic.bookId);
    final chapter = await comic.dataSource.loadChapterContent(comic.bookId, catalog.items.first.id);
    expect(chapter.images, hasLength(2));
    final image = chapter.images.last;
    expect(await comic.dataSource.loadImageBytes(comic.bookId, chapter.chapterId, image.id), isNotEmpty);
    await comic.stateStore.saveProgress(
      comic.bookId,
      ComicReaderProgress(chapterId: chapter.chapterId, imageId: image.id, imageFraction: .42, chapterIndex: 0, bookFraction: .7),
    );
    final progress = await library.loadProgress(imported.itemId!) as LibraryMangaReadingProgress;
    expect(progress.imageId, image.id);
    expect(progress.imageFraction, .42);
    expect((await library.getLibraryItem(imported.itemId!))!.kind, ContentKind.manga);
    expect((await comic.stateStore.loadProgress(comic.bookId))!.imageFraction, .42);
    await comic.stateStore.addBookmark(
      ComicReaderBookmark(
        id: 'local-comic-bookmark',
        bookId: comic.bookId,
        chapterId: chapter.chapterId,
        imageId: image.id,
        imageFraction: .42,
        chapterTitle: chapter.title,
        createdAt: DateTime.utc(2026, 11, 4),
      ),
    );
    final reopened = await ContentLibraryLocalReader(library).launch(imported.itemId!.value) as ComicReaderLaunchRequest;
    addTearDown(() => (reopened.dataSource as DisposableReaderDataSource).dispose());
    final restoredBookmark = (await reopened.stateStore.loadBookmarks(reopened.bookId)).single;
    expect(restoredBookmark.chapterTitle, chapter.title);
    expect(restoredBookmark.imageId, image.id);
    expect(restoredBookmark.imageFraction, .42);
  });

  test('mixed EPUB is rejected without creating a shelf item', () async {
    final bytes = _epubBytes(mixed: true);
    final staged = await library.prepareLocalImport(
      LocalImportInput(fileName: 'mixed.epub', bytes: bytes.length, openRead: () => Stream.value(bytes)),
    );
    expect(staged.status, LocalImportStatus.failed);
    expect(staged.errorCode, 'epub_mixed_content_unsupported');
    expect(await library.listLocalDocuments(), isEmpty);
  });

  test('TXT internal segments remain readable while only logical chapters enter the directory', () async {
    final imported = await _importText(library, '第一章 开始\n${'长正文。' * 20000}\n第二章 结束\n结尾\n');
    final novel = await ContentLibraryLocalReader(library).launch(imported.itemId!.value) as NovelReaderLaunchRequest;
    addTearDown(() => (novel.dataSource as DisposableReaderDataSource).dispose());
    final catalog = await novel.dataSource.loadChapterCatalog(novel.bookId);
    expect(catalog.items.length, greaterThan(2));
    expect(catalog.items.where((chapter) => !chapter.isContinuation).map((chapter) => chapter.title), ['第一章 开始', '第二章 结束']);
    expect(novel.seed!.book.chapterCount, 2);
    final continuation = catalog.items.firstWhere((chapter) => chapter.isContinuation);
    expect((await novel.dataSource.loadChapterContent(novel.bookId, continuation.id)).paragraphs, isNotEmpty);
  });
}

Future<LocalImportSnapshot> _importText(ContentLibrary library, String text) async {
  final bytes = utf8.encode(text);
  final staged = await library.prepareLocalImport(
    LocalImportInput(fileName: 'book.txt', bytes: bytes.length, openRead: () => Stream.value(bytes)),
  );
  expect(staged.status, LocalImportStatus.awaitingConfirmation);
  final imported = await library.commitLocalImport(staged.id);
  expect(imported.status, LocalImportStatus.succeeded, reason: imported.errorCode);
  return imported;
}

List<int> _epubBytes({bool imageOnly = false, bool mixed = false}) {
  final archive = Archive();
  void add(String path, String value) => archive.addFile(ArchiveFile.bytes(path, utf8.encode(value)));
  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '''<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
  );
  add(
    'OPS/package.opf',
    '''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">id</dc:identifier><dc:title>Local EPUB</dc:title><dc:creator>Author</dc:creator></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/><item id="page" href="page.png" media-type="image/png"/></manifest><spine><itemref idref="chapter"/></spine></package>''',
  );
  add(
    'OPS/chapter.xhtml',
    '''<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Chapter</title></head><body>${imageOnly ? '<img id="one" src="page.png"/><img id="two" src="page.png"/>' : '<h1 id="target">Chapter</h1><p>A <strong>bold</strong> paragraph.</p>'}${mixed ? '<img src="cover.png"/>' : ''}</body></html>''',
  );
  add(
    'OPS/nav.xhtml',
    '''<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml#target">Chapter</a><ol><li><a href="chapter.xhtml#target">Nested</a></li></ol></li></ol></nav></body></html>''',
  );
  archive.addFile(ArchiveFile.bytes('OPS/cover.png', [1, 2, 3, 4]));
  archive.addFile(ArchiveFile.bytes('OPS/page.png', [4, 3, 2, 1]));
  return ZipEncoder().encode(archive);
}

Future<LocalImportSnapshot> _importEpub(ContentLibrary library, List<int> bytes) async {
  final staged = await library.prepareLocalImport(
    LocalImportInput(fileName: 'book.epub', bytes: bytes.length, openRead: () => Stream.value(bytes)),
  );
  expect(staged.status, LocalImportStatus.awaitingConfirmation, reason: staged.errorCode);
  final imported = await library.commitLocalImport(staged.id);
  expect(imported.status, LocalImportStatus.succeeded, reason: imported.errorCode);
  return imported;
}
