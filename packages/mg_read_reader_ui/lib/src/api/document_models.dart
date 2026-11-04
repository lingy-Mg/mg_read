import 'package:flutter/foundation.dart';

/// Immutable reflowable document content prepared by the host.
@immutable
class ReaderDocumentSpan {
  const ReaderDocumentSpan({
    required this.text,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.superscript = false,
    this.subscript = false,
    this.href,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool superscript;
  final bool subscript;
  final String? href;

  factory ReaderDocumentSpan.fromJson(Map<String, Object?> json) =>
      ReaderDocumentSpan(
        text: json['text'] as String? ?? '',
        bold: json['bold'] == true,
        italic: json['italic'] == true,
        underline: json['underline'] == true,
        superscript: json['superscript'] == true,
        subscript: json['subscript'] == true,
        href: json['href'] as String?,
      );
}

/// A typed, layout-independent XHTML-derived block.
@immutable
class ReaderDocumentBlock {
  const ReaderDocumentBlock({
    required this.id,
    required this.type,
    this.text = '',
    this.spans = const [],
    this.children = const [],
    this.resourceId,
    this.href,
    this.style = const {},
    this.anchor,
    this.anchors = const [],
  });

  final String id;
  final String type;
  final String text;
  final List<ReaderDocumentSpan> spans;
  final List<ReaderDocumentBlock> children;
  final String? resourceId;
  final String? href;
  final Map<String, Object?> style;
  final String? anchor;
  final List<String> anchors;

  factory ReaderDocumentBlock.fromJson(Map<String, Object?> json) {
    final rawSpans = json['spans'] as List? ?? const [];
    final rawChildren = json['children'] as List? ?? const [];
    return ReaderDocumentBlock(
      id: json['id'] as String? ?? '',
      type: json['type'] as String? ?? 'paragraph',
      text: json['text'] as String? ?? '',
      spans: List.unmodifiable(
        rawSpans.whereType<Map>().map(
          (value) =>
              ReaderDocumentSpan.fromJson(Map<String, Object?>.from(value)),
        ),
      ),
      children: List.unmodifiable(
        rawChildren.whereType<Map>().map(
          (value) =>
              ReaderDocumentBlock.fromJson(Map<String, Object?>.from(value)),
        ),
      ),
      resourceId: json['resourceId'] as String?,
      href: json['href'] as String?,
      style: Map.unmodifiable(
        Map<String, Object?>.from(json['style'] as Map? ?? const {}),
      ),
      anchor: json['anchor'] as String?,
      anchors: List.unmodifiable(
        (json['anchors'] as List? ?? const []).whereType<String>(),
      ),
    );
  }

  String get plainText =>
      spans.isEmpty ? text : spans.map((s) => s.text).join();
}

/// One complete chapter after host-side EPUB package/path resolution.
@immutable
class ReaderDocumentChapter {
  ReaderDocumentChapter({
    required this.chapterId,
    required this.title,
    required List<ReaderDocumentBlock> blocks,
  }) : blocks = List.unmodifiable(blocks);
  final String chapterId;
  final String title;
  final List<ReaderDocumentBlock> blocks;
}

/// Host-resolved internal navigation target. Null means external or unsupported.
@immutable
class ReaderDocumentLinkTarget {
  const ReaderDocumentLinkTarget({required this.chapterId, this.anchor});
  final String chapterId;
  final String? anchor;
}
