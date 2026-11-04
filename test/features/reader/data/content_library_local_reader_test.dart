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

  test('EPUB launch exposes rich blocks, nested navigation, resources and links', () async {
    final epub = _epubBytes();
    final staged = await library.prepareLocalImport(
      LocalImportInput(fileName: 'book.epub', bytes: epub.length, openRead: () => Stream.value(epub)),
    );
    expect(staged.status, LocalImportStatus.awaitingConfirmation);
    final imported = await library.commitLocalImport(staged.id);
    expect(imported.status, LocalImportStatus.succeeded, reason: imported.errorCode);
    final request = await ContentLibraryLocalReader(library).launch(imported.itemId!.value);
    expect(request, isA<DocumentReaderLaunchRequest>());
    final document = request as DocumentReaderLaunchRequest;
    expect(document.dataSource, isA<DisposableReaderDataSource>());
    expect(document.navigationEntries.map((entry) => entry.depth), [0, 1]);
    expect(document.navigationEntries.last.anchor, 'target');
    final chapters = await document.dataSource.loadChapterCatalog(document.bookId);
    final chapter = await document.dataSource.loadChapter(document.bookId, chapters.items.first.id);
    expect(chapter.blocks.map((block) => block.type), containsAll(['heading', 'paragraph', 'image']));
    final paragraph = chapter.blocks.firstWhere((block) => block.type == 'paragraph');
    expect(paragraph.spans.any((span) => span.bold), isTrue);
    final image = chapter.blocks.firstWhere((block) => block.type == 'image');
    expect(await document.dataSource.loadResourceBytes(image.resourceId!), isNotEmpty);
    final target = await document.dataSource.resolveLink(chapter.chapterId, 'chapter.xhtml#target');
    expect(target?.anchor, 'target');
    await (document.dataSource as DisposableReaderDataSource).dispose();
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

List<int> _epubBytes() {
  final archive = Archive();
  void add(String path, String value) => archive.addFile(ArchiveFile.bytes(path, utf8.encode(value)));
  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '''<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
  );
  add(
    'OPS/package.opf',
    '''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">id</dc:identifier><dc:title>Local EPUB</dc:title><dc:creator>Author</dc:creator></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/></manifest><spine><itemref idref="chapter"/></spine></package>''',
  );
  add(
    'OPS/chapter.xhtml',
    '''<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Chapter</title></head><body><h1 id="target">Chapter</h1><p>A <strong>bold</strong> paragraph.</p><img src="cover.png"/></body></html>''',
  );
  add(
    'OPS/nav.xhtml',
    '''<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml#target">Chapter</a><ol><li><a href="chapter.xhtml#target">Nested</a></li></ol></li></ol></nav></body></html>''',
  );
  archive.addFile(ArchiveFile.bytes('OPS/cover.png', [1, 2, 3, 4]));
  return ZipEncoder().encode(archive);
}
