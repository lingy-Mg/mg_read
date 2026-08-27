/// 书架条目的宿主投影。
///
/// 职责：
/// - 提供书架主体和长按详情即时显示所需的稳定字段与来源身份。
/// - 将封面字节解析延后至展示层异步执行。
///
/// 注意：
/// - 不携带持久化路径、Runtime DTO 或网络响应。
/// - 缺失封面身份时由展示层降级，不影响条目可见性。
///
/// TODO:
/// - 无。
library;

final class LibraryItemSummary {
  /// Creates one stable library-item projection.
  const LibraryItemSummary({
    required this.id,
    required this.title,
    this.author,
    this.coverUrl,
    this.coverBytes,
    this.coverPluginId,
    this.coverPluginVersion,
    this.coverRemoteContentId,
    this.sourceName,
    this.sourceUrl,
    this.description,
    this.language,
    this.accessCode,
    this.wordCount,
    this.chapterCount,
    this.publishedAt,
    this.updatedAt,
    this.statusLabel,
    this.latestChapterId,
    this.latestChapterTitle,
    this.latestChapterUrl,
    this.latestChapterUpdatedAt,
    this.categories = const <String>[],
    this.tags = const <String>[],
    this.attributes = const <LibraryItemSummaryAttribute>[],
    this.readingProgress,
    this.readingChapterIndex,
    this.lastReadAtUtc,
  }) : assert(id != ''),
       assert(title != ''),
       assert(readingProgress == null || (readingProgress >= 0 && readingProgress <= 1));

  /// Stable identifier generated and owned by the host application.
  final String id;

  /// User-visible title from the current local projection.
  final String title;
  final String? author;
  final Uri? coverUrl;

  /// Cover bytes loaded from the app-owned file object, when available.
  final List<int>? coverBytes;
  final String? coverPluginId;
  final String? coverPluginVersion;
  final String? coverRemoteContentId;
  final String? sourceName;
  final Uri? sourceUrl;
  final String? description;
  final String? language;
  final String? accessCode;
  final int? wordCount;
  final int? chapterCount;
  final DateTime? publishedAt;
  final DateTime? updatedAt;
  final String? statusLabel;
  final String? latestChapterId;
  final String? latestChapterTitle;
  final Uri? latestChapterUrl;
  final DateTime? latestChapterUpdatedAt;
  final List<String> categories;
  final List<String> tags;
  final List<LibraryItemSummaryAttribute> attributes;

  /// Displayable full-book fraction last reported by the reader.
  final double? readingProgress;

  /// Zero-based chapter order of the saved semantic position.
  final int? readingChapterIndex;

  /// Time of the durable semantic position, in UTC.
  final DateTime? lastReadAtUtc;
}

/// Structured detail attribute retained in the library overview projection.
final class LibraryItemSummaryAttribute {
  const LibraryItemSummaryAttribute({required this.key, required this.label, required this.value});

  final String key;
  final String label;
  final String value;
}
