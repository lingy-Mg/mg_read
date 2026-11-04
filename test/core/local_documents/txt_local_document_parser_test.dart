import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/local_documents/local_document_models.dart';
import 'package:mg_read/core/local_documents/txt_local_document_parser.dart';

void main() {
  late Directory temp;
  late TxtLocalDocumentParser parser;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('txt_parser_test_');
    parser = const TxtLocalDocumentParser();
  });
  tearDown(() async => temp.delete(recursive: true));

  Future<ParsedLocalDocument> parseBytes(
    List<int> bytes, {
    LocalDocumentParseOptions options = const LocalDocumentParseOptions(),
    String name = 'book.txt',
  }) async {
    final source = File('${temp.path}/$name');
    await source.writeAsBytes(bytes);
    return parser.parse(source: source, output: Directory('${temp.path}/out'), options: options);
  }

  Future<Map<String, dynamic>> chapter(ParsedLocalDocument doc, [int index = 0]) async =>
      jsonDecode(await File('${temp.path}/out/${doc.chapters[index].contentFile}').readAsString()) as Map<String, dynamic>;

  test('normalizes BOM and CR variants while preserving whitespace', () async {
    final doc = await parseBytes([0xef, 0xbb, 0xbf, ...utf8.encode('  first  \rsecond\r\n\n')]);
    final blocks = (await chapter(doc))['blocks'] as List;
    expect(blocks.map((b) => b['text']).join(), '  first  \nsecond\n\n');
    expect(doc.encoding, 'utf-8');
  });

  test('decodes UTF-16 and GB18030 four-byte sequence at a chunk boundary', () async {
    final utf16 = [
      0xff,
      0xfe,
      ...'章\n'.codeUnits.expand((u) => [u & 0xff, u >> 8]),
    ];
    final utf16Doc = await parseBytes(utf16, name: 'u16.txt');
    expect((await chapter(utf16Doc))['blocks'][0]['text'], '章\n');
    final noBomUtf16 = 'ABCDEFG章\n'.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]).toList();
    final detectedUtf16 = await parseBytes(noBomUtf16, name: 'u16-detected.txt');
    expect(detectedUtf16.encoding, 'utf-16le');
    final boundaryText = '${'A' * 32767}𠀀';
    final boundaryBytes = [
      0xff,
      0xfe,
      ...boundaryText.codeUnits.expand((unit) => [unit & 0xff, unit >> 8]),
    ];
    final boundaryDoc = await parseBytes(boundaryBytes, name: 'u16-boundary.txt');
    final boundaryBlocks = <dynamic>[];
    for (var i = 0; i < boundaryDoc.chapters.length; i++) {
      boundaryBlocks.addAll((await chapter(boundaryDoc, i))['blocks'] as List);
    }
    expect(boundaryBlocks.map((b) => b['text']).join(), boundaryText);
    final gb = [...List<int>.filled(65535, 0x41), 0x95, 0x32, 0x82, 0x36];
    final gbDoc = await parseBytes(
      gb,
      options: const LocalDocumentParseOptions(encoding: 'gb18030'),
      name: 'gb.txt',
    );
    final blocks = <dynamic>[];
    for (var i = 0; i < gbDoc.chapters.length; i++) {
      blocks.addAll((await chapter(gbDoc, i))['blocks'] as List);
    }
    expect(blocks.map((b) => b['text']).join().endsWith('𠀀'), isTrue);
    for (final item in gbDoc.chapters) {
      expect(await File('${temp.path}/out/${item.contentFile}').length(), lessThan(256 * 1024));
    }
  });

  test('strict malformed input fails and allowMalformed keeps replacement text', () async {
    await expectLater(
      parseBytes([0xc3, 0x28], options: const LocalDocumentParseOptions(encoding: 'utf-8')),
      throwsA(isA<LocalDocumentException>().having((e) => e.code, 'code', 'malformed_text')),
    );
    final doc = await parseBytes(
      [0xc3, 0x28],
      options: const LocalDocumentParseOptions(encoding: 'utf-8', allowMalformed: true),
      name: 'bad2.txt',
    );
    expect((await chapter(doc))['blocks'][0]['text'], '�(');
    await expectLater(
      parseBytes(
        [0x41, 0x00, 0x42],
        options: const LocalDocumentParseOptions(encoding: 'utf-16le'),
        name: 'odd-u16.txt',
      ),
      throwsA(isA<LocalDocumentException>().having((e) => e.code, 'code', 'malformed_text')),
    );
  });

  test('chapter reparsing preserves paragraph anchors and none keeps one chapter', () async {
    final source = File('${temp.path}/split.txt')..writeAsBytesSync(utf8.encode('preface\n第1章 开始\n正文\n第2章 后续\n结尾'));
    final split = await parser.parse(source: source, output: Directory('${temp.path}/out'));
    expect(split.chapters.length, 3);
    final splitBlocks = <Map<String, dynamic>>[];
    for (var i = 0; i < split.chapters.length; i++) {
      splitBlocks.addAll(((await chapter(split, i))['blocks'] as List).cast<Map<String, dynamic>>());
    }
    final whole = await parser.parse(
      source: source,
      output: Directory('${temp.path}/whole'),
      options: const LocalDocumentParseOptions(chapterRule: 'none'),
    );
    final content = jsonDecode(await File('${temp.path}/whole/${whole.chapters.single.contentFile}').readAsString()) as Map;
    final wholeBlocks = (content['blocks'] as List).cast<Map<String, dynamic>>();
    expect(splitBlocks.map((b) => b['id']).toList(), wholeBlocks.map((b) => b['id']).toList());
    expect(whole.chapters.single.startOffset, 0);
  });

  test('bounded reading segments preserve the logical TXT table of contents', () async {
    final doc = await parseBytes(utf8.encode('第一章 开始\n${'正文很长。' * 18000}\n第二章 结束\n结尾\n'));
    expect(doc.chapters.length, greaterThan(2));
    expect(doc.logicalChapterCount, 2);
    expect(doc.navigation.map((entry) => entry.label), ['第一章 开始', '第二章 结束']);
    final whole = await parseBytes(
      utf8.encode('正文。' * 18000),
      name: 'whole.txt',
      options: const LocalDocumentParseOptions(chapterRule: 'none'),
    );
    expect(whole.chapters.length, greaterThan(1));
    expect(whole.logicalChapterCount, 1);
  });
}
