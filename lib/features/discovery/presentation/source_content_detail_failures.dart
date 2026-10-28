part of 'source_content_detail_sheet.dart';

/// Compact detail loading/failure presentation blocks.
class _DetailFailure extends StatelessWidget {
  const _DetailFailure({
    required this.error,
    this.capability = 'source.getContent.v1',
    this.hasRetainedData = false,
    this.sourceName,
    this.pluginId,
    this.pluginVersion,
    this.contentId,
    this.chapterId,
    this.onCopy = _copySourceDetailFailure,
    this.onRetry,
  });

  final AppError error;
  final String capability;
  final bool hasRetainedData;
  final String? sourceName;
  final String? pluginId;
  final String? pluginVersion;
  final String? contentId;
  final String? chapterId;
  final SourceDetailFailureCopy onCopy;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final detail = error.detail?.trim();
    final originalReason = detail == null || detail.isEmpty ? null : '原始原因：$detail';
    final diagnosticPayloadParts = <String>[
      'MgRead 详情加载失败诊断信息',
      '操作：加载详情或目录',
      if (sourceName case final value?) '数据源名称：$value',
      if (pluginId case final value?) '插件 ID：$value',
      if (pluginVersion case final value?) '插件版本：$value',
      if (contentId case final value?) '内容 ID：$value',
      if (chapterId case final value?) '章节 ID：$value',
      '失败阶段：$capability',
      '错误码：${error.code.wireValue}',
      '错误分类：${error.category.name}',
      '可重试：${error.retryable ? '允许' : '不建议'}',
      '用户提示：${_detailErrorDescription(error)}',
      if (error.retryAfter case final retryAfter?) '建议等待：${retryAfter.inMilliseconds}ms',
      if (error.traceId case final traceId?) '跟踪 ID：$traceId',
      if (hasRetainedData) '已保留列表预览；实时详情和可播放选集尚未加载。',
      if (error.location case final location? when location.trim().isNotEmpty) '诊断位置：${location.trim()}',
    ];
    if (originalReason != null) diagnosticPayloadParts.add(originalReason);
    final diagnosticPayload = diagnosticPayloadParts.join('\n');
    return Semantics(
      liveRegion: true,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Material(
            key: const Key('source-content-sheet-failure'),
            color: colors.errorContainer,
            shape: RoundedRectangleBorder(
              borderRadius: AppRadii.surface,
              side: BorderSide(color: colors.error),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.regular),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
                      const SizedBox(width: AppSpacing.compact),
                      Expanded(
                        child: Text('详情加载失败', style: theme.textTheme.titleSmall?.copyWith(color: colors.onErrorContainer)),
                      ),
                      TextButton(
                        key: const Key('source-detail-error-copy'),
                        onPressed: () => unawaited(_copySafely(diagnosticPayload)),
                        child: const Text('复制诊断信息'),
                      ),
                      if (onRetry != null) TextButton(key: const Key('source-detail-retry'), onPressed: onRetry, child: const Text('重试')),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.unit),
                  SelectableText(
                    _detailErrorDescription(error),
                    style: theme.textTheme.bodyMedium?.copyWith(color: colors.onErrorContainer),
                  ),
                  if (originalReason != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.compact),
                    SelectableText(
                      originalReason,
                      key: const Key('source-detail-error-cause'),
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.onErrorContainer, fontFamily: 'monospace'),
                    ),
                  ],
                  if (hasRetainedData) ...<Widget>[
                    const SizedBox(height: AppSpacing.unit),
                    SelectableText('已保留列表预览；实时详情和可播放选集尚未加载。', style: theme.textTheme.bodySmall?.copyWith(color: colors.onErrorContainer)),
                  ],
                  const SizedBox(height: AppSpacing.compact),
                  SelectableText(
                    '错误码：${error.code.wireValue}\n失败阶段：$capability\n自动重试：${error.retryable ? '允许' : '不建议'}',
                    key: const Key('source-detail-error-details'),
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.onErrorContainer, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copySafely(String payload) async {
    try {
      await onCopy(payload);
    } catch (_) {
      // Clipboard availability must not prevent retrying the detail request.
    }
  }
}

