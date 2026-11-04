/// Local document parser contracts. Parsers own only a supplied staging folder;
/// ContentLibrary owns durable identities, file objects and commit lifecycles.
/// Paths below are staging-relative internal descriptors, never UI contracts.
library;

import 'dart:io';

enum LocalDocumentFormat { txt, epub }

enum LocalDocumentReadingKind { text, comic }

const localDocumentMaxFileBytes = 256 * 1024 * 1024;
const localDocumentMaxExpandedBytes = 2 * 1024 * 1024 * 1024;
const localDocumentMaxEntries = 20000;
const localDocumentParserVersion = 1;

final class LocalDocumentException implements Exception {
  const LocalDocumentException(this.code, [this.detail]);
  final String code;
  final String? detail;
  @override
  String toString() => 'LocalDocumentException($code${detail == null ? '' : ': $detail'})';
}

/// Worker-local cancellation. The coordinator may also terminate an isolate;
/// all output remains uncommitted until ContentLibrary validates the manifest.
final class LocalDocumentCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw const LocalDocumentException('cancelled');
  }
}

typedef LocalDocumentProgress = void Function(String stage, int completed, int? total);

final class LocalDocumentParseOptions {
  const LocalDocumentParseOptions({this.encoding, this.chapterRule = 'auto', this.allowMalformed = false});
  final String? encoding;

  /// auto, chinese, english, none, or a bounded user expression prefixed regex:.
  final String chapterRule;
  final bool allowMalformed;
  Map<String, Object?> toJson() => {'encoding': encoding, 'chapterRule': chapterRule, 'allowMalformed': allowMalformed};
  factory LocalDocumentParseOptions.fromJson(Map<String, Object?> value) => LocalDocumentParseOptions(
    encoding: value['encoding'] as String?,
    chapterRule: value['chapterRule'] as String? ?? 'auto',
    allowMalformed: value['allowMalformed'] == true,
  );
}

final class LocalDocumentChapter {
  const LocalDocumentChapter({
    required this.id,
    required this.title,
    required this.index,
    required this.contentFile,
    required this.wordCount,
    this.startOffset = 0,
    this.href,
  });
  final String id, title, contentFile;
  final int index, wordCount, startOffset;
  final String? href;
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'index': index,
    'contentFile': contentFile,
    'wordCount': wordCount,
    'startOffset': startOffset,
    'href': href,
  };
  factory LocalDocumentChapter.fromJson(Map<String, Object?> v) => LocalDocumentChapter(
    id: v['id']! as String,
    title: v['title']! as String,
    index: v['index']! as int,
    contentFile: v['contentFile']! as String,
    wordCount: v['wordCount']! as int,
    startOffset: v['startOffset'] as int? ?? 0,
    href: v['href'] as String?,
  );
}

final class LocalDocumentResource {
  const LocalDocumentResource({required this.id, required this.file, required this.mimeType, required this.bytes, this.href});
  final String id, file, mimeType;
  final int bytes;
  final String? href;
  Map<String, Object?> toJson() => {'id': id, 'file': file, 'mimeType': mimeType, 'bytes': bytes, 'href': href};
  factory LocalDocumentResource.fromJson(Map<String, Object?> v) => LocalDocumentResource(
    id: v['id']! as String,
    file: v['file']! as String,
    mimeType: v['mimeType']! as String,
    bytes: v['bytes']! as int,
    href: v['href'] as String?,
  );
}

final class LocalDocumentNavigation {
  const LocalDocumentNavigation({required this.label, required this.chapterId, this.fragment, this.children = const []});
  final String label, chapterId;
  final String? fragment;
  final List<LocalDocumentNavigation> children;
  Map<String, Object?> toJson() => {
    'label': label,
    'chapterId': chapterId,
    'fragment': fragment,
    'children': [for (final child in children) child.toJson()],
  };
  factory LocalDocumentNavigation.fromJson(Map<String, Object?> v) => LocalDocumentNavigation(
    label: v['label']! as String,
    chapterId: v['chapterId']! as String,
    fragment: v['fragment'] as String?,
    children: [
      for (final child in v['children'] as List? ?? const []) LocalDocumentNavigation.fromJson(Map<String, Object?>.from(child as Map)),
    ],
  );
}

