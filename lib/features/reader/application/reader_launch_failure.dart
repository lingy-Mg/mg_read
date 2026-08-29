import 'package:mg_read/core/errors/app_error.dart';

/// Stable, safe-to-display reasons for a persisted reader launch failure.
///
/// The reason and normalized [error] are deliberately small diagnostic
/// metadata. They never retain source URLs, book data, raw exceptions, or
/// stack traces.
enum ReaderLaunchFailureReason {
  shelfItemMissing('shelf_item_missing', '书架记录不存在，或已被删除。'),
  unsupportedContentKind('unsupported_content_kind', '当前阅读器只能打开小说内容。'),
  shelfSourceMissing('shelf_source_missing', '书架记录缺少数据源信息，请从发现页重新加入书架。'),
  sourceDetail('source_detail', '无法从数据源获取这本书的详情。'),
  sourceContentKind('source_content_kind', '数据源返回的内容不是可阅读的小说。'),
  sourceCatalog('source_catalog', '无法从数据源获取章节目录。'),
  sourceCatalogEmpty('source_catalog_empty', '数据源没有返回可阅读的章节。'),
  unexpected('unexpected', '准备阅读内容时发生未分类错误。');

  const ReaderLaunchFailureReason(this.wireValue, this.userMessage);

  final String wireValue;
  final String userMessage;
}

/// A reader-launch failure containing only stable, non-sensitive diagnostics.
final class ReaderLaunchFailure implements Exception {
  const ReaderLaunchFailure({required this.reason, required this.error});

  final ReaderLaunchFailureReason reason;
  final AppError error;

  /// A copyable code for user support and diagnostics correlation.
  String get diagnosticCode =>
      'reader_launch_${reason.wireValue}_${error.code.wireValue}';

  factory ReaderLaunchFailure.fromError(Object error) {
    if (error case final ReaderLaunchFailure failure) return failure;
    return ReaderLaunchFailure(
      reason: ReaderLaunchFailureReason.unexpected,
      error: AppError.fromUnknown(error),
    );
  }

  @override
  String toString() => 'ReaderLaunchFailure($diagnosticCode)';
}
