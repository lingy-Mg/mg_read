/// 书架条目的宿主投影。
///
/// 职责：
/// - 提供书架主体即时显示所需的稳定字段和封面来源身份。
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

  /// Displayable full-book fraction last reported by the reader.
  final double? readingProgress;

  /// Zero-based chapter order of the saved semantic position.
  final int? readingChapterIndex;

  /// Time of the durable semantic position, in UTC.
  final DateTime? lastReadAtUtc;
}