/// Each chapter JSON contains {chapterId, title, blocks:[...]}. Blocks contain
/// id,type,text,spans,children,resourceId,href,style,anchor. A text span contains
/// text,bold,italic,underline,superscript,subscript,href. Text offsets are UTF-16.
/// Supported block types: paragraph,heading,image,listItem,quote,pre,table,row,cell,rule.
final class ParsedLocalDocument {
  const ParsedLocalDocument({
    required this.format,
    required this.title,
    required this.chapters,
    this.author,
    this.language,
    this.description,
    this.encoding,
    this.coverResourceId,
    this.resources = const [],
    this.navigation = const [],
    this.warnings = const [],
    this.attributes = const {},
  });
  final LocalDocumentFormat format;
  final String title;
  final String? author, language, description, encoding, coverResourceId;
  final List<LocalDocumentChapter> chapters;
  final List<LocalDocumentResource> resources;
  final List<LocalDocumentNavigation> navigation;
  final List<String> warnings;
  final Map<String, Object?> attributes;
  LocalDocumentReadingKind? get readingKind => switch (format) {
    LocalDocumentFormat.txt => LocalDocumentReadingKind.text,
    LocalDocumentFormat.epub => switch (attributes['readingKind']) {
      'text' => LocalDocumentReadingKind.text,
      'comic' => LocalDocumentReadingKind.comic,
      _ => null,
    },
  };
  int get wordCount => chapters.fold(0, (sum, chapter) => sum + chapter.wordCount);
  int get logicalChapterCount => attributes['logicalChapterStarts'] is List
      ? (attributes['logicalChapterStarts']! as List).length
      : chapters.map((chapter) => chapter.href ?? chapter.id).toSet().length;
  Map<String, Object?> toJson() => {
    'version': localDocumentParserVersion,
    'format': format.name,
    'title': title,
    'author': author,
    'language': language,
    'description': description,
    'encoding': encoding,
    'coverResourceId': coverResourceId,
    'chapters': [for (final c in chapters) c.toJson()],
    'resources': [for (final r in resources) r.toJson()],
    'navigation': [for (final n in navigation) n.toJson()],
    'warnings': warnings,
    'attributes': attributes,
  };
  factory ParsedLocalDocument.fromJson(Map<String, Object?> v) {
    if (v['version'] != localDocumentParserVersion) throw const LocalDocumentException('unsupported_parser_version');
    return ParsedLocalDocument(
      format: LocalDocumentFormat.values.byName(v['format']! as String),
      title: v['title']! as String,
      author: v['author'] as String?,
      language: v['language'] as String?,
      description: v['description'] as String?,
      encoding: v['encoding'] as String?,
      coverResourceId: v['coverResourceId'] as String?,
      chapters: [for (final c in v['chapters']! as List) LocalDocumentChapter.fromJson(Map<String, Object?>.from(c as Map))],
      resources: [for (final r in v['resources'] as List? ?? const []) LocalDocumentResource.fromJson(Map<String, Object?>.from(r as Map))],
      navigation: [
        for (final n in v['navigation'] as List? ?? const []) LocalDocumentNavigation.fromJson(Map<String, Object?>.from(n as Map)),
      ],
      warnings: List<String>.from(v['warnings'] as List? ?? const []),
      attributes: Map<String, Object?>.from(v['attributes'] as Map? ?? const {}),
    );
  }
}

abstract interface class LocalDocumentParser {
  Future<ParsedLocalDocument> parse({
    required File source,
    required Directory output,
    LocalDocumentParseOptions options = const LocalDocumentParseOptions(),
    LocalDocumentCancellation? cancellation,
    LocalDocumentProgress? onProgress,
  });
}
