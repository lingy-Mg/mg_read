import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/local_documents/epub_local_document_parser.dart';
import 'package:mg_read/core/local_documents/local_document_models.dart';

void main() {
  late Directory temp;
  late Directory output;
  late EpubLocalDocumentParser parser;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mgread-epub-test-');
    output = Directory('${temp.path}/out');
    parser = const EpubLocalDocumentParser();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('EPUB3 respects spine order, nested nav fragments, rich blocks and images', () async {
    final file = await _epub(temp, <String, String>{
      'OPS/z-last.xhtml': _xhtml('''<h1>Last</h1><p>Tail</p>'''),
      'OPS/images/cover.png': 'png-data',
      'OPS/a-first.xhtml': _xhtml(
        '''<h1 id="start">Opening</h1><p>A <strong>bold</strong> <em>italic</em> <a href="z-last.xhtml#next">next</a></p><ul><li>one</li><li>two</li></ul><blockquote>quote</blockquote><table><tr><th>head</th><td>cell</td></tr></table><img src="images/cover.png" alt="cover"/>''',
      ),
      'OPS/nav.xhtml': _xhtml(
        '''<nav epub:type="toc"><ol><li><a href="a-first.xhtml#start">Start</a><ol><li><a href="z-last.xhtml#next">Last section</a></li></ol></li></ol></nav>''',
      ),
    }, opf: _opf3);

    final parsed = await parser.parse(source: file, output: output);

    expect(parsed.format, LocalDocumentFormat.epub);
    expect(parsed.title, 'Test book');
    expect(parsed.chapters.map((c) => c.href).take(2), ['OPS/a-first.xhtml', 'OPS/z-last.xhtml']);
    expect(parsed.chapters.first.title, 'Opening');
    expect(parsed.navigation.single.label, 'Start');
    expect(parsed.navigation.single.fragment, 'start');
    expect(parsed.navigation.single.children.single.fragment, 'next');
    final first = await _chapter(parsed.chapters.first, output);
    final types = (first['blocks'] as List).map((b) => (b as Map)['type']).toList();
    expect(types, containsAll(['heading', 'paragraph', 'listItem', 'quote', 'row', 'image']));
    final paragraph = (first['blocks'] as List).cast<Map>().firstWhere((b) => b['type'] == 'paragraph');
    expect((paragraph['spans'] as List).cast<Map>().any((span) => span['bold'] == true), isTrue);
    expect((paragraph['spans'] as List).cast<Map>().any((span) => span['href'] == 'OPS/z-last.xhtml#next'), isTrue);
    expect(parsed.resources.single.mimeType, 'image/png');
    expect(parsed.coverResourceId, parsed.resources.single.id);
    expect(await File('${output.path}/${parsed.resources.single.file}').exists(), isTrue);
  });

  test('EPUB2 reads NCX nested points and continues a split spine section', () async {
    final huge = 'ab ' * 33000;
    final file = await _epub(temp, <String, String>{
      'OPS/chapter.xhtml': _xhtml('<h1 id="chapter">Chapter</h1><p>$huge</p>'),
      'OPS/toc.ncx':
          '''<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint><navLabel><text>Part</text></navLabel><content src="chapter.xhtml#chapter"/><navPoint><navLabel><text>Nested</text></navLabel><content src="chapter.xhtml#chapter"/></navPoint></navPoint></navMap></ncx>''',
    }, opf: _opf2);

    final parsed = await parser.parse(source: file, output: output);

    expect(parsed.chapters.length, greaterThan(1));
    expect(parsed.navigation.single.label, 'Part');
    expect(parsed.navigation.single.children.single.label, 'Nested');
    for (final chapter in parsed.chapters) {
      final payload = await _chapter(chapter, output);
      final blocks = (payload['blocks'] as List).cast<Map>();
      expect(blocks.fold<int>(0, (sum, block) => sum + ((block['text'] as String?)?.length ?? 0)), lessThanOrEqualTo(64000));
    }
  });

  test('long common path prefixes retain distinct chapter and resource identities', () async {
    const directory = 'very-long-shared-directory-prefix/';
    final opf = _opf3.replaceAll('a-first.xhtml', '${directory}first.xhtml').replaceAll('z-last.xhtml', '${directory}last.xhtml');
    final file = await _epub(temp, {
      'OPS/${directory}first.xhtml': _xhtml('<p>First <img src="one.png"/></p>'),
      'OPS/${directory}last.xhtml': _xhtml('<p>Last <img src="two.png"/></p>'),
      'OPS/${directory}one.png': 'first-image',
      'OPS/${directory}two.png': 'second-image',
    }, opf: opf);
    final parsed = await parser.parse(source: file, output: output);
    expect(parsed.chapters.map((entry) => entry.id).toSet().length, parsed.chapters.length);
    expect(parsed.resources.map((entry) => entry.id).toSet().length, parsed.resources.length);
    expect((await _chapter(parsed.chapters[0], output))['blocks'].toString(), contains('First'));
    expect((await _chapter(parsed.chapters[1], output))['blocks'].toString(), contains('Last'));
  });

  test('linear=no spine content remains available as an auxiliary chapter', () async {
    final file = await _epub(temp, <String, String>{
      'OPS/main.xhtml': _xhtml('<p><a href="notes.xhtml#n1">note</a></p>'),
      'OPS/notes.xhtml': _xhtml('<p id="n1">Footnote</p>'),
    }, opf: _opf3.replaceAll('<itemref idref="notes"/>', '<itemref idref="notes" linear="no"/>'));

    final parsed = await parser.parse(source: file, output: output);

    expect(parsed.chapters.map((c) => c.href).toList().sublist(2), ['OPS/main.xhtml', 'OPS/notes.xhtml']);
    expect(parsed.attributes['linearAuxiliaryContent'], 1);
  });

  test('font obfuscation warns while fixed layout, essential encryption and script-only content fail explicitly', () async {
    final base = <String, String>{'OPS/main.xhtml': _xhtml('<p>Text</p>')};
    final fontEncrypted = await _epub(
      temp,
      base,
      opf: _opf3,
      extra: {
        'META-INF/encryption.xml':
            '''<encryption><EncryptedData><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><CipherData><CipherReference URI="OPS/font.otf"/></CipherData></EncryptedData></encryption>''',
      },
    );
    final result = await parser.parse(source: fontEncrypted, output: output);
    expect(result.warnings.any((w) => w.contains('字体')), isTrue);

    final fixed = await _epub(
      temp,
      base,
      opf: _opf3.replaceAll('</metadata>', '<meta property="rendition:layout">pre-paginated</meta></metadata>'),
    );
    await _expectCode(parser, fixed, output, 'epub_fixed_layout');

    final encrypted = await _epub(
      temp,
      base,
      opf: _opf3,
      extra: {
        'META-INF/encryption.xml':
            '<encryption><EncryptedData><CipherData><CipherReference URI="OPS/main.xhtml"/></CipherData></EncryptedData></encryption>',
      },
    );
    await _expectCode(parser, encrypted, output, 'epub_drm_unsupported');

    final scripted = await _epub(temp, {
      'OPS/main.xhtml': _xhtml('<script>document.write("x")</script>'),
    }, opf: _opf3.replaceAll('media-type="application/xhtml+xml"/>', 'media-type="application/xhtml+xml" properties="scripted"/>'));
    await _expectCode(parser, scripted, output, 'epub_scripted_unsupported');
  });

  test('preflight rejects traversal, normalized duplicates and truncated ZIPs', () async {
    final traversal = await _epub(temp, {'../outside.txt': 'bad'}, opf: _opf3);
    await _expectCode(parser, traversal, output, 'epub_zip_path');

    final duplicate = await _zip(temp, [('mimetype', 'application/epub+zip'), ('OPS/a/../same', 'one'), ('OPS/same', 'two')]);
    await _expectCode(parser, duplicate, output, 'epub_zip_duplicate');

    final good = await _epub(temp, {'OPS/main.xhtml': _xhtml('<p>Text</p>')}, opf: _opf3);
    final bytes = await good.readAsBytes();
    final truncated = File('${temp.path}/truncated.epub')..writeAsBytesSync(bytes.sublist(0, bytes.length - 12));
    await _expectCode(parser, truncated, output, 'epub_zip_eocd');
  });

  test('malformed OPF, missing spine documents and CRC corruption fail closed', () async {
    final malformed = await _epub(temp, {'OPS/main.xhtml': _xhtml('<p>Text</p>')}, opf: '<package>');
    await _expectCode(parser, malformed, output, 'epub_xml_invalid');

    final missing = await _epub(temp, {'OPS/main.xhtml': _xhtml('<p>Text</p>')}, opf: _opf3.replaceAll('idref="main"', 'idref="absent"'));
    await _expectCode(parser, missing, output, 'epub_spine_missing_item');

    final good = await _epub(temp, {'OPS/main.xhtml': _xhtml('<p>CRC CHECK CONTENT</p>')}, opf: _opf3);
    final damaged = await _corruptEntry(good, 'OPS/main.xhtml', temp);
    await _expectCode(parser, damaged, output, 'epub_zip_invalid');
  });
}

