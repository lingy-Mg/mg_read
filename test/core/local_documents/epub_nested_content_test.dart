import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';

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

  test('nested pure text XHTML keeps rich spans, flat blocks, links, and cover metadata', () async {
    final source = await _epub(
      root,
      <String, String>{
        'OPS/text/one.xhtml': _xhtml('''
        <section id="part-one"><div class="chapter"><h1>First</h1>
          <p id="intro">A <strong>bold</strong> and <em>emphatic</em> <a href="/OPS/text/two.xhtml#target">next</a>.</p>
          <p>Footnote <a epub:type="noteref" href="notes.xhtml#note-1">1</a></p>
        </div></section>
      '''),
        'OPS/text/two.xhtml': _xhtml('<section><h1 id="target">Second</h1><p>Destination.</p></section>'),
        'OPS/text/notes.xhtml': _xhtml('<section><p id="note-1">Footnote body.</p></section>'),
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

    expect(session.readingKind, LocalDocumentReadingKind.text);
    expect(session.chapterCount, 3);
    expect(blocks.map((block) => block['type']), containsAll(['heading', 'paragraph']));
    expect(blocks.every((block) => block['type'] == 'heading' || block['type'] == 'paragraph'), isTrue);
    expect(blocks.every((block) => (block['children'] as List? ?? const []).isEmpty), isTrue);
    final introductory = blocks.firstWhere((block) => block['type'] == 'paragraph');
    final spans = (introductory['spans'] as List).whereType<Map>().toList();
    expect(spans.map((span) => span['text']).join(), contains('bold'));
    expect(spans.any((span) => span['bold'] == true), isTrue);
    expect(spans.any((span) => span['italic'] == true), isTrue);
    expect(spans.any((span) => span['href'] == 'OPS/text/two.xhtml#target'), isTrue);
    final coverBytes = await session.readCover();
    expect(coverBytes, isNotNull);
    // A packaged SVG cover wrapper resolves to its controlled raster image,
    // rather than leaving an unresolved relative image URL in display bytes.
    expect(utf8.decode(coverBytes!), 'not-a-real-image-but-retained-by-epub');

    final target = session.chapterAt(1)!;
    final link = await session.resolveLink(chapter.id, '/OPS/text/two.xhtml#target');
    expect(link?.chapterId, target.id);
    expect(link?.anchor, 'target');
    expect(await session.resolveLink(chapter.id, 'notes.xhtml#note-1'), isNotNull);
    expect(await session.resolveLink(chapter.id, '../text/two.xhtml#target'), isNotNull);

    expect(await session.resolveLink(chapter.id, 'https://example.invalid/book'), isNull);
    expect(await session.resolveLink(chapter.id, '../../outside.xhtml'), isNull);
  });

  test('independent SVG cover spine page is removed from a pure text EPUB', () async {
    final source = await _epub(
      root,
      {
        'OPS/text/wrap0000.xhtml': _xhtml('''
          <div class="x-ebookmaker-cover">
            <svg xmlns="http://www.w3.org/2000/svg" height="100%" viewBox="0 0 1600 2400"
                 xmlns:xlink="http://www.w3.org/1999/xlink">
              <image width="1600" height="2400" xlink:href="../images/cover.png"/>
            </svg>
          </div>
        '''),
        'OPS/text/chapter.xhtml': _xhtml('<h1>Chapter</h1><p>Readable content.</p>'),
        'OPS/images/cover.png': 'not-a-real-image-but-retained-by-epub',
      },
      opf: '''<?xml version="1.0"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Wrapper Image</dc:title></metadata>
        <manifest>
          <item id="cover-spine" href="text/wrap0000.xhtml" media-type="application/xhtml+xml"/>
          <item id="chapter" href="text/chapter.xhtml" media-type="application/xhtml+xml"/>
          <item id="cover-image" href="images/cover.png" media-type="image/png" properties="cover-image"/>
        </manifest>
        <spine><itemref idref="cover-spine"/><itemref idref="chapter"/></spine>
      </package>''',
    );
    final bytes = await source.readAsBytes();
    final prepared = await library.prepareLocalImport(
      LocalImportInput(fileName: 'wrapper.epub', bytes: bytes.length, openRead: () => Stream.value(bytes)),
    );
    expect(prepared.status, LocalImportStatus.awaitingConfirmation, reason: prepared.errorCode);
    final committed = await library.commitLocalImport(prepared.id);
    expect(committed.status, LocalImportStatus.succeeded, reason: committed.errorCode);
    final session = (await library.openLocalDocumentSession(committed.itemId!))!;
    addTearDown(session.close);

    expect(session.readingKind, LocalDocumentReadingKind.text);
    expect(session.chapterCount, 1);
    expect(session.chapterAt(0)?.href, 'OPS/text/chapter.xhtml');
    final first = session.chapterAt(0)!;
    final chapter = await session.readChapter(first.id);
    expect((chapter['blocks'] as List).whereType<Map>().map((block) => block['type']), ['heading', 'paragraph']);
    expect(await session.readCover(), isNotEmpty);
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
    'official reflowable EPUB samples classify through ContentLibrary',
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
        if (prepared.status == LocalImportStatus.failed && prepared.errorCode == 'epub_mixed_content_unsupported') continue;
        expect(prepared.status, LocalImportStatus.awaitingConfirmation, reason: '$path: ${prepared.errorCode}');
        final committed = await library.commitLocalImport(prepared.id);
        expect(committed.status, LocalImportStatus.succeeded, reason: '$path: ${committed.errorCode}');
        final session = (await library.openLocalDocumentSession(committed.itemId!))!;
        try {
          expect(session.chapterCount, greaterThan(0), reason: path);
          expect(session.readingKind, isNotNull, reason: path);
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
          if (session.readingKind == LocalDocumentReadingKind.text) {
            expect(textBlocks, greaterThan(0), reason: path);
            expect(imageBlocks, 0, reason: path);
          } else {
            expect(textBlocks, 0, reason: path);
            expect(imageBlocks, greaterThan(0), reason: path);
          }
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