String _detailErrorDescription(AppError error) => switch (error.code) {
  AppErrorCode.invalidFormat => '数据源返回的详情或目录格式不符合规范。请更新插件后重试。',
  AppErrorCode.runtimeUnavailable || AppErrorCode.runtimeStartFailed || AppErrorCode.runtimeNotReady => '数据源运行环境当前不可用，请重启应用后重试。',
  AppErrorCode.pluginNotFound || AppErrorCode.pluginDisabled || AppErrorCode.pluginDamaged => '当前数据源不可用，请在数据源管理中检查插件状态。',
  AppErrorCode.timeout || AppErrorCode.rateLimited || AppErrorCode.overloaded => '请求暂时没有完成，请稍后重试。',
  _ => '无法安全加载实时详情，请根据下方稳定错误信息继续定位。',
};

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return DiscoveryCoverVariant.values[checksum % DiscoveryCoverVariant.values.length];
}

String _wordCount(int? value) {
  if (value == null) return '—';
  return _formatReadableCount(value);
}

String _wordCountLabel(int? value) => value != null && value >= 10000 ? '万字' : '字数';

String _chapterCount(int? value) => value == null ? '—' : _formatReadableCount(value);

int? _chapterTotal({required int? detailTotal, required int loadedCount}) {
  if (loadedCount > 0) return loadedCount;
  return detailTotal != null && detailTotal > 0 ? detailTotal : null;
}

String _formatStatValue(String value) {
  final normalized = value.trim();
  final parsed = num.tryParse(normalized);
  if (parsed == null || !parsed.isFinite) return value;
  if (parsed == parsed.roundToDouble()) {
    return _formatReadableCount(parsed.toInt());
  }
  if (parsed.abs() >= 10000) {
    return _formatReadableDecimal(parsed);
  }
  return normalized;
}

String _formatReadableCount(int value) {
  final absolute = value.abs();
  if (absolute >= 100000000) {
    return '${value < 0 ? '-' : ''}${_trimDecimal(absolute / 100000000)}亿';
  }
  if (absolute >= 10000) {
    return '${value < 0 ? '-' : ''}${_trimDecimal(absolute / 10000)}万';
  }
  return '$value';
}

String _formatReadableDecimal(num value) {
  final absolute = value.abs();
  if (absolute >= 100000000) {
    return '${value < 0 ? '-' : ''}${_trimDecimal(absolute / 100000000)}亿';
  }
  return '${value < 0 ? '-' : ''}${_trimDecimal(absolute / 10000)}万';
}

String _trimDecimal(num value) => value.toStringAsFixed(2).replaceFirst(RegExp(r'\.0+$'), '').replaceFirst(RegExp(r'0+$'), '');
String _statusLabel(PluginContentStatus value) => switch (value) {
  PluginContentStatus.ongoing => '连载中',
  PluginContentStatus.completed => '已完结',
  PluginContentStatus.hiatus => '暂停',
  PluginContentStatus.unknown => '未知',
};
String _chapterSubtitle(PluginChapterSummary chapter) => <String>[
  if (chapter.wordCount != null) '${chapter.wordCount} 字',
  if (chapter.updatedAt != null) _formatDateTime(chapter.updatedAt!),
  if (chapter.isLocked != null) chapter.isLocked! ? '已锁定' : '可阅读',
].join(' · ');
String _mangaPageSubtitle(PluginMangaPage page) => <String>[
  if (page.mimeType != null) page.mimeType!,
  if (page.width != null && page.height != null) '${page.width} × ${page.height}',
].join(' · ');

String? _attributeValue(Iterable<PluginContentAttribute> attributes, String key) {
  for (final attribute in attributes) {
    if (attribute.key == key) return attribute.value;
  }
  return null;
}

Iterable<PluginContentAttribute> _displayAttributes(Iterable<PluginContentAttribute> attributes) => attributes.where(
  (attribute) =>
      attribute.key != 'heat' &&
      attribute.key != 'favorites' &&
      attribute.key != 'rating' &&
      attribute.key != 'ratingCount' &&
      attribute.key != 'discoveryUpdatedLabel',
);

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} ${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
