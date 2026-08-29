import 'package:mg_read/core/errors/app_error.dart';

/// Stable, safe-to-display reasons why a shelf detail route cannot start.
enum LibraryBookDetailFailureReason {
  itemRead('item_read', '无法读取本地书架记录。'),
  itemMissing('item_missing', '书架记录不存在，可能已被删除。'),
  unsupportedContent('unsupported_content', '当前书架条目不是可阅读的小说。'),
  sourceMissing('source_missing', '书架记录缺少数据源信息，请重新加入书架。'),
  catalogRead('catalog_read', '无法读取本地书架目录。'),
  presentationOpen('presentation_open', '无法显示书籍详情页面。'),
  unexpected('unexpected', '打开书架书籍详情时发生未分类错误。');

  const LibraryBookDetailFailureReason(this.wireValue, this.userMessage);

  final String wireValue;
  final String userMessage;
}

/// Bounded diagnostic metadata for the shelf-detail route.
final class LibraryBookDetailFailure implements Exception {
  const LibraryBookDetailFailure({required this.reason, required this.error});

  final LibraryBookDetailFailureReason reason;
  final AppError error;

  String get diagnosticCode =>
      'library_detail_${reason.wireValue}_${error.code.wireValue}';

  factory LibraryBookDetailFailure.fromError(Object error) {
    if (error case final LibraryBookDetailFailure failure) return failure;
    return LibraryBookDetailFailure(
      reason: LibraryBookDetailFailureReason.unexpected,
      error: AppError.fromUnknown(error),
    );
  }

  @override
  String toString() => 'LibraryBookDetailFailure($diagnosticCode)';
}
