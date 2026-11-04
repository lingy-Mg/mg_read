/// Bounded EPUB2/3 static-content parser. It reads a ZIP on disk, writes only
/// sanitized document JSON and packaged resources into the caller's staging
/// directory, and never executes scripts or follows external references.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import 'local_document_models.dart';
import 'local_document_disk_space.dart';

part 'epub_local_document_markup.dart';

const _maxContainer = 16 * 1024 * 1024;
const _maxXhtml = 16 * 1024 * 1024;
const _maxMetadata = 4 * 1024 * 1024;
const _maxResource = 32 * 1024 * 1024;
const _maxBlocks = 200000;
const _maxDepth = 128;
const _maxNodes = 500000;

final class EpubLocalDocumentParser implements LocalDocumentParser {
  const EpubLocalDocumentParser();

  @override
  Future<ParsedLocalDocument> parse({
    required File source,
    required Directory output,
    LocalDocumentParseOptions options = const LocalDocumentParseOptions(),
    LocalDocumentCancellation? cancellation,
    LocalDocumentProgress? onProgress,
  }) async {
    final cancel = cancellation ?? LocalDocumentCancellation();
    cancel.check();
    final sourceLength = await source.length();
    if (sourceLength <= 0 || sourceLength > localDocumentMaxFileBytes) {
      throw const LocalDocumentException('epub_source_size');
    }
    await output.create(recursive: true);
    final preflight = await _preflightZip(source, sourceLength, cancel);
    final available = await availableLocalDocumentBytes(output);
    final estimatedOutput = preflight.values.fold<int>(0, (sum, entry) => sum + entry.size) * 3;
    if (available != null && available < estimatedOutput + 16 * 1024 * 1024) throw const LocalDocumentException('disk_full');
    final decoder = ZipDecoder();
    final zipInput = InputFileStream(source.path);
    try {
      late final Archive archive;
      try {
        archive = decoder.decodeStream(zipInput, verify: true, throwOnError: true);
      } on Object catch (error) {
        throw LocalDocumentException('epub_zip_invalid', _short(error));
      }
      if (archive.files.length != preflight.length) {
        throw const LocalDocumentException('epub_zip_directory_mismatch');
      }
      final byName = <String, ArchiveFile>{};
      var expanded = 0;
      var checked = 0;
      for (final entry in archive.files) {
        cancel.check();
        final name = _normalizeZipPath(entry.name);
        if (name == null || entry.isSymbolicLink || entry.isDirectory) continue;
        final record = preflight[name];
        if (record == null || entry.size != record.size || entry.crc32 != record.crc) {
          throw LocalDocumentException('epub_zip_directory_mismatch', entry.name);
        }
        final allowed = _entryLimit(name, _mediaType(name));
        if (entry.size < 0 || entry.size > allowed) {
          throw LocalDocumentException('epub_entry_size', name);
        }
        expanded += entry.size;
        if (expanded > localDocumentMaxExpandedBytes) throw const LocalDocumentException('epub_expanded_size');
        Uint8List? bytes;
        try {
          bytes = entry.readBytes();
        } on Object catch (error) {
          throw LocalDocumentException('epub_zip_invalid', _short(error));
        }
        if (bytes == null || bytes.length != record.size || getCrc32(bytes) != record.crc) {
          throw LocalDocumentException('epub_crc', name);
        }
        _releaseZipCache(entry);
        byName[name] = entry;
        checked++;
        if (checked > localDocumentMaxEntries) throw const LocalDocumentException('epub_entry_count');
        onProgress?.call('epub_preflight', checked, preflight.length);
      }
      if (!byName.containsKey('META-INF/container.xml')) throw const LocalDocumentException('epub_container_missing');
      final container = _xmlBytes(_bytes(byName['META-INF/container.xml']!, _maxMetadata, 'container'), _maxMetadata, 'container');
      final rootfile = container.rootElement.findAllElements('rootfile').firstOrNull;
      final opfHref = rootfile?.getAttribute('full-path');
      if (opfHref == null) throw const LocalDocumentException('epub_container_invalid');
      final opfPath = _resolvePath('', opfHref);
      if (opfPath == null) throw const LocalDocumentException('epub_opf_path');
      final opfEntry = byName[opfPath];
      if (opfEntry == null) throw const LocalDocumentException('epub_opf_missing');
      final opf = _xmlBytes(_bytes(opfEntry, _maxMetadata, 'opf'), _maxMetadata, 'opf');
      final package = opf.rootElement;
      final metadataNode = package.findAllElements('metadata').firstOrNull;
      final meta = _metadata(metadataNode);
      final manifestNode = package.findAllElements('manifest').firstOrNull;
      final spineNode = package.findAllElements('spine').firstOrNull;
      if (manifestNode == null || spineNode == null) throw const LocalDocumentException('epub_opf_invalid');
      final manifest = <String, _ManifestItem>{};
      for (final item in manifestNode.findAllElements('item')) {
        final id = item.getAttribute('id'), href = item.getAttribute('href'), type = item.getAttribute('media-type');
        if (id == null || href == null || type == null || manifest.containsKey(id)) {
          throw const LocalDocumentException('epub_manifest_invalid');
        }
        final path = _resolvePath(_dirOf(opfPath), href);
        if (path == null) throw LocalDocumentException('epub_manifest_path', href);
        manifest[id] = _ManifestItem(
          id,
          href,
          path,
          type.toLowerCase(),
          item.getAttribute('properties') ?? '',
          fallback: item.getAttribute('fallback'),
        );
      }
      // Check encrypted font resources separately for a gentle fallback notice.
      final warnings = <String>[];
      final encryption = byName['META-INF/encryption.xml'];
      if (encryption != null) {
        final encXml = _xmlBytes(_bytes(encryption, _maxMetadata, 'encryption'), _maxMetadata, 'encryption');
        for (final encrypted in encXml.findAllElements('EncryptedData')) {
          final uri = encrypted.findAllElements('CipherReference').firstOrNull?.getAttribute('URI') ?? '';
          final isFont = ['.otf', '.ttf', '.woff', '.woff2'].any(uri.toLowerCase().endsWith);
          if (!isFont) throw LocalDocumentException('epub_drm_unsupported', uri);
        }
        if (encXml.findAllElements('EncryptedData').any((e) {
          final uri = e.findAllElements('CipherReference').firstOrNull?.getAttribute('URI') ?? '';
          return ['.otf', '.ttf', '.woff', '.woff2'].any(uri.toLowerCase().endsWith);
        })) {
          warnings.add('字体使用了 EPUB 字体混淆，已忽略并使用阅读器字体。');
        }
      }
      final rendition = _metaProperty(package, 'rendition:layout');
      if (metadataNode
              ?.findAllElements('meta')
              .any(
                (element) =>
                    element.getAttribute('name') == 'fixed-layout' &&
                    ['true', 'yes'].contains(element.getAttribute('content')?.toLowerCase()),
              ) ==
          true) {
        throw const LocalDocumentException('epub_fixed_layout');
      }
      if (rendition == 'pre-paginated') throw const LocalDocumentException('epub_fixed_layout');
      final items = manifest.values.toList(growable: false);
      final spineRefs = spineNode.findAllElements('itemref').toList();
      if (spineRefs.isEmpty) throw const LocalDocumentException('epub_spine_missing');
      final spineIds = <String>{};
      final chapterItems = <_ManifestItem>[];
      final auxiliaryItems = <_ManifestItem>[];
      final fallbackIds = <String>{};
      for (final ref in spineRefs) {
        if ((ref.getAttribute('properties') ?? '').split(RegExp(r'\s+')).contains('rendition:layout-pre-paginated')) {
          throw const LocalDocumentException('epub_mixed_fixed_layout');
        }
        final idref = ref.getAttribute('idref');
        if (idref == null || !spineIds.add(idref)) throw const LocalDocumentException('epub_spine_invalid');
        final item = manifest[idref];
        if (item == null) throw LocalDocumentException('epub_spine_missing_item', idref);
        final auxiliary = ref.getAttribute('linear')?.toLowerCase() == 'no';
        var selected = item;
        if (!_isXhtml(item)) {
          final fallbackId = _manifestAttribute(item, 'fallback');
          final fallback = fallbackId == null ? null : manifest[fallbackId];
          if (fallback == null || !_isXhtml(fallback)) throw LocalDocumentException('epub_spine_unsupported', item.href);
          selected = fallback;
          fallbackIds.add(selected.id);
        }
        if (_isXhtml(selected)) {
          final entry = byName[selected.path];
          if (entry == null) throw LocalDocumentException('epub_spine_content_missing', selected.href);
          final selectedDoc = _xmlBytes(_bytes(entry, _maxXhtml, 'xhtml'), _maxXhtml, 'xhtml');
          final scripted =
              selected.properties.split(RegExp(r'\s+')).contains('scripted') || selectedDoc.findAllElements('script').isNotEmpty;
          if (scripted && !_hasStaticEpubContent(selectedDoc)) {
            final fallbackId = _manifestAttribute(selected, 'fallback');
            final fallback = fallbackId == null ? null : manifest[fallbackId];
            if (fallback == null ||
                !_isXhtml(fallback) ||
                byName[fallback.path] == null ||
                !_hasStaticEpubContent(_xmlBytes(_bytes(byName[fallback.path]!, _maxXhtml, 'xhtml'), _maxXhtml, 'xhtml'))) {
              throw LocalDocumentException('epub_scripted_unsupported', selected.href);
            }
            selected = fallback;
            fallbackIds.add(selected.id);
          } else if (scripted && warnings.length < 100) {
            warnings.add('书籍脚本已禁用，使用完整静态正文。');
          }
        }
        final destination = auxiliary ? auxiliaryItems : chapterItems;
        if (!destination.any((e) => e.path == selected.path)) destination.add(selected);
      }
      chapterItems.addAll(auxiliaryItems.where((aux) => !chapterItems.any((linear) => linear.path == aux.path)));
      if (chapterItems.isEmpty) throw const LocalDocumentException('epub_spine_missing');

      // A pre-paginated XHTML item outside spine or a fixed-layout item overrides
      // the package layout; mixed layout does not silently become reflowable.
      for (final item in items.where(_isXhtml)) {
        final bytes = byName[item.path];
        if (bytes == null) continue;
        final doc = _xmlBytes(_bytes(bytes, _maxXhtml, 'xhtml'), _maxXhtml, 'xhtml');
        if (_metaProperty(doc.rootElement, 'rendition:layout') == 'pre-paginated') {
          throw LocalDocumentException('epub_mixed_fixed_layout', item.href);
        }
      }

      final navItem = items.where((item) => item.properties.split(RegExp(r'\s+')).contains('nav')).firstOrNull;
      final ncxId = spineNode.getAttribute('toc');
      final tocItem = navItem ?? (ncxId == null ? null : manifest[ncxId]);
      final chapterMap = <String, String>{};
      final chapterOutput = <LocalDocumentChapter>[];
      final resources = <LocalDocumentResource>[];
      final resourceByPath = <String, LocalDocumentResource>{};
      String? coverId;
      for (var i = 0; i < chapterItems.length; i++) {
        cancel.check();
        final item = chapterItems[i];
        final chapterId = _stableId('ch', item.path);
        chapterMap[item.path] = chapterId;
        final entry = byName[item.path];
        if (entry == null) throw LocalDocumentException('epub_spine_content_missing', item.href);
        final doc = _xmlBytes(_bytes(entry, _maxXhtml, 'xhtml'), _maxXhtml, 'xhtml');
        final css = _stylesFor(doc, item, byName, opfPath, warnings);
        final body = doc.rootElement.findAllElements('body').firstOrNull ?? doc.rootElement;
        final builder = _BlockBuilder(
          output.path,
          item.path,
          chapterId,
          css,
          items,
          byName,
          _dirOf(opfPath),
          resourceByPath,
          resources,
          warnings,
        );
        builder.walkChildren(body, const _InheritedStyle(), 0);
        if (builder.blocks.length > _maxBlocks) throw const LocalDocumentException('epub_block_count');
        final sectionTitle =
            builder.blocks.where((block) => block['type'] == 'heading').map((block) => block['text'] as String).firstOrNull ?? item.href;
        final split = _splitBlocks(builder.blocks, chapterId, item.href, item.path, i, sectionTitle);
        for (var j = 0; j < split.length; j++) {
          final part = split[j];
          final filename = 'chapters/${chapterId}_${j.toString().padLeft(4, '0')}.json';
          final file = File('${output.path}${Platform.pathSeparator}${filename.replaceAll('/', Platform.pathSeparator)}');
          await file.parent.create(recursive: true);
          await file.writeAsString(
            jsonEncode({'chapterId': j == 0 ? chapterId : '$chapterId-$j', 'title': part.title, 'blocks': part.blocks}),
            encoding: utf8,
          );
          chapterOutput.add(
            LocalDocumentChapter(
              id: j == 0 ? chapterId : '$chapterId-$j',
              title: part.title.isEmpty ? item.href : part.title,
              index: chapterOutput.length,
              contentFile: filename,
              wordCount: part.words,
              startOffset: part.startOffset,
              href: item.path,
            ),
          );
        }
        onProgress?.call('epub_chapters', i + 1, chapterItems.length);
      }
      // Copy media resources referenced by the normalized block stream. CSS URLs
      // and unreferenced package payloads are intentionally not made fetchable.
      for (final item in items) {
        if (item.properties.split(RegExp(r'\s+')).contains('cover-image')) coverId = resourceByPath[item.path]?.id;
      }
      if (coverId == null) {
        final coverIdMeta = _metaProperty(package, 'cover');
        if (coverIdMeta != null) coverId = resourceByPath[manifest[coverIdMeta]?.path]?.id;
      }
      if (coverId == null) {
        final cover =
            items.where((item) => item.properties.split(RegExp(r'\s+')).contains('cover-image')).firstOrNull ??
            (manifest[_metaProperty(package, 'cover')]);
        final coverFile = cover == null ? null : byName[cover.path];
        if (cover != null && coverFile != null && cover.mediaType.startsWith('image/')) {
          try {
            if (cover.mediaType == 'image/svg+xml') {
              final svg = _xmlBytes(_bytes(coverFile, _maxResource, 'cover'), _maxResource, 'svg');
              final image = svg.descendants.whereType<XmlElement>().where((e) => e.name.local == 'image').firstOrNull;
              final href = image?.attributes.where((a) => a.name.local == 'href').firstOrNull?.value;
              final path = href == null ? null : _resolvePath(_dirOf(cover.path), href);
              final embedded = path == null ? null : byName[path];
              final mime = items.where((item) => item.path == path).firstOrNull?.mediaType;
              if (path != null && embedded != null && mime != null && mime.startsWith('image/') && mime != 'image/svg+xml') {
                coverId = _copyResource(output, path, mime, embedded, resourceByPath, resources);
              }
            }
            coverId ??= _copyResource(output, cover.path, cover.mediaType, coverFile, resourceByPath, resources);
          } on LocalDocumentException {
            warnings.add('无法安全显示书籍封面，已使用默认封面。');
          }
        }
      }
      final nav = tocItem == null ? const <LocalDocumentNavigation>[] : _readNavigation(tocItem, byName, opfPath, chapterMap, warnings);
      return ParsedLocalDocument(
        format: LocalDocumentFormat.epub,
        title: meta.title.isEmpty ? _fallbackTitle(source) : meta.title,
        author: meta.author,
        language: meta.language,
        description: meta.description,
        encoding: 'UTF-8',
        coverResourceId: coverId,
        chapters: chapterOutput,
        resources: resources,
        navigation: nav,
        warnings: warnings.toSet().toList(),
        attributes: {
          'opfPath': opfPath,
          'epubVersion': package.getAttribute('version') ?? '2.0',
          'linearAuxiliaryContent': spineRefs.where((e) => e.getAttribute('linear')?.toLowerCase() == 'no').length,
          'fallbackContent': fallbackIds.length,
        },
      );
    } finally {
      await zipInput.close();
    }
  }
}

