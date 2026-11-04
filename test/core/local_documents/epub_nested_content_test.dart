import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/reader/data/content_library_local_reader.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';

void main() {
  late Directory root;
  late ContentLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mgread-epub-nested-');
    library = await ContentLibrary.open(dataRoot: root);
  });

  tearDown(() async {
    await library.close();
    await root.delete(recursive: true);
  });

  test('nested XHTML keeps structure, inline styles, media, and root-relative links through reader adapter', () async {
    final source = await _epub(
      root,
      <String, String>{
        'OPS/text/one.xhtml': _xhtml('''
        <section id="part-one"><div class="chapter"><h1>First</h1>
          <p id="intro">A <strong>bold</strong> and <em>emphatic</em> <a href="/OPS/text/two.xhtml#target">next</a>.</p>
          <p>Picture <img src="../images/figure.svg" alt="diagram"/> inline.</p>
          <p>Footnote <a epub:type="noteref" href="notes.xhtml#note-1">1</a></p>
        </div></section>
      '''),
        'OPS/text/two.xhtml': _xhtml('<section><h1 id="target">Second</h1><p>Destination.</p></section>'),
        'OPS/text/notes.xhtml': _xhtml('<section><p id="note-1">Footnote body.</p></section>'),
        'OPS/images/figure.svg':
            '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><title>Triangle</title><path d="M0 10L5 0L10 10Z"/></svg>''',
        'OPS/images/cover-wrapper.svg':
            '''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 30"><image xlink:href="cover.png" width="20" height="30"/></svg>''',
        'OPS/images/cover.png': 'not-a-real-image-but-retained-by-epub',
      },
      opf: '''<?xml version="1.0"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Nested Book</dc:title><dc:creator>Author</dc:creator></metadata>
        <manifest>
          <item id="one" href="text/one.xhtml" media-type="application/xhtml+xml"/>
          <item id="two" href="text/two.xhtml" media-type="application/xhtml+xml"/>
          <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
          <item id="figure" href="images/figure.svg" media-type="image/svg+xml"/>
          <item id="cover" href="images/cover-wrapper.svg" media-type="image/svg+xml" properties="cover-image"/>
          <item id="cover-png" href="images/cover.png" media-type="image/png"/>
        </manifest><spine><itemref idref="one"/><itemref idref="two"/><itemref idref="notes"/></spine>
      </package>''',
    );

    final bytes = await source.readAsBytes();
    final prepared = await library.prepareLocalImport(
      LocalImportInput(fileName: 'nested.epub', bytes: bytes.length, openRead: () => Stream.value(bytes)),
    );
    expect(prepared.status, LocalImportStatus.awaitingConfirmation, reason: prepared.errorCode);
    final committed = await library.commitLocalImport(prepared.id);
    expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
    final session = (await library.openLocalDocumentSession(committed.itemId!))!;
    addTearDown(session.close);
    final chapter = session.chapterAt(0)!;
    final body = await session.readChapter(chapter.id);
    final blocks = (body['blocks'] as List).whereType<Map>().toList();

    expect(blocks.map((block) => block['type']), containsAll(['heading', 'paragraph', 'image']));
    final introductory = blocks.firstWhere((block) => block['type'] == 'paragraph');
    final spans = (introductory['spans'] as List).whereType<Map>().toList();
    expect(spans.map((span) => span['text']).join(), contains('bold'));
    expect(spans.any((span) => span['bold'] == true), isTrue);
    expect(spans.any((span) => span['italic'] == true), isTrue);
    expect(spans.any((span) => span['href'] == 'OPS/text/two.xhtml#target'), isTrue);
    final image = blocks.firstWhere((block) => block['type'] == 'image');
    final resourceId = image['resourceId'] as String;
    expect(await session.readResource(resourceId), isNotEmpty);
    final coverBytes = await session.readCover();
    expect(coverBytes, isNotNull);
    // A packaged SVG cover wrapper resolves to its controlled raster image,
    // rather than leaving an unresolved relative image URL in display bytes.
    expect(utf8.decode(coverBytes!), 'not-a-real-image-but-retained-by-epub');

    final rawReader = ContentLibraryLocalReader(library);
    final request = await rawReader.launch(committed.itemId!.value) as DocumentReaderLaunchRequest;
    addTearDown(() async => (request.dataSource as DisposableReaderDataSource).dispose());
    final adapter = request.dataSource;
    final adapted = await adapter.loadChapter(committed.itemId!.value, chapter.id);
    expect(adapted.blocks.map((block) => block.type), containsAll(['heading', 'paragraph', 'image']));
    final target = session.chapterAt(1)!;
    final link = await adapter.resolveLink(chapter.id, '/OPS/text/two.xhtml#target');
    expect(link?.chapterId, target.id);
    expect(link?.anchor, 'target');
    expect(await session.resolveLink(chapter.id, 'notes.xhtml#note-1'), isNotNull);
    expect(await session.resolveLink(chapter.id, '../text/two.xhtml#target'), isNotNull);

    expect(await session.resolveLink(chapter.id, 'https://example.invalid/book'), isNull);
    expect(await session.resolveLink(chapter.id, '../../outside.xhtml'), isNull);
  });

  test('malformed container and non-ZIP input fail without publishing a shelf item', () async {
    final malformed = await _epub(root, {'OPS/text/one.xhtml': _xhtml('<p>valid</p>')}, opf: '<package>');
    final malformedBytes = await malformed.readAsBytes();
    final badOpf = await library.prepareLocalImport(
      LocalImportInput(fileName: 'malformed.epub', bytes: malformedBytes.length, openRead: () => Stream.value(malformedBytes)),
    );
    expect(badOpf.status, LocalImportStatus.failed);
    expect(await library.loadShelfProjection(), isEmpty);

    const garbage = <int>[0, 1, 2, 3, 4];
    final badZip = await library.prepareLocalImport(
      LocalImportInput(fileName: 'broken.epub', bytes: garbage.length, openRead: () => Stream.value(garbage)),
    );
    expect(badZip.status, LocalImportStatus.failed);
    expect(await library.loadShelfProjection(), isEmpty);
  });

  test(
    'official reflowable EPUB samples import through ContentLibrary',
    () async {
      final samples = <String>[
        '.dart_tool/ai-checks/local-samples/childrens-literature.epub',
        '.dart_tool/ai-checks/local-samples/moby-dick.epub',
        '.dart_tool/ai-checks/local-samples/wasteland.epub',
      ];
      for (final path in samples) {
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        final prepared = await library.prepareLocalImport(
          LocalImportInput(
            fileName: path.split(Platform.pathSeparator).last,
            bytes: bytes.length,
            openRead: () => Stream<List<int>>.value(bytes),
          ),
        );
        expect(prepared.status, LocalImportStatus.awaitingConfirmation, reason: '$path: ${prepared.errorCode}');
        final committed = await library.commitLocalImport(prepared.id);
        expect(committed.status, LocalImportStatus.succeeded, reason: '$path: ${committed.errorCode}');
        final session = (await library.openLocalDocumentSession(committed.itemId!))!;
        try {
          expect(session.chapterCount, greaterThan(0), reason: path);
          var textBlocks = 0;
          var imageBlocks = 0;
          for (final chapter in session.chapters(limit: session.chapterCount)) {
            final payload = await session.readChapter(chapter.id);
            final blocks = (payload['blocks'] as List).whereType<Map>();
            textBlocks += blocks.where((block) {
              return block['type'] != 'image' && ((block['text'] as String?)?.trim().isNotEmpty ?? false);
            }).length;
            imageBlocks += blocks.where((block) => block['type'] == 'image').length;
          }
          expect(textBlocks, greaterThan(0), reason: path);
          // Keep the real-sample evidence compact in the test output.
          // ignore: avoid_print
          print(
            'EPUB sample ${file.uri.pathSegments.last}: chapters=${session.chapterCount}, navigation=${session.navigation.length}, imageBlocks=$imageBlocks',
          );
        } finally {
          await session.close();
        }
      }
    },
    skip:
        !File('.dart_tool/ai-checks/local-samples/childrens-literature.epub').existsSync() &&
            !File('.dart_tool/ai-checks/local-samples/moby-dick.epub').existsSync() &&
            !File('.dart_tool/ai-checks/local-samples/wasteland.epub').existsSync()
        ? 'Run with IDPF release samples under .dart_tool/ai-checks/local-samples.'
        : false,
  );
}

String _xhtml(String body) =>
    '''<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Test</title></head><body>$body</body></html>''';

Future<File> _epub(Directory root, Map<String, String> files, {required String opf}) async {
  final archive = Archive();
  void add(String path, String contents) => archive.addFile(ArchiveFile.bytes(path, utf8.encode(contents)));
  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '''<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
  );
  for (final entry in files.entries) {
    add(entry.key, entry.value);
  }
  add('OPS/package.opf', opf);
  final path = '${root.path}/nested.epub';
  final file = File(path);
  await file.writeAsBytes(ZipEncoder().encode(archive));
  return file;
}
