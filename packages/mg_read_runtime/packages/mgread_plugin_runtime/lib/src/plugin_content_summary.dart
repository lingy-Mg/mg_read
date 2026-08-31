/// Public source-content summary models for the Flutter Runtime Facade.
///
/// Owns media kind, independent cover orientation and the immutable summary
/// shared by search, discovery and detail. Host-local cover bytes never cross
/// the Runtime wire boundary.
part of mgread_plugin_runtime;

enum PluginContentKind {
  audio('audio'),
  novel('novel'),
  manga('manga'),
  video('video');

  const PluginContentKind(this.code);
  final String code;
}

/// Selects one of the host's two generic cover composition families.
///
/// Cover orientation is independent from [PluginContentKind].
enum PluginCoverOrientation {
  landscape('landscape'),
  portrait('portrait');

  const PluginCoverOrientation(this.code);
  final String code;
}

/// Rich, closed content projection shared by search, discovery and detail.
@immutable
final class PluginContentSummary {
  PluginContentSummary({
    required this.id,
    required this.title,
    required this.contentKind,
    this.coverOrientation = PluginCoverOrientation.portrait,
    required this.author,
    required this.url,
    required this.coverUrl,
    this.coverBytes,
    required this.description,
    required this.language,
    required this.status,
    required this.access,
    required this.wordCount,
    required this.chapterCount,
    required this.publishedAt,
    required this.updatedAt,
    required this.latestChapter,
    required List<String> categories,
    required List<String> tags,
    required List<PluginContentAttribute> attributes,
  }) : categories = List<String>.unmodifiable(categories),
       tags = List<String>.unmodifiable(tags),
       attributes = List<PluginContentAttribute>.unmodifiable(attributes);

  final String id;
  final String title;
  final PluginContentKind contentKind;
  final PluginCoverOrientation coverOrientation;
  final String? author;
  final Uri? url;
  final Uri? coverUrl;

  /// Host-local decoded cover bytes. This is never read from or written to
  /// the Runtime wire payload; the Flutter host may fill it from its cover
  /// persistence adapter after the typed result is decoded.
  final List<int>? coverBytes;
  final String? description;
  final String? language;
  final PluginContentStatus status;
  final PluginAccessKind access;
  final int? wordCount;
  final int? chapterCount;
  final DateTime? publishedAt;
  final DateTime? updatedAt;
  final PluginLatestChapter? latestChapter;
  final List<String> categories;
  final List<String> tags;
  final List<PluginContentAttribute> attributes;
}
