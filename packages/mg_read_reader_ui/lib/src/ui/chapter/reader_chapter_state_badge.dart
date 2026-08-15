import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../reader_theme.dart';

abstract final class ReaderChapterStateStrings {
  static const downloaded = '已下载';
  static const notDownloaded = '未下载';
  static const downloading = '下载中';
  static const failed = '下载失败';
  static const read = '已读';
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
    final (String?, IconData?, Color) availabilityStyle =
        switch (availability) {
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
            null,
            palette.secondaryText,
          ),
        };
    final List<String> semantics = <String>[
      if (loading) ReaderChapterStateStrings.loading,
      if (!loading && availabilityStyle.$1 != null) availabilityStyle.$1!,
      if (wordCount != null && wordCount! >= 0)
        ReaderChapterStateStrings.wordCount(wordCount!),
      if (hasBeenRead) ReaderChapterStateStrings.read,
    ];
    if (semantics.isEmpty) return const SizedBox.shrink();
    final Widget content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Wrap(
        spacing: 7,
        runSpacing: 3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (loading)
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            )
          else if (availabilityStyle.$2 != null)
            Icon(availabilityStyle.$2, size: 16, color: availabilityStyle.$3),
          if (!loading && availabilityStyle.$1 != null)
            Text(
              availabilityStyle.$1!,
              style: TextStyle(
                color: availabilityStyle.$3,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (wordCount != null && wordCount! >= 0)
            Text(
              ReaderChapterStateStrings.wordCount(wordCount!),
              style: TextStyle(color: palette.secondaryText, fontSize: 12),
            ),
          if (hasBeenRead)
            Text(
              ReaderChapterStateStrings.read,
              style: TextStyle(color: palette.secondaryText, fontSize: 12),
            ),
        ],
      ),
    );
    if (availability != ReaderChapterAvailability.failed || onRetry == null) {
      return Semantics(
        label: semantics.join('，'),
        excludeSemantics: true,
        child: content,
      );
    }
    return Tooltip(
      message: ReaderChapterStateStrings.retry,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: '${semantics.join('，')}，${ReaderChapterStateStrings.retry}',
        onTap: onRetry,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onRetry,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
