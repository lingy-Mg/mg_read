part of 'epub_local_document_parser.dart';

/// XML safety, rich XHTML normalization, navigation extraction, and bounded
/// chapter chunking helpers owned by [EpubLocalDocumentParser].
XmlDocument _xmlBytes(Uint8List bytes, int max, String kind) {
  if (bytes.length > max) throw LocalDocumentException('epub_${kind}_size');
  String value;
  try {
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
      value = _decodeUtf16(bytes.sublist(2), littleEndian: true);
    } else if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
      value = _decodeUtf16(bytes.sublist(2), littleEndian: false);
    } else if (bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf) {
      value = utf8.decode(bytes.sublist(3));
    } else {
      value = utf8.decode(bytes);
    }
  } on FormatException catch (e) {
    throw LocalDocumentException('epub_xml_encoding', _short(e));
  }
  if (RegExp(r'<!ENTITY\s+[^\s]+\s+(SYSTEM|PUBLIC)', caseSensitive: false).hasMatch(value)) {
    throw LocalDocumentException('epub_xml_external_entity', kind);
  }
  try {
    var depth = 0;
    var events = 0;
    for (final event in parseEvents(value, validateNesting: true, validateDocument: true)) {
      if (++events > _maxNodes * 2) throw LocalDocumentException('epub_xml_complexity', kind);
      if (event is XmlStartElementEvent && !event.isSelfClosing && ++depth > _maxDepth) {
        throw LocalDocumentException('epub_xml_complexity', kind);
      }
      if (event is XmlEndElementEvent) depth--;
      if (event is XmlDoctypeEvent && event.internalSubset?.trim().isNotEmpty == true) {
        throw LocalDocumentException('epub_xml_external_entity', kind);
      }
    }
    final doc = XmlDocument.parse(value);
    if (doc.doctypeElement?.internalSubset?.trim().isNotEmpty == true) throw LocalDocumentException('epub_xml_external_entity', kind);
    var nodes = 0;
    void walk(XmlNode node, int depth) {
      if (depth > _maxDepth || ++nodes > _maxNodes) throw LocalDocumentException('epub_xml_complexity', kind);
      if (node is XmlElement) {
        for (final child in node.children) {
          walk(child, depth + 1);
        }
      }
    }

    walk(doc.rootElement, 0);
    return doc;
  } on XmlException catch (e) {
    throw LocalDocumentException('epub_xml_invalid', _short(e));
  }
}

