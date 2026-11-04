part of 'epub_local_document_parser.dart';

/// Classifies bounded spine blocks for the existing novel/comic readers.
/// Explicit auxiliary publication text is retained as metadata; body images
/// and text are never silently discarded to force a supported reading mode.
final class _EpubSpinePage {
  const _EpubSpinePage({
    required this.item,
    required this.chapterId,
    required this.blocks,
    required this.title,
    this.containsImageMarkup = false,
    this.isAuxiliaryBackmatter = false,
  });

  final _ManifestItem item;
  final String chapterId;
  final List<Map<String, Object?>> blocks;
  final String title;
  final bool containsImageMarkup;
  final bool isAuxiliaryBackmatter;
}

String _epubBlockText(Map block) {
  final spans = (block['spans'] as List? ?? const []).whereType<Map>().map((span) => span['text'] as String? ?? '').join();
  return spans.isEmpty ? block['text'] as String? ?? '' : spans;
}

Iterable<Map> _epubNestedBlocks(Iterable<Map> blocks) sync* {
  for (final block in blocks) {
    yield block;
    yield* _epubNestedBlocks((block['children'] as List? ?? const []).whereType<Map>());
  }
}

bool _epubHasBodyText(List<Map<String, Object?>> blocks) => _epubNestedBlocks(blocks).any((block) {
  final type = block['type'];
  return type != 'image' && type != 'heading' && _epubBlockText(block).trim().isNotEmpty;
});

bool _epubHasText(List<Map<String, Object?>> blocks) =>
    _epubNestedBlocks(blocks).any((block) => block['type'] != 'image' && _epubBlockText(block).trim().isNotEmpty);

List<Map> _epubImages(List<Map<String, Object?>> blocks) =>
    _epubNestedBlocks(blocks).where((block) => block['type'] == 'image').toList(growable: false);

bool _epubIsCoverOnly(List<Map<String, Object?>> blocks, Set<String> coverResourceIds) {
  final images = _epubImages(blocks);
  return coverResourceIds.isNotEmpty &&
      images.isNotEmpty &&
      !_epubHasBodyText(blocks) &&
      images.every((block) => coverResourceIds.contains(block['resourceId']));
}

List<Map<String, Object?>> _epubTextBlocks(List<Map<String, Object?>> blocks) {
  final result = <Map<String, Object?>>[];
  void visit(Map block) {
    final type = block['type'] as String? ?? 'paragraph';
    if (type == 'image') return;
    final children = (block['children'] as List? ?? const []).whereType<Map>().toList(growable: false);
    final text = _epubBlockText(block);
    if (type == 'heading') {
      if (text.trim().isNotEmpty) result.add({...Map<String, Object?>.from(block), 'type': 'heading', 'text': text, 'children': const []});
      return;
    }
    if (type == 'table' || type == 'row' || (type == 'cell' && children.isNotEmpty)) {
      for (final child in children) {
        visit(child);
      }
      return;
    }
    if (text.trim().isNotEmpty) result.add({...Map<String, Object?>.from(block), 'type': 'paragraph', 'text': text, 'children': const []});
    for (final child in children) {
      visit(child);
    }
  }

  for (final block in blocks) {
    visit(block);
  }
  return result;
}

List<Map<String, Object?>> _epubComicBlocks(List<Map<String, Object?>> blocks) => [
  for (final block in _epubNestedBlocks(blocks))
    if (block['type'] == 'image') Map<String, Object?>.from(block),
];

Set<String> _epubDeclaredCoverResourceIds(
  XmlElement package,
  Map<String, _ManifestItem> manifest,
  List<_ManifestItem> items,
  Map<String, ArchiveFile> files,
) {
  final cover =
      items.where((item) => item.properties.split(RegExp(r'\s+')).contains('cover-image')).firstOrNull ??
      manifest[_metaProperty(package, 'cover')];
  if (cover == null) return const {};
  final paths = <String>{cover.path};
  if (cover.mediaType == 'image/svg+xml') {
    final entry = files[cover.path];
    if (entry != null) {
      final svg = _xmlBytes(_bytes(entry, _maxResource, 'cover'), _maxResource, 'svg');
      for (final image in svg.rootElement.descendants.whereType<XmlElement>().where((node) => node.name.local == 'image')) {
        final href = image.attributes.where((attribute) => attribute.name.local == 'href').firstOrNull?.value;
        final path = href == null ? null : _resolvePath(_dirOf(cover.path), href);
        if (path != null && files.containsKey(path)) paths.add(path);
      }
    }
  }
  return {for (final path in paths) _stableId('r', path)};
}

bool _epubContainsImageMarkup(XmlDocument document) {
  final body = document.rootElement.findAllElements('body').firstOrNull ?? document.rootElement;
  return body.descendants.whereType<XmlElement>().any(
    (element) => const {'img', 'svg', 'image'}.contains(element.name.local.toLowerCase()),
  );
}

bool _epubHasBackmatterSemantics(XmlDocument document) {
  final body = document.rootElement.findAllElements('body').firstOrNull ?? document.rootElement;
  bool isBackmatter(XmlElement element) => element.attributes.any(
    (attribute) =>
        attribute.name.local == 'type' &&
        attribute.name.namespaceUri == 'http://www.idpf.org/2007/ops' &&
        attribute.value.split(RegExp(r'\s+')).contains('backmatter'),
  );
  if (isBackmatter(body)) return true;
  final contentElements = body.children.whereType<XmlElement>().toList(growable: false);
  return contentElements.length == 1 && isBackmatter(contentElements.single);
}

String _epubBackmatterDescription(List<Map<String, Object?>> blocks) =>
    _epubTextBlocks(blocks).map(_epubBlockText).where((text) => text.trim().isNotEmpty).join('\n');