final class _ZipRecord {
  const _ZipRecord(this.size, this.crc, this.mode);
  final int size, crc, mode;
}

Future<Map<String, _ZipRecord>> _preflightZip(File file, int fileSize, LocalDocumentCancellation cancel) async {
  final raf = await file.open();
  try {
    final tailSize = math.min(fileSize, 65557);
    await raf.setPosition(fileSize - tailSize);
    final tail = await raf.read(tailSize);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (_u32(tail, i) == 0x06054b50 && i + 22 + _u16(tail, i + 20) == tail.length) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const LocalDocumentException('epub_zip_eocd');
    final disk = _u16(tail, eocd + 4), cdDisk = _u16(tail, eocd + 6);
    final countDisk = _u16(tail, eocd + 8), count = _u16(tail, eocd + 10);
    final cdSize = _u32(tail, eocd + 12), cdOffset = _u32(tail, eocd + 16);
    if (disk != 0 ||
        cdDisk != 0 ||
        countDisk != count ||
        count > localDocumentMaxEntries ||
        cdSize > _maxContainer ||
        cdOffset + cdSize > fileSize) {
      throw const LocalDocumentException('epub_zip_directory_limit');
    }
    if (cdOffset + cdSize > fileSize - tailSize + eocd) throw const LocalDocumentException('epub_zip_directory_range');
    await raf.setPosition(cdOffset);
    final data = await raf.read(cdSize);
    if (data.length != cdSize) throw const LocalDocumentException('epub_zip_directory_truncated');
    final records = <String, _ZipRecord>{};
    var p = 0;
    for (var i = 0; i < count; i++) {
      cancel.check();
      if (p + 46 > data.length || _u32(data, p) != 0x02014b50) throw const LocalDocumentException('epub_zip_directory_invalid');
      final madeBy = _u16(data, p + 4), flags = _u16(data, p + 8), crc = _u32(data, p + 16);
      final compressed = _u32(data, p + 20), size = _u32(data, p + 24);
      final nameLen = _u16(data, p + 28), extraLen = _u16(data, p + 30), commentLen = _u16(data, p + 32);
      final diskStart = _u16(data, p + 34), attrs = _u32(data, p + 38);
      final end = p + 46 + nameLen + extraLen + commentLen;
      if (end > data.length || diskStart != 0 || (flags & 1) != 0 || size == 0xffffffff || compressed == 0xffffffff) {
        throw const LocalDocumentException('epub_zip_entry_invalid');
      }
      final rawName = utf8.decode(data.sublist(p + 46, p + 46 + nameLen), allowMalformed: (flags & 0x800) == 0);
      final name = _normalizeZipPath(rawName);
      if (name == null) throw LocalDocumentException('epub_zip_path', rawName);
      final fileType = (madeBy >> 8) == 3 ? (attrs >> 16) & 0xf000 : 0;
      if (fileType == 0xa000) throw LocalDocumentException('epub_zip_symlink', rawName);
      if (records.containsKey(name)) throw LocalDocumentException('epub_zip_duplicate', rawName);
      records[name] = _ZipRecord(size, crc, attrs >> 16);
      p = end;
    }
    if (p != data.length) throw const LocalDocumentException('epub_zip_directory_trailing');
    return records;
  } finally {
    await raf.close();
  }
}

