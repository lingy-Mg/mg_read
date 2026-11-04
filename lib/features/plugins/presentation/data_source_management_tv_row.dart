/// TV source cards expose each command as a single, labelled remote target.
/// This view owns no Runtime state; pending mutations disable its commands.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'data_source_management_row.dart';

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

  @override
  Widget build(BuildContext context) {
    final available = source.enabled && source.canOpen && !pending;
    return Padding(
      key: ValueKey('data-source-${source.id}'),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SourceIcon(sourceId: source.id, displayName: source.name, iconUrl: source.iconUrl, size: 56, borderRadius: 12),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(source.name, style: Theme.of(context).textTheme.headlineSmall),
                    Text(
                      '${source.kindLabel} · ${pending
                          ? '处理中'
                          : source.enabled
                          ? '已启用'
                          : '已停用'}${source.isDevelopment ? ' · 开发数据源' : ''}',
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(source.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (onDiscover != null) _action('discover', '浏览内容', available ? onDiscover : null),
              if (onSearch != null) _action('search', '搜索', available ? onSearch : null),
              _action('detail', '详情与管理', pending ? null : onDetail),
              if (onOpenSourceUrl != null) _action('open-url', '打开网站', onOpenSourceUrl),
              if (!source.isDevelopment) _action('toggle', source.enabled ? '停用' : '启用', pending ? null : onToggle),
            ],
          ),
        ],
      ),
    );
  }

  Widget _action(String id, String label, VoidCallback? onPressed) =>
      TvFocusable(key: ValueKey('data-source-$id-${source.id}'), onPressed: onPressed, child: Text(label));
}
