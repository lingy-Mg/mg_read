/// Catalog chapter-state presentation and its recoverable retry action.
///
/// Noninteractive badges keep their intrinsic width. Failed-state retry badges
/// retain a compact 32 dp hit target, tooltip, and one explicit semantics node;
/// their icon pair scales down only when it cannot fit that target.
library;

import 'package:mg_read_motion/mg_read_motion.dart';
import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../reader_accessible_tooltip.dart';
import '../reader_theme.dart';

abstract final class ReaderChapterStateStrings {
  static const downloaded = '已下载';
  static const notDownloaded = '未下载';
  static const downloading = '下载中';
  static const failed = '下载失败';
  static const read = '已读';
  static const unread = '未读';
  static const loading = '状态加载中';
  static const retry = '重试加载章节状态';

  static String wordCount(int value) => '$value 字';
}

class ReaderChapterStateBadge extends StatelessWidget {
  const ReaderChapterStateBadge({
    required this.availability,
    required this.palette,
    this.wordCount,
    this.hasBeenRead = false,
    this.loading = false,
    this.onRetry,
    super.key,
  });

  factory ReaderChapterStateBadge.fromInfo({
    required ReaderChapterInfo chapter,
    required ReaderPalette palette,
    bool loading = false,
    VoidCallback? onRetry,
    Key? key,
  }) => ReaderChapterStateBadge(
    key: key,
    availability: chapter.availability,
    wordCount: chapter.wordCount,
    hasBeenRead: chapter.hasBeenRead,
    palette: palette,
    loading: loading,
    onRetry: onRetry,
  );

  factory ReaderChapterStateBadge.fromState({
    required ReaderChapterState state,
    required ReaderPalette palette,
    bool loading = false,
    VoidCallback? onRetry,
    Key? key,
  }) => ReaderChapterStateBadge(
    key: key,
    availability: state.availability,
    wordCount: state.wordCount,
    hasBeenRead: state.hasBeenRead,
    palette: palette,
    loading: loading,
    onRetry: onRetry,
  );

  final ReaderChapterAvailability availability;
  final int? wordCount;
  final bool hasBeenRead;
  final ReaderPalette palette;
  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final (String?, IconData, Color) availabilityStyle = switch (availability) {
      ReaderChapterAvailability.downloaded => (
        ReaderChapterStateStrings.downloaded,
        Icons.download_done_rounded,
        palette.accent,
      ),
      ReaderChapterAvailability.notDownloaded => (
        ReaderChapterStateStrings.notDownloaded,
        Icons.cloud_download_outlined,
        palette.secondaryText,
      ),
      ReaderChapterAvailability.downloading => (
        ReaderChapterStateStrings.downloading,
        Icons.downloading_rounded,
        palette.accent,
      ),
      ReaderChapterAvailability.failed => (
        ReaderChapterStateStrings.failed,
        Icons.error_outline_rounded,
        palette.accent,
      ),
      ReaderChapterAvailability.unknown => (
        null,
        Icons.cloud_download_outlined,
        palette.secondaryText,
      ),
    };
    final List<String> semantics = <String>[
      if (loading) ReaderChapterStateStrings.loading,
      if (!loading && availabilityStyle.$1 != null) availabilityStyle.$1!,
      if (wordCount != null && wordCount! >= 0)
        ReaderChapterStateStrings.wordCount(wordCount!),
      hasBeenRead
          ? ReaderChapterStateStrings.read
          : ReaderChapterStateStrings.unread,
    ];
    if (semantics.isEmpty) return const SizedBox.shrink();
    final Color readingStateColor = hasBeenRead
        ? palette.secondaryText
        : palette.accent;
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          hasBeenRead
              ? Icons.done_rounded
              : Icons.radio_button_unchecked_rounded,
          size: 15,
          color: readingStateColor,
        ),
        const SizedBox(width: 6),
        loading
            ? SizedBox.square(
                dimension: 15,
                child: MotionCircularProgressIndicator(
                  strokeWidth: 1.7,
                  color: availabilityStyle.$3,
                ),
              )
            : Icon(availabilityStyle.$2, size: 16, color: availabilityStyle.$3),
      ],
    );
    if (availability != ReaderChapterAvailability.failed || onRetry == null) {
      return Semantics(
        label: semantics.join('，'),
        excludeSemantics: true,
        child: content,
      );
    }
    return ReaderAccessibleTooltip(
      label: '${semantics.join('，')}，${ReaderChapterStateStrings.retry}',
      tooltipMessage: ReaderChapterStateStrings.retry,
      onTap: onRetry!,
      child: MotionMaterial(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onRetry,
          child: SizedBox.square(
            dimension: 32,
            child: FittedBox(fit: BoxFit.scaleDown, child: content),
          ),
        ),
      ),
    );
  }
}
