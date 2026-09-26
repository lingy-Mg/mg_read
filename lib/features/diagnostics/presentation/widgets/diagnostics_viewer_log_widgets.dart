/// Presentational building blocks for diagnostics lifecycle, files, events,
/// structured fields, and bounded text previews.
///
/// State, I/O, capture ownership, and refresh lifecycles remain in the parent
/// diagnostics viewer page; these widgets only render values and callbacks.
part of '../diagnostics_viewer_page.dart';

class _LogFilePicker extends StatelessWidget {
  const _LogFilePicker({
    required this.files,
    required this.selectedFileId,
    required this.onSelected,
    required this.onDelete,
    required this.onExport,
  });
  final List<DiagnosticsViewerLogFile> files;
  final String? selectedFileId;
  final ValueChanged<DiagnosticsViewerLogFile> onSelected;
  final VoidCallback onDelete;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final selected = files.where((file) => file.fileId == selectedFileId).firstOrNull;
    final history = files.where((file) => !file.isLive).toList();
    final live = selected?.isLive ?? true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(live ? '最近记录' : '已保存的记录', style: Theme.of(context).textTheme.titleMedium)),
            if (history.isNotEmpty)
              PopupMenuButton<DiagnosticsViewerLogFile>(
                key: const Key('diagnostics-history'),
                tooltip: '查看历史记录',
                onSelected: onSelected,
                itemBuilder: (context) => files
                    .map(
                      (file) => PopupMenuItem(
                        key: Key('diagnostics-log-${file.fileId}'),
                        value: file,
                        child: Text(
                          file.isLive
                              ? '本次运行'
                              : '${_formatFileDate(file.startedAtUtcMicros)} · ${_formatBytes(file.storedBytes)}${file.isCurrent ? ' · 当前' : ''}',
                        ),
                      ),
                    )
                    .toList(),
                child: const Padding(
                  padding: EdgeInsets.all(AppSpacing.compact),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Icon(Icons.history_rounded, size: 20), SizedBox(width: 6), Text('历史记录')],
                  ),
                ),
              ),
          ],
        ),
        if (selected != null && !live) ...[
          Text(_formatFileDate(selected.startedAtUtcMicros), style: Theme.of(context).textTheme.bodySmall),
          Wrap(
            spacing: AppSpacing.compact,
            children: [
              TextButton.icon(onPressed: onExport, icon: const Icon(Icons.ios_share_rounded), label: const Text('导出文件')),
              if (!selected.isCurrent)
                TextButton.icon(onPressed: onDelete, icon: const Icon(Icons.delete_outline_rounded), label: const Text('删除文件')),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.compact),
      ],
    );
  }
}

String _formatFileDate(int micros) {
  final date = DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true).toLocal();
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} ${_formatTimestamp(micros).substring(0, 8)}';
}

