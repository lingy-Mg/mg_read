/// 漫画正文图片缓存逐书统计卡片。
///
/// 职责：
/// - 展示书架中每部漫画的正文图片缓存用量。
/// - 将无法归属到漫画的旧版缓存单独列出，保持总量可核对。
///
/// 注意：
/// - 只渲染应用层快照，不读取路径或触发缓存操作。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/cache/application/cover_cache_manager.dart';

final class MangaImageCacheBreakdownCard extends StatelessWidget {
  const MangaImageCacheBreakdownCard({required this.usage, super.key});

  final MangaImageCacheUsage usage;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final rows = <Widget>[
      for (final entry in usage.entries)
        _UsageRow(key: ValueKey<String>('manga-image-cache-entry-${entry.itemId}'), title: entry.title, bytes: entry.bytes),
      if (usage.unattributedBytes > 0)
        _UsageRow(key: const Key('manga-image-cache-unattributed'), title: '旧版缓存（无法归属）', bytes: usage.unattributedBytes),
    ];
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
            Text('各漫画缓存', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.compact),
            if (rows.isEmpty)
              Text('书架中暂无漫画。', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText))
            else
              for (int index = 0; index < rows.length; index++) ...<Widget>[
                if (index > 0) Divider(height: 1, color: tokens.divider),
                rows[index],
              ],
          ],
        ),
      ),
    );
  }
}

final class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.title, required this.bytes, super.key});

  final String title;
  final int bytes;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyLarge),
        ),
        const SizedBox(width: AppSpacing.regular),
        Text(_formatBytes(bytes), style: Theme.of(context).textTheme.labelLarge),
      ],
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}