int _u16(List<int> b, int p) => b[p] | (b[p + 1] << 8);
int _u32(List<int> b, int p) => _u16(b, p) | (_u16(b, p + 2) << 16);

String? _normalizeZipPath(String raw) {
  if (raw.isEmpty ||
      raw.startsWith('/') ||
      raw.startsWith('\\') ||
      raw.contains('\\') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(raw) ||
      raw.startsWith('//')) {
    return null;
  }
  final parts = <String>[];
  for (final part in raw.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isEmpty) return null;
      parts.removeLast();
    } else {
      parts.add(part);
    }
  }
  return parts.join('/');
}

String? _resolvePath(String base, String href) {
  final uri = Uri.tryParse(href);
  if (uri == null || uri.hasScheme || uri.hasAuthority || href.startsWith('\\')) return null;
  final decoded = uri.path;
  if (decoded.startsWith('/')) return _normalizeZipPath(decoded.substring(1));
  return _normalizeZipPath(base.isEmpty ? decoded : '$base/$decoded');
}

String _dirOf(String path) => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
int _entryLimit(String path, String? mime) => _isXhtmlName(path)
    ? _maxXhtml
    : mime?.startsWith('text/css') == true || ['.css', '.xml', '.opf', '.ncx'].any(path.toLowerCase().endsWith)
    ? _maxMetadata
    : _maxResource;