class _SelectLogFile extends StatelessWidget {
  const _SelectLogFile();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(AppSpacing.page),
    child: Center(child: Text('暂无记录')),
  );
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.expanded,
    required this.loadingDetails,
    required this.previews,
    required this.loadingPreviews,
    required this.onToggle,
    required this.onPreview,
    this.details,
    this.detailError,
  });

  final String? detailError;
  final DiagnosticsViewerEventDetails? details;
  final DiagnosticsViewerEvent event;
  final bool expanded;
  final bool loadingDetails;
  final Set<String> loadingPreviews;
  final ValueChanged<DiagnosticsViewerAttachment> onPreview;
  final VoidCallback onToggle;
  final Map<String, String> previews;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final severityColor = _severityColor(context, event.severity);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: ValueKey<String>('diagnostic-event-${event.identity}'),
            borderRadius: AppRadii.detailCard,
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.regular),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      DecoratedBox(
                        decoration: BoxDecoration(color: severityColor.withValues(alpha: 0.12), borderRadius: AppRadii.pill),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact, vertical: AppSpacing.unit),
                          child: Text(switch (event.severity) {
                            'fatal' => '严重错误',
                            'error' => '错误',
                            'warn' => '警告',
                            'info' => '信息',
                            _ => '调试',
                          }, style: theme.textTheme.labelSmall?.copyWith(color: severityColor, fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.compact),
                      Expanded(
                        child: Text(
                          _componentTitle(event.component),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Text(
                        _formatTimestamp(event.occurredAtUtcMicros),
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                      ),
                      Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: tokens.mutedText),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.compact),
                  Text(
                    _eventTitle(event),
                    style: theme.textTheme.bodyMedium,
                    maxLines: expanded ? null : 3,
                    overflow: expanded ? null : TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppSpacing.unit),
                  Text(
                    event.eventName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...<Widget>[
            Divider(height: 1, color: tokens.divider),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.regular),
              child: _EventDetails(
                details: details,
                loading: loadingDetails,
                errorCode: detailError,
                previews: previews,
                loadingPreviews: loadingPreviews,
                onPreview: onPreview,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EventDetails extends StatelessWidget {
  const _EventDetails({
    required this.loading,
    required this.previews,
    required this.loadingPreviews,
    required this.onPreview,
    this.details,
    this.errorCode,
  });

  final DiagnosticsViewerEventDetails? details;
  final String? errorCode;
  final bool loading;
  final Set<String> loadingPreviews;
  final ValueChanged<DiagnosticsViewerAttachment> onPreview;
  final Map<String, String> previews;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    if (loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (errorCode != null) return Text('详情读取失败：$errorCode');
    final value = details;
    if (value == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('结构化字段', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.compact),
        _PlainTextPreview(text: value.attributesText),
        if (value.attachments.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          Text('详情附件', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.compact),
          ...value.attachments.map((attachment) {
            final preview = previews[attachment.identity];
            final loadingPreview = loadingPreviews.contains(attachment.identity);
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.compact),
              child: DecoratedBox(
                decoration: BoxDecoration(color: tokens.mutedSurface, borderRadius: AppRadii.control),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.compact),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(child: Text('${attachment.kind} · ${attachment.mediaType}', style: theme.textTheme.labelLarge)),
                          Text(
                            _formatBytes(attachment.storedByteLength),
                            style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        '状态 ${attachment.captureState}'
                        '${attachment.truncationReason == null ? '' : ' · ${attachment.truncationReason}'}',
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                      ),
                      const SizedBox(height: AppSpacing.compact),
                      OutlinedButton.icon(
                        onPressed: loadingPreview || attachment.storedByteLength == 0 ? null : () => onPreview(attachment),
                        icon: loadingPreview
                            ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.visibility_outlined),
                        label: const Text('纯文本预览前 32 KiB'),
                      ),
                      if (preview != null) ...<Widget>[const SizedBox(height: AppSpacing.compact), _PlainTextPreview(text: preview)],
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}

class _PlainTextPreview extends StatelessWidget {
  const _PlainTextPreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.compact),
      decoration: BoxDecoration(
        color: tokens.mutedSurface,
        borderRadius: AppRadii.control,
        border: Border.all(color: tokens.divider),
      ),
      child: SingleChildScrollView(
        child: SelectableText(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
      ),
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.errorCode, required this.onRetry});

  final String errorCode;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Column(
        children: <Widget>[
          const Icon(Icons.error_outline_rounded, size: 40),
          const SizedBox(height: AppSpacing.compact),
          Text('日志读取失败：$errorCode'),
          const SizedBox(height: AppSpacing.compact),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _EmptyEvents extends StatelessWidget {
  const _EmptyEvents({required this.isLive});

  final bool isLive;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.page),
      child: Text(
        isLive ? '暂无记录\n出现警告或错误时会自动显示。' : '这个文件中没有可显示的记录。',
        key: const Key('diagnostics-viewer-empty'),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
      ),
    );
  }
}

String _componentTitle(String component) => switch (component) {
  'feature.plugins' => '数据源',
  'feature.library' || 'core.content-library' => '内容与书架',
  'feature.reader' => '阅读器',
  'app.bootstrap' => '应用启动',
  'app.error' => '应用',
  'app.settings' => '设置',
  'app.persistence' => '本地存储',
  'app.diagnostics' => '诊断',
  _ => component,
};

String _eventTitle(DiagnosticsViewerEvent event) {
  final name = event.eventName;
  if (name == 'performance.slow') return '操作耗时较长';
  if (name == 'app.error.unhandled') return '应用发生异常';
  final operation = name.startsWith('runtime.facade.')
      ? '数据源调用'
      : name.startsWith('app.bootstrap.')
      ? '应用启动'
      : name.startsWith('library.')
      ? '书架操作'
      : null;
  if (operation != null) {
    return '$operation${switch (event.outcome) {
      'error' => '失败',
      'timeout' => '超时',
      'success' => '完成',
      'cancelled' => '已取消',
      _ => '记录',
    }}';
  }
  return event.summary;
}

Color _severityColor(BuildContext context, String severity) {
  final tokens = AppThemeTokens.of(context);
  return switch (severity) {
    'fatal' || 'error' => Theme.of(context).colorScheme.error,
    'warn' => tokens.warning,
    'info' => tokens.success,
    _ => tokens.mutedText,
  };
}

String _formatTimestamp(int micros) {
  final value = DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true).toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  String three(int number) => number.toString().padLeft(3, '0');
  return '${two(value.hour)}:${two(value.minute)}:${two(value.second)}.'
      '${three(value.millisecond)}';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

String _viewerErrorCode(Object error) {
  if (error is DiagnosticsViewerException) return error.code;
  if (error is StateError) return 'invalid_state';
  if (error is TimeoutException) return 'timeout';
  return 'operation_failed';
}
