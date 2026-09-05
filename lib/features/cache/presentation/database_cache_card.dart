/// 数据库缓存卡片。
///
/// 展示自动扫描结果并提供显式清理、压缩和失败重试；不发起路径或 SQL 操作。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/cache/application/database_cache_manager.dart';

final class DatabaseCacheSection extends StatelessWidget {
  const DatabaseCacheSection({required this.state, required this.onRetry, required this.onClear, required this.onCompact, super.key});

  final AsyncValue<DatabaseCacheManagementState> state;
  final VoidCallback onRetry;
  final VoidCallback onClear;
  final VoidCallback onCompact;

  @override
  Widget build(BuildContext context) => state.when(
    loading: () => const _DatabaseCard(
      description: '正在扫描可清理的数据库缓存…',
      trailing: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
    ),
    error: (Object _, StackTrace _) => _DatabaseCard(
      description: '数据库缓存信息暂不可用。',
      actions: <Widget>[
        TextButton.icon(
          key: const Key('database-cache-retry'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      ],
    ),
    data: (value) {
      final usage = value.usage;
      return Column(
        children: <Widget>[
          _DatabaseCard(
            description: usage.isEmpty ? '未发现可清理的无引用正文对象。' : '预计可清理 ${_formatBytes(usage.estimatedReclaimableBytes)}；清理后空间会先供数据库复用。',
            trailing: value.isRefreshing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
            details: <Widget>[
              _Metric(label: '无引用正文对象', value: '${usage.orphanContentObjects} 个'),
              _Metric(label: '无引用正文大小', value: _formatBytes(usage.reclaimableContentBytes)),
              _Metric(label: '可压缩数据库空间', value: _formatBytes(usage.compactableDatabaseBytes)),
            ],
            actions: <Widget>[
              FilledButton.tonalIcon(
                key: const Key('database-cache-clear'),
                onPressed: value.isBusy || usage.isEmpty ? null : onClear,
                icon: value.isClearing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cleaning_services_outlined),
                label: Text(value.isClearing ? '正在清理' : '全部清理'),
              ),
              OutlinedButton.icon(
                key: const Key('database-cache-compact'),
                onPressed: value.isBusy || (usage.compactableDatabaseBytes == 0 && !value.hasCompletedCleanup) ? null : onCompact,
                icon: value.isCompacting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.compress_rounded),
                label: Text(value.isCompacting ? '正在压缩' : '压缩数据库'),
              ),
              IconButton(
                key: const Key('database-cache-refresh'),
                tooltip: '重新扫描',
                onPressed: value.isBusy ? null : onRetry,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          if (value.feedback != null) ...<Widget>[
            const SizedBox(height: AppSpacing.compact),
            _Feedback(text: _feedbackText(value.feedback!, value.releasedBytes)),
          ],
        ],
      );
    },
  );
}

final class _DatabaseCard extends StatelessWidget {
  const _DatabaseCard({required this.description, this.trailing, this.details = const <Widget>[], this.actions = const <Widget>[]});

  final String description;
  final Widget? trailing;
  final List<Widget> details;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.profileList,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text('数据库缓存', style: Theme.of(context).textTheme.titleLarge)),
                ...switch (trailing) {
                  final Widget widget => <Widget>[widget],
                  null => const <Widget>[],
                },
              ],
            ),
            const SizedBox(height: AppSpacing.compact),
            Text(description, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
            if (details.isNotEmpty) ...<Widget>[const SizedBox(height: AppSpacing.regular), ...details],
            if (actions.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              Wrap(spacing: AppSpacing.compact, runSpacing: AppSpacing.compact, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}

final class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.compact),
    child: Row(
      children: <Widget>[
        Expanded(child: Text(label)),
        Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      ],
    ),
  );
}

final class _Feedback extends StatelessWidget {
  const _Feedback({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          borderRadius: AppRadii.control,
          border: Border.all(color: tokens.divider),
        ),
        child: Padding(padding: const EdgeInsets.all(AppSpacing.regular), child: Text(text)),
      ),
    );
  }
}

String _feedbackText(DatabaseCacheFeedback feedback, int bytes) => switch (feedback) {
  DatabaseCacheFeedback.cleared => '数据库缓存已清理，释放了约 ${_formatBytes(bytes)} 的逻辑空间。',
  DatabaseCacheFeedback.alreadyEmpty => '数据库缓存已经为空。',
  DatabaseCacheFeedback.partiallyCleared => '部分数据库缓存已清理，其余内容可重新扫描后重试。',
  DatabaseCacheFeedback.compacted => '数据库压缩完成，磁盘文件减少了 ${_formatBytes(bytes)}。',
  DatabaseCacheFeedback.alreadyCompact => '数据库当前无需进一步压缩。',
  DatabaseCacheFeedback.scanFailed => '重新扫描失败，仍保留上一次统计结果。',
  DatabaseCacheFeedback.clearFailed => '数据库缓存清理失败，请重新扫描后重试。',
  DatabaseCacheFeedback.compactFailed => '数据库压缩失败，现有数据不受影响。',
};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
