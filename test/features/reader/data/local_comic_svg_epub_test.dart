/// Exercises SVG resource MIME propagation through the real EPUB reader adapter.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';
import 'package:mg_read/features/reader/data/content_library_local_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an inline SVG-only EPUB supplies a PNG to the existing comic reader', () async {
    final root = await Directory.systemTemp.createTemp('mgread-svg-comic-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final archive = Archive();
    void add(String name, String value) => archive.addFile(ArchiveFile.bytes(name, utf8.encode(value)));
    add('mimetype', 'application/epub+zip');
    add('META-INF/container.xml', '<container><rootfiles><rootfile full-path="book.opf"/></rootfiles></container>');
    add(
      'book.opf',
      '<package version="3.0"><metadata><title>SVG comic</title></metadata>'
          '<manifest><item id="page" href="page.xhtml" media-type="application/xhtml+xml"/></manifest>'
          '<spine><itemref idref="page"/></spine></package>',
    );
    add(
      'page.xhtml',
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
          '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="60" viewBox="0 0 120 60">'
          '<rect width="120" height="60" fill="red"/></svg></body></html>',
    );
    final original = ZipEncoder().encode(archive);
    final preview = await library.prepareLocalImport(
      LocalImportInput(fileName: 'svg.epub', bytes: original.length, openRead: () => Stream.value(original)),
    );
    expect(preview.status, LocalImportStatus.awaitingConfirmation, reason: preview.errorCode);
    final imported = await library.commitLocalImport(preview.id);
    expect(imported.status, LocalImportStatus.succeeded, reason: imported.errorCode);
    final request = await ContentLibraryLocalReader(library).launch(imported.itemId!.value) as ComicReaderLaunchRequest;
    addTearDown(() => (request.dataSource as DisposableReaderDataSource).dispose());
    final catalog = await request.dataSource.loadChapterCatalog(request.bookId);
    final chapter = await request.dataSource.loadChapterContent(request.bookId, catalog.items.single.id);
    final bytes = await request.dataSource.loadImageBytes(request.bookId, chapter.chapterId, chapter.images.single.id);
    expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 120);
      expect(frame.image.height, 60);
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  });
}