bool _isXhtmlName(String path) => ['.xhtml', '.html', '.htm'].any(path.toLowerCase().endsWith);
String? _mediaType(String path) => switch (path.toLowerCase().split('.').last) {
  'xhtml' || 'html' || 'htm' => 'application/xhtml+xml',
  'css' => 'text/css',
  'png' => 'image/png',
  'jpg' || 'jpeg' => 'image/jpeg',
  'gif' => 'image/gif',
  'webp' => 'image/webp',
  'svg' => 'image/svg+xml',
  'otf' || 'ttf' || 'woff' || 'woff2' => 'font/unknown',
  _ => null,
};
bool _isXhtml(_ManifestItem i) => i.mediaType == 'application/xhtml+xml' || i.mediaType == 'text/html' || _isXhtmlName(i.path);
String? _manifestAttribute(_ManifestItem i, String key) => i.fallback;

Uint8List _bytes(ArchiveFile file, int max, String kind) {
  if (file.size > max) throw LocalDocumentException('epub_${kind}_size', file.name);
  final bytes = file.readBytes();
  if (bytes == null || bytes.length != file.size) throw LocalDocumentException('epub_${kind}_truncated', file.name);
  _releaseZipCache(file);
  return bytes;
}

void _releaseZipCache(ArchiveFile file) {
  final temporary = File('${Directory.systemTemp.path}${Platform.pathSeparator}mgread-epub-${identityHashCode(file)}.tmp');
  try {
    final output = OutputFileStream(temporary.path);
    file.writeContent(output);
    output.closeSync();
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}
