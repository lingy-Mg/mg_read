/// TV 数据源紧凑卡片：确认打开内容，长按确认或菜单键展开管理操作。
/// 卡片只持有菜单的临时选择，Runtime 状态和 IO 仍归调用方；处理中禁止重复操作。
library;

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'data_source_management_row.dart';
import 'source_management_tv.dart';

class TvDataSourceManagementRow extends StatelessWidget {
  const TvDataSourceManagementRow({
    required this.source,
    required this.pending,
    required this.onDetail,
    required this.onToggle,
    this.onDiscover,
    this.onSearch,
    this.onOpenSourceUrl,
    super.key,
  });
  final DataSourceManagementRowData source;
  final bool pending;
  final VoidCallback onDetail;
  final VoidCallback onToggle;
  final VoidCallback? onDiscover;
  final VoidCallback? onSearch;
  final VoidCallback? onOpenSourceUrl;

  Future<void> _showActions(BuildContext context) async {
    final available = source.enabled && source.canOpen && !pending;
    final actions = <(String, String, VoidCallback?)>[
      if (onDiscover != null) ('discover', '浏览内容', available ? onDiscover : null),
      if (onSearch != null) ('search', '搜索内容', available ? onSearch : null),
      ('detail', '详情与管理', pending ? null : onDetail),
      if (onOpenSourceUrl != null) ('open-url', '打开网站', onOpenSourceUrl),
      if (!source.isDevelopment) ('toggle', source.enabled ? '停用数据源' : '启用数据源', pending ? null : onToggle),
    ];
    final action = await showSourceManagementDialog<VoidCallback>(
      context: context,
      builder: (dialogContext) => SourceManagementDialog(
        title: Text(source.name),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(source.description, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 16),
                for (final (id, label, callback) in actions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TvFocusable(
                      key: ValueKey('data-source-$id-${source.id}'),
                      onPressed: callback == null ? null : () => Navigator.of(dialogContext).pop(callback),
                      child: Text(label),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [TvFocusable(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('返回'))],
      ),
    );
    if (context.mounted) action?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final available = source.enabled && source.canOpen && !pending;
    final primary = available ? onDiscover ?? onSearch ?? onDetail : onDetail;
    final status = pending
        ? '处理中'
        : source.enabled
        ? source.kindLabel
        : '${source.kindLabel} · 已停用';
    return Padding(
      key: ValueKey('data-source-${source.id}'),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: TvFocusable(
              key: ValueKey('data-source-open-${source.id}'),
              label: '${source.name}，$status，确认${available && onDiscover != null ? '浏览内容' : '打开'}，菜单键管理',
              onPressed: pending ? null : primary,
              onMore: pending ? null : () => _showActions(context),
              child: Row(
                children: [
                  SourceIcon(sourceId: source.id, displayName: source.name, iconUrl: source.iconUrl, size: 48, borderRadius: 12),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(source.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge),
                        const SizedBox(height: 6),
                        Text(
                          '$status${source.isDevelopment ? ' · 开发数据源' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          TvFocusable(
            key: ValueKey('data-source-menu-${source.id}'),
            label: '管理${source.name}',
            onPressed: pending ? null : () => _showActions(context),
            child: Icon(Icons.more_horiz_rounded, color: tokens.mutedText),
          ),
        ],
      ),
    );
  }
}