const _opf3 =
    '''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">id</dc:identifier><dc:title>Test book</dc:title><dc:creator>Author</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="last" href="z-last.xhtml" media-type="application/xhtml+xml"/><item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/><item id="first" href="a-first.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="main" href="main.xhtml" media-type="application/xhtml+xml"/><item id="notes" href="notes.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="first"/><itemref idref="last"/><itemref idref="main"/><itemref idref="notes"/></spine></package>''';
const _opf2 =
    '''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="book"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book">id</dc:identifier><dc:title>Test book</dc:title><dc:creator>Author</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="chap" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="toc"><itemref idref="chap"/></spine></package>''';

String _xhtml(String body) =>
    '''<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Test</title></head><body>$body</body></html>''';

Future<File> _epub(Directory temp, Map<String, String> files, {required String opf, Map<String, String> extra = const {}}) => _zip(temp, [
  ('mimetype', 'application/epub+zip'),
  (
    'META-INF/container.xml',
    '''<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',
  ),
  ...<String, String>{
    'OPS/a-first.xhtml': _xhtml('<p>First</p>'),
    'OPS/z-last.xhtml': _xhtml('<p>Last</p>'),
    'OPS/main.xhtml': _xhtml('<p>Main</p>'),
    'OPS/notes.xhtml': _xhtml('<p>Notes</p>'),
    ...files,
  }.entries.map((e) => (e.key, e.value)),
  ('OPS/package.opf', opf),
  ...extra.entries.map((e) => (e.key, e.value)),
]);

Future<File> _zip(Directory temp, List<(String, String)> entries) async {
  final archive = Archive();
  for (final (name, value) in entries) {
    archive.addFile(ArchiveFile.bytes(name, utf8.encode(value)));
  }
  final bytes = ZipEncoder().encode(archive);
  final file = File('${temp.path}/book-${DateTime.now().microsecondsSinceEpoch}-${entries.length}.epub');
  await file.writeAsBytes(bytes);
  return file;
}

Future<File> _corruptEntry(File source, String entryName, Directory temp) async {
  final bytes = await source.readAsBytes();
  final view = ByteData.sublistView(bytes);
  var dataOffset = -1;
  for (var i = 0; i < bytes.length - 30; i++) {
    if (view.getUint32(i, Endian.little) != 0x04034b50) continue;
    final nameLength = view.getUint16(i + 26, Endian.little);
    final extraLength = view.getUint16(i + 28, Endian.little);
    final name = utf8.decode(bytes.sublist(i + 30, i + 30 + nameLength));
    if (name == entryName) {
      dataOffset = i + 30 + nameLength + extraLength;
      break;
    }
  }
  expect(dataOffset, greaterThanOrEqualTo(0));
  bytes[dataOffset + 1] ^= 0x40;
  final corrupted = File('${temp.path}/corrupted.epub')..writeAsBytesSync(bytes);
  return corrupted;
}

Future<Map<String, Object?>> _chapter(LocalDocumentChapter chapter, Directory output) async =>
    (jsonDecode(await File('${output.path}/${chapter.contentFile}').readAsString()) as Map).cast<String, Object?>();

Future<void> _expectCode(EpubLocalDocumentParser parser, File source, Directory output, String code) async {
  try {
    await parser.parse(source: source, output: output);
    fail('Expected LocalDocumentException($code)');
  } on LocalDocumentException catch (e) {
    expect(e.code, code);
  }
}