String _copyResource(
  Directory output,
  String path,
  String mime,
  ArchiveFile entry,
  Map<String, LocalDocumentResource> byPath,
  List<LocalDocumentResource> resources,
) {
  final existing = byPath[path];
  if (existing != null) return existing.id;
  final id = _stableId('r', path);
  final fileName = 'resources/${id}_${path.split('/').last.replaceAll(RegExp(r'[^\w.-]'), '_')}';
  final bytes = _bytes(entry, ContentLimits.imageBytes, 'image');
  if (mime == 'image/svg+xml') {
    final svg = _xmlBytes(bytes, ContentLimits.imageBytes, 'svg');
    final elements = [svg.rootElement, ...svg.rootElement.descendants.whereType<XmlElement>()];
    if (elements.any(
      (node) =>
          {'script', 'foreignObject', 'animate', 'set', 'iframe', 'audio', 'video', 'feImage', 'image'}.contains(node.name.local) ||
          node.attributes.any(
            (attribute) =>
                attribute.name.local.toLowerCase().startsWith('on') ||
                (attribute.name.local == 'href' && !attribute.value.startsWith('#')) ||
                (attribute.value.contains('url(') && !RegExp(r'''url\(\s*['"]?#''').hasMatch(attribute.value)),
          ),
    )) {
      throw const LocalDocumentException('epub_unsafe_svg');
    }
  }
  final target = File('${output.path}${Platform.pathSeparator}${fileName.replaceAll('/', Platform.pathSeparator)}');
  target.parent.createSync(recursive: true);
  target.writeAsBytesSync(bytes, flush: true);
  final resource = LocalDocumentResource(id: id, file: fileName, mimeType: mime, bytes: bytes.length, href: path);
  byPath[path] = resource;
  resources.add(resource);
  return id;
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  if (bytes.length.isOdd) throw const FormatException('Odd UTF-16 byte count');
  final units = <int>[];
  for (var i = 0; i < bytes.length; i += 2) {
    units.add(littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

String _short(Object error) => error.toString().replaceAll(RegExp(r'\s+'), ' ').substring(0, math.min(300, error.toString().length));
String _fallbackTitle(File source) => source.uri.pathSegments.last.replaceAll(RegExp(r'\.epub$', caseSensitive: false), '');
String _stableId(String prefix, String value) {
  // Hash the complete publication path: truncating an encoded path aliases
  // chapters and resources that share a long directory prefix.
  return '$prefix-${crypto.sha256.convert(utf8.encode(value))}';
}

final class _ManifestItem {
  const _ManifestItem(this.id, this.href, this.path, this.mediaType, this.properties, {this.fallback});
  final String id, href, path, mediaType, properties;
  final String? fallback;
}

final class _BookMetadata {
  const _BookMetadata(this.title, this.author, this.language, this.description);
  final String title;
  final String? author, language, description;
}

_BookMetadata _metadata(XmlElement? element) {
  String? text(String local) => element?.children
      .whereType<XmlElement>()
      .where((e) => e.name.local == local)
      .map((e) => e.innerText.trim())
      .where((e) => e.isNotEmpty)
      .firstOrNull;
  return _BookMetadata(text('title') ?? '', text('creator'), text('language'), text('description'));
}

String? _metaProperty(XmlElement root, String property) {
  for (final meta in root.findAllElements('meta')) {
    if (meta.getAttribute('property') == property || meta.getAttribute('name') == property) {
      return (meta.getAttribute('content') ?? meta.innerText).trim();
    }
  }
  return null;
}

List<Map<String, String>> _stylesFor(
  XmlDocument doc,
  _ManifestItem item,
  Map<String, ArchiveFile> files,
  String opfPath,
  List<String> warnings,
) {
  final css = <String, Map<String, String>>{};
  for (final link in doc.findAllElements('link')) {
    if (link.getAttribute('rel')?.split(RegExp(r'\s+')).contains('stylesheet') != true) continue;
    final path = _resolvePath(_dirOf(item.path), link.getAttribute('href') ?? '');
    final file = path == null ? null : files[path];
    if (file == null) {
      warnings.add('样式表缺失，已使用默认排版。');
      continue;
    }
    final source = utf8.decode(_bytes(file, _maxMetadata, 'css'), allowMalformed: true);
    if (RegExp(r'writing-mode\s*:\s*(vertical|tb|sideways)', caseSensitive: false).hasMatch(source)) {
      throw const LocalDocumentException('epub_vertical_layout');
    }
    _parseCss(source, css);
  }
  for (final style in doc.findAllElements('style')) {
    _parseCss(style.innerText, css);
  }
  return [
    for (final e in css.entries) {'selector': e.key, ...e.value},
  ];
}

void _parseCss(String source, Map<String, Map<String, String>> rules) {
  final clean = source.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  for (final match in RegExp(r'([^{}]+)\{([^{}]*)\}').allMatches(clean)) {
    final selectors = match.group(1)!.split(',');
    final declarations = <String, String>{};
    for (final declaration in match.group(2)!.split(';')) {
      final p = declaration.indexOf(':');
      if (p < 1) continue;
      final key = declaration.substring(0, p).trim().toLowerCase(), value = declaration.substring(p + 1).trim().toLowerCase();
      if ({
            'text-align',
            'font-weight',
            'font-style',
            'text-decoration',
            'white-space',
            'margin-left',
            'text-indent',
            'direction',
          }.contains(key) &&
          !value.contains('url(') &&
          !value.contains('expression')) {
        declarations[key] = value;
      }
    }
    for (final selector in selectors.map((e) => e.trim()).where((e) => e.length < 160)) {
      if (declarations.isNotEmpty) rules[selector] = {...?rules[selector], ...declarations};
    }
  }
}

List<LocalDocumentNavigation> _readNavigation(
  _ManifestItem item,
  Map<String, ArchiveFile> files,
  String opfPath,
  Map<String, String> chapterMap,
  List<String> warnings,
) {
  final file = files[item.path];
  if (file == null) {
    warnings.add('目录文件缺失。');
    return const [];
  }
  final doc = _xmlBytes(_bytes(file, _maxXhtml, 'nav'), _maxXhtml, 'nav');
  final base = _dirOf(item.path);
  final nav = doc
      .findAllElements('nav')
      .where((e) => (e.getAttribute('type') ?? e.getAttribute('epub:type') ?? '').contains('toc'))
      .firstOrNull;
  if (nav != null) {
    XmlElement? ol = nav.findAllElements('ol').firstOrNull;
    return ol == null ? const [] : _navOl(ol, base, chapterMap, 0);
  }
  final map = doc.findAllElements('navMap').firstOrNull;
  return map == null ? const [] : _ncxPoints(map, base, chapterMap, 0);
}

List<LocalDocumentNavigation> _navOl(XmlElement ol, String base, Map<String, String> chapters, int depth) {
  if (depth > 32) return const [];
  final result = <LocalDocumentNavigation>[];
  for (final li in ol.children.whereType<XmlElement>().where((e) => e.name.local == 'li')) {
    final anchor = li.findAllElements('a').firstOrNull ?? li.findAllElements('span').firstOrNull;
    final href = anchor?.getAttribute('href') ?? '';
    final target = _navTarget(base, href, chapters);
    if (target == null) continue;
    final nested = li.findAllElements('ol').firstOrNull;
    result.add(
      LocalDocumentNavigation(
        label: anchor?.innerText.trim().isNotEmpty == true ? anchor!.innerText.trim() : '目录',
        chapterId: target.$1,
        fragment: target.$2,
        children: nested == null ? const [] : _navOl(nested, base, chapters, depth + 1),
      ),
    );
  }
  return result;
}

List<LocalDocumentNavigation> _ncxPoints(XmlElement map, String base, Map<String, String> chapters, int depth) {
  if (depth > 32) return const [];
  final result = <LocalDocumentNavigation>[];
  for (final point in map.children.whereType<XmlElement>().where((e) => e.name.local == 'navPoint')) {
    final label = point.findAllElements('text').firstOrNull?.innerText.trim() ?? '目录';
    final src = point.findAllElements('content').firstOrNull?.getAttribute('src') ?? '';
    final target = _navTarget(base, src, chapters);
    if (target == null) continue;
    result.add(
      LocalDocumentNavigation(
        label: label,
        chapterId: target.$1,
        fragment: target.$2,
        children: _ncxPoints(point, base, chapters, depth + 1),
      ),
    );
  }
  return result;
}

(String, String?)? _navTarget(String base, String href, Map<String, String> chapters) {
  final uri = Uri.tryParse(href);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  final path = _resolvePath(base, uri.path);
  if (path == null) return null;
  final id = chapters[path];
  return id == null ? null : (id, uri.fragment.isEmpty ? null : uri.fragment);
}

final class _Part {
  const _Part(this.title, this.blocks, this.words, this.startOffset);
  final String title;
  final List<Map<String, Object?>> blocks;
  final int words, startOffset;
}

List<_Part> _splitBlocks(List<Map<String, Object?>> blocks, String chapterId, String href, String path, int index, String title) {
  const chunk = 16000;
  final parts = <_Part>[];
  var current = <Map<String, Object?>>[];
  var chars = 0, words = 0, start = 0, renderNodes = 0, images = 0;
  void flush() {
    if (current.isNotEmpty) {
      parts.add(_Part(title, current, words, start));
      current = [];
      chars = 0;
      renderNodes = 0;
      images = 0;
      words = 0;
      start += parts.last.blocks.fold<int>(0, (n, b) => n + ((b['text'] as String?)?.length ?? 0));
    }
  }

  for (final block in blocks) {
    final text = block['text'] as String? ?? '';
    final weight = _epubRenderNodes(block);
    if (weight > 512 && block['children'] is List) throw const LocalDocumentException('epub_block_complexity');
    if (current.length >= 128 || renderNodes + weight > 512 || (block['type'] == 'image' && images >= 4)) flush();
    renderNodes += weight;
    if (block['type'] == 'image') images++;
    if (text.length <= chunk) {
      if (chars + text.length > chunk) {
        flush();
        renderNodes = weight;
        if (block['type'] == 'image') images = 1;
      }
      current.add(block);
      chars += text.length;
      words += _wordCount(text);
    } else {
      flush();
      var pos = 0;
      while (pos < text.length) {
        var end = math.min(text.length, pos + chunk);
        if (end < text.length &&
            end > pos &&
            text.codeUnitAt(end - 1) >= 0xd800 &&
            text.codeUnitAt(end - 1) <= 0xdbff &&
            text.codeUnitAt(end) >= 0xdc00 &&
            text.codeUnitAt(end) <= 0xdfff) {
          end--;
        }
        final segment = text.substring(pos, end);
        current = [
          {
            'id': pos == 0 ? block['id'] : '${block['id']}-$pos',
            'type': block['type'],
            'text': segment,
            'spans': _sliceEpubSpans(block['spans'] as List? ?? const [], pos, end, segment),
            'anchor': pos == 0 ? block['anchor'] : null,
            'style': block['style'],
          },
        ];
        chars = segment.length;
        words = _wordCount(segment);
        flush();
        pos = end;
      }
    }
  }
  flush();
  if (parts.isEmpty) parts.add(_Part(title, const [], 0, 0));
  return parts;
}

List<Map<String, Object?>> _sliceEpubSpans(List spans, int start, int end, String fallback) {
  var position = 0;
  final output = <Map<String, Object?>>[];
  for (final raw in spans.whereType<Map>()) {
    final text = raw['text'] as String? ?? '';
    final next = position + text.length;
    if (next > start && position < end) {
      output.add({
        ...Map<String, Object?>.from(raw),
        'text': text.substring(math.max(0, start - position), math.min(text.length, end - position)),
      });
    }
    position = next;
  }
  return output.isEmpty
      ? [
          {'text': fallback},
        ]
      : output;
}

int _epubRenderNodes(Map block) {
  var count = 1;
  for (final child in (block['children'] as List? ?? const []).whereType<Map>()) {
    count += _epubRenderNodes(child);
    if (count > 512) break;
  }
  return count;
}

int _wordCount(String text) => RegExp(r'[\p{L}\p{N}]+', unicode: true).allMatches(text).length;

final class _InheritedStyle {
  const _InheritedStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.superscript = false,
    this.subscript = false,
    this.href,
  });
  final bool bold, italic, underline, superscript, subscript;
  final String? href;
}

final class _BlockBuilder {
  _BlockBuilder(
    this.outputPath,
    this.path,
    this.chapterId,
    this.css,
    this.items,
    this.files,
    this.opfDir,
    this.resourceByPath,
    this.resources,
    this.warnings,
  );
  final String outputPath, path, chapterId, opfDir;
  final List<Map<String, String>> css;
  final List<_ManifestItem> items;
  final Map<String, ArchiveFile> files;
  final Map<String, LocalDocumentResource> resourceByPath;
  final List<LocalDocumentResource> resources;
  final List<String> warnings;
  final List<Map<String, Object?>> blocks = [];
  int nodes = 0;
  void walkChildren(XmlElement parent, _InheritedStyle style, int depth) {
    if (depth > _maxDepth || ++nodes > _maxNodes) throw const LocalDocumentException('epub_xhtml_complexity');
    var textIndex = 0;
    for (final child in parent.children) {
      if (child is XmlElement) {
        walk(child, style, depth + 1);
      } else if (child is XmlText && child.value.trim().isNotEmpty) {
        _emit(
          'paragraph',
          child.value.replaceAll(RegExp(r'\s+'), ' '),
          parent,
          style,
          extra: {'id': _stableId('text', '$path|${_elementPath(parent)}|${textIndex++}')},
        );
      }
    }
  }

  void walk(XmlElement element, _InheritedStyle inherited, int depth) {
    if (depth > _maxDepth || ++nodes > _maxNodes) throw const LocalDocumentException('epub_xhtml_complexity');
    final tag = element.name.local.toLowerCase();
    if ({'script', 'iframe', 'object', 'embed', 'form', 'input', 'video', 'audio', 'canvas', 'svg'}.contains(tag)) {
      if (tag == 'svg') _svg(element, inherited);
      return;
    }
    final style = _styleFor(element, inherited);
    if (tag == 'img') {
      _image(element, style);
      return;
    }
    if (tag == 'br') {
      _textBlock('paragraph', '\n', element, style);
      return;
    }
    if (tag == 'hr') {
      _emit('rule', '', element, style);
      return;
    }
    if (tag == 'table') {
      _table(element, style, depth);
      return;
    }
    if (tag == 'ul' || tag == 'ol') {
      _list(element, style, depth);
      return;
    }
    if (tag == 'pre') {
      _textBlock('pre', element.innerText, element, style);
      return;
    }
    if (tag == 'blockquote') {
      final text = _inlineText(element, style);
      _textBlock('quote', text, element, style);
      return;
    }
    if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
      _textBlock('heading', _inlineText(element, style), element, style, extra: {'level': int.parse(tag.substring(1))});
      return;
    }
    if ({'div', 'section', 'article', 'aside', 'header', 'footer', 'main', 'figure', 'figcaption'}.contains(tag) &&
        element.children.whereType<XmlElement>().any(
          (child) => {
            'div',
            'section',
            'article',
            'p',
            'ul',
            'ol',
            'table',
            'blockquote',
            'pre',
            'figure',
            'svg',
            'img',
            'h1',
            'h2',
            'h3',
            'h4',
            'h5',
            'h6',
          }.contains(child.name.local.toLowerCase()),
        )) {
      final before = blocks.length;
      walkChildren(element, style, depth + 1);
      final anchor = element.getAttribute('id');
      if (anchor != null && blocks.length > before) {
        final first = blocks[before];
        first['anchors'] = [...(first['anchors'] as List? ?? const []), anchor];
        first['anchor'] ??= anchor;
      }
      return;
    }
    if (tag == 'p' || tag == 'div' || tag == 'section' || tag == 'article' || tag == 'figure' || tag == 'figcaption') {
      final text = _inlineText(element, style);
      if (text.trim().isNotEmpty) _textBlock('paragraph', text, element, style);
      return;
    }
    walkChildren(element, style, depth);
  }

  _InheritedStyle _styleFor(XmlElement e, _InheritedStyle s) {
    final tag = e.name.local.toLowerCase();
    final inline = (e.getAttribute('style') ?? '').toLowerCase();
    if (RegExp(r'writing-mode\s*:\s*(vertical|tb|sideways)').hasMatch(inline)) throw const LocalDocumentException('epub_vertical_layout');
    final classNames = (e.getAttribute('class') ?? '').split(RegExp(r'\s+'));
    final rules = css.where((rule) => _selectorMatches(rule['selector']!, e, classNames)).toList();
    bool has(String value) =>
        inline.contains(value) || rules.any((r) => (r[value.split(':').first]?.contains(value.split(':').last.trim()) ?? false));
    final href = tag == 'a' ? e.getAttribute('href') : s.href;
    return _InheritedStyle(
      bold: s.bold || const {'b', 'strong'}.contains(tag) || has('font-weight:bold') || has('font-weight:700'),
      italic: s.italic || const {'i', 'em', 'cite', 'dfn'}.contains(tag) || has('font-style:italic'),
      underline: s.underline || const {'u', 'ins'}.contains(tag) || has('text-decoration:underline'),
      superscript: s.superscript || tag == 'sup',
      subscript: s.subscript || tag == 'sub',
      href: href == null ? s.href : _safeLink(href),
    );
  }

  String _inlineText(XmlElement e, _InheritedStyle style) {
    final spans = <String>[];
    void collect(XmlNode n, _InheritedStyle s) {
      if (n is XmlText) {
        spans.add(n.value);
        return;
      }
      if (n is! XmlElement) return;
      final tag = n.name.local.toLowerCase();
      if ({'script', 'style', 'iframe', 'object', 'embed'}.contains(tag)) return;
      final next = _styleFor(n, s);
      if (tag == 'img') {
        spans.add(n.getAttribute('alt') ?? '');
        return;
      }
      for (final child in n.children) {
        collect(child, next);
      }
      if ({'br', 'p', 'div', 'li'}.contains(tag)) spans.add('\n');
    }

    for (final child in e.children) {
      collect(child, style);
    }
    return spans.join().replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  void _textBlock(String type, String text, XmlElement e, _InheritedStyle style, {Map<String, Object?> extra = const {}}) {
    final spans = <Map<String, Object?>>[];
    final anchors = <String>[];
    var segment = 0;
    void flush() {
      if (spans.isEmpty) return;
      final value = spans.map((span) => span['text']! as String).join();
      if (value.trim().isEmpty && type != 'pre') {
        spans.clear();
        return;
      }
      _emit(
        type,
        value,
        e,
        style,
        extra: {
          ...extra,
          if (segment > 0) 'id': '${_stableId('b', '$path|${e.getAttribute('id') ?? _elementPath(e)}')}:$segment',
          if (anchors.isNotEmpty) 'anchors': List<String>.of(anchors),
          if (anchors.isNotEmpty) 'anchor': anchors.first,
        },
        spans: List<Map<String, Object?>>.of(spans),
      );
      segment++;
      spans.clear();
      anchors.clear();
    }

    void collect(XmlNode node, _InheritedStyle inherited) {
      if (node is XmlText) {
        if (node.value.isNotEmpty) {
          spans.add({
            'text': node.value,
            'bold': inherited.bold,
            'italic': inherited.italic,
            'underline': inherited.underline,
            'superscript': inherited.superscript,
            'subscript': inherited.subscript,
            if (inherited.href != null) 'href': inherited.href,
          });
        }
        return;
      }
      if (node is! XmlElement) return;
      final tag = node.name.local.toLowerCase();
      if ({'script', 'style', 'iframe', 'object', 'embed', 'form', 'input', 'video', 'audio', 'canvas'}.contains(tag)) return;
      final next = _styleFor(node, inherited);
      if (node.getAttribute('id') case final String anchor) {
        anchors.add(anchor);
      }
      if (tag == 'img' || tag == 'image' || tag == 'svg') {
        flush();
        if (tag == 'svg') {
          _svg(node, next);
        } else {
          _image(node, next);
        }
        return;
      }
      if (tag == 'ul' || tag == 'ol') {
        flush();
        _list(node, next, 1);
        return;
      }
      for (final child in node.children) {
        collect(child, next);
      }
      if (tag == 'br') spans.add({'text': '\n'});
    }

    for (final child in e.children) {
      collect(child, style);
    }
    flush();
  }

  void _emit(
    String type,
    String text,
    XmlElement e,
    _InheritedStyle s, {
    Map<String, Object?> extra = const {},
    List<Map<String, Object?>>? spans,
    String? resourceId,
  }) {
    final id = _stableId('b', '$path|${e.getAttribute('id') ?? _elementPath(e)}');
    blocks.add({
      'id': id,
      'type': type,
      'text': text,
      'spans':
          spans ??
          [
            {'text': text},
          ],
      'style': {
        ..._normalizedStyle(e),
        if (extra.containsKey('ordered')) 'ordered': extra['ordered'],
        if (extra.containsKey('listIndex')) 'listIndex': extra['listIndex'],
        if (extra.containsKey('depth')) 'depth': extra['depth'],
      },
      'resourceId': ?resourceId,
      if (e.getAttribute('id') != null) 'anchor': e.getAttribute('id'),
      ...extra,
    });
  }

  Map<String, String> _normalizedStyle(XmlElement e) {
    final result = <String, String>{};
    void add(String value) {
      for (final pair in value.toLowerCase().split(';')) {
        final p = pair.indexOf(':');
        if (p < 1) continue;
        final k = pair.substring(0, p).trim(), v = pair.substring(p + 1).trim();
        if ({
              'text-align',
              'direction',
              'white-space',
              'margin-left',
              'text-indent',
              'font-size',
              'color',
              'background-color',
            }.contains(k) &&
            !v.contains('url(') &&
            !v.contains('expression')) {
          result[k] = v;
        }
      }
    }

    final classes = (e.getAttribute('class') ?? '').split(RegExp(r'\s+'));
    for (final rule in css.where((rule) => _selectorMatches(rule['selector']!, e, classes))) {
      for (final entry in rule.entries) {
        if (entry.key != 'selector') result[entry.key] = entry.value;
      }
    }
    add(e.getAttribute('style') ?? '');
    return result;
  }

  void _list(XmlElement e, _InheritedStyle s, int depth) {
    final ordered = e.name.local.toLowerCase() == 'ol';
    var index = 1;
    for (final li in e.children.whereType<XmlElement>().where((c) => c.name.local.toLowerCase() == 'li')) {
      final text = _inlineText(li, _styleFor(li, s));
      if (text.isNotEmpty) _textBlock('listItem', text, li, s, extra: {'ordered': ordered, 'listIndex': index++, 'depth': depth});
    }
  }

  void _table(XmlElement e, _InheritedStyle s, int depth) {
    final rows = e.findAllElements('tr').toList(growable: false);
    if (rows.length > ContentLimits.epubTableRows) throw const LocalDocumentException('epub_table_too_large');
    var rowIndex = 0;
    for (final row in rows) {
      final cells = <Map<String, Object?>>[];
      var col = 0;
      if (row.children.whereType<XmlElement>().where((c) => {'td', 'th'}.contains(c.name.local.toLowerCase())).length >
          ContentLimits.epubTableColumns) {
        throw const LocalDocumentException('epub_table_too_large');
      }
      for (final cell
          in row.children
              .whereType<XmlElement>()
              .where((c) => const {'td', 'th'}.contains(c.name.local.toLowerCase()))
              .take(ContentLimits.epubTableColumns)) {
        final text = _inlineText(cell, s);
        cells.add({
          'id': _stableId('cell', '$path|${rowIndex}_$col'),
          'type': 'cell',
          'text': text,
          'spans': [
            {'text': text},
          ],
          'style': {'header': cell.name.local.toLowerCase() == 'th'},
          'rowspan': _boundedInt(cell.getAttribute('rowspan')),
          'colspan': _boundedInt(cell.getAttribute('colspan')),
        });
        col++;
      }
      _emit('row', cells.map((c) => c['text']).join('\t'), row, s, extra: {'children': cells, 'rowIndex': rowIndex});
      rowIndex++;
    }
  }

  int _boundedInt(String? s) => int.tryParse(s ?? '')?.clamp(1, 100) ?? 1;
  String? _safeLink(String href) {
    final u = Uri.tryParse(href);
    if (u == null || u.hasAuthority || href.startsWith('//')) return null;
    if (u.hasScheme) return const {'http', 'https'}.contains(u.scheme.toLowerCase()) ? u.toString() : null;
    final target = u.path.isEmpty ? path : _resolvePath(_dirOf(path), u.path);
    if (target == null || !items.any((item) => item.path == target)) return null;
    return '$target${u.fragment.isEmpty ? '' : '#${Uri.encodeComponent(u.fragment)}'}';
  }

  void _image(XmlElement e, _InheritedStyle s) {
    final src = e.getAttribute('src') ?? e.attributes.where((attribute) => attribute.name.local == 'href').firstOrNull?.value ?? '';
    final path = _resolvePath(_dirOf(this.path), src);
    if (path == null) {
      warnings.add('已忽略外部或无效图片引用。');
      return;
    }
    final target = files[path];
    if (target == null) {
      warnings.add('图片资源缺失：$src');
      return;
    }
    final item = items.where((i) => i.path == path).firstOrNull;
    final mime = item?.mediaType ?? _mediaType(path) ?? 'application/octet-stream';
    if (!mime.startsWith('image/')) return;
    if (mime == 'image/svg+xml') {
      final svg = _xmlBytes(_bytes(target, _maxResource, 'image'), _maxResource, 'svg');
      final svgElements = svg.rootElement.descendants.whereType<XmlElement>();
      if (svgElements.any(
        (element) =>
            const {
              'script',
              'foreignObject',
              'image',
              'use',
              'animate',
              'set',
              'iframe',
              'audio',
              'video',
              'feImage',
            }.contains(element.name.local) ||
            element.attributes.any((attribute) => attribute.name.local.toLowerCase().startsWith('on')) ||
            (element.getAttribute('href') ?? '').isNotEmpty ||
            (element.getAttribute('style') ?? '').toLowerCase().contains('url('),
      )) {
        warnings.add('已忽略含活动内容的 SVG 图片。');
        return;
      }
    }
    final resourceId = _copyResource(Directory(outputPath), path, mime, target, resourceByPath, resources);
    _emit('image', e.getAttribute('alt') ?? '', e, s, resourceId: resourceId);
  }

  void _svg(XmlElement e, _InheritedStyle s) {
    final images = e.descendants.whereType<XmlElement>().where((node) => node.name.local == 'image').toList();
    if (images.isNotEmpty) {
      for (final image in images) {
        _image(image, s);
      }
      return;
    }
    final elements = [e, ...e.descendants.whereType<XmlElement>()];
    if (elements.any(
      (node) =>
          {'script', 'foreignObject', 'animate', 'set', 'iframe', 'audio', 'video', 'feImage'}.contains(node.name.local) ||
          node.attributes.any(
            (attribute) =>
                attribute.name.local.toLowerCase().startsWith('on') ||
                (attribute.name.local == 'href' && !attribute.value.startsWith('#')) ||
                (attribute.value.contains('url(') && !RegExp(r'''url\(\s*['"]?#''').hasMatch(attribute.value)),
          ),
    )) {
      warnings.add('已忽略含活动内容的 SVG 图片。');
      return;
    }
    final id = _stableId('svg', '$path|${_elementPath(e)}');
    final fileName = 'resources/$id.svg';
    final file = File('$outputPath/$fileName');
    file.parent.createSync(recursive: true);
    final clone = e.copy();
    if (clone.getAttribute('xmlns') == null) clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
    final bytes = utf8.encode(clone.toXmlString());
    file.writeAsBytesSync(bytes);
    resources.add(LocalDocumentResource(id: id, file: fileName, mimeType: 'image/svg+xml', bytes: bytes.length));
    _emit('image', e.getAttribute('aria-label') ?? '', e, s, resourceId: id);
  }
}

bool _selectorMatches(String selector, XmlElement e, List<String> classes) {
  if (selector.contains(' ') || selector.contains('>') || selector.contains(':')) return false;
  final tag = e.name.local.toLowerCase();
  final id = e.getAttribute('id');
  final m = RegExp(r'^([a-zA-Z][\w-]*)?((?:[.#][\w-]+)*)$').firstMatch(selector);
  if (m == null) return false;
  if ((m.group(1)?.toLowerCase() ?? tag) != tag) return false;
  final tokens = RegExp(r'([.#])([\w-]+)').allMatches(m.group(2)!);
  return tokens.every((x) => x.group(1) == '#' ? id == x.group(2) : classes.contains(x.group(2)));
}

String _elementPath(XmlElement element) {
  final components = <String>[];
  XmlNode? current = element;
  while (current is XmlElement) {
    final parent = current.parent;
    final siblings = switch (parent) {
      XmlElement p => p.children.whereType<XmlElement>().toList(growable: false),
      XmlDocument d => d.children.whereType<XmlElement>().toList(growable: false),
      _ => const <XmlElement>[],
    };
    components.add('${current.name.local}[${siblings.indexOf(current)}]');
    current = parent;
  }
  return components.reversed.join('/');
}

bool _hasStaticEpubContent(XmlDocument document) {
  final body = document.rootElement.findAllElements('body').firstOrNull ?? document.rootElement;
  for (final node in body.descendants) {
    if (node is XmlText &&
        node.value.trim().isNotEmpty &&
        !node.ancestors.whereType<XmlElement>().any((parent) => {'script', 'style', 'head'}.contains(parent.name.local.toLowerCase()))) {
      return true;
    }
    if (node is XmlElement && {'img', 'svg'}.contains(node.name.local.toLowerCase())) return true;
  }
  return false;
}
