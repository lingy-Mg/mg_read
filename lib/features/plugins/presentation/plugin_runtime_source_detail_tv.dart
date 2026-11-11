/// TV 详情布局：左侧品牌与操作，右侧分块展示简介、元数据与占用。
/// 不持有 Runtime 状态；字段可确认查看完整内容，两个区域独立滚动。
part of 'plugin_runtime_source_detail_page.dart';

class _TvSourceDetail extends StatelessWidget {
  const _TvSourceDetail({required this.source, required this.dataUsage, required this.archiveUsage, required this.actions});
  final PluginRuntimePlugin source;
  final AsyncValue<PluginInstallationSize>? dataUsage;
  final AsyncValue<PluginInstallationSize>? archiveUsage;
  final Widget actions;

  @override
  Widget build(BuildContext context) => TvSourceWorkspace(
    key: const Key('data-source-detail-content'),
    sidebar: ListView(
      padding: const EdgeInsets.all(4),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SourceIcon(
                key: const Key('data-source-detail-icon'),
                sourceId: source.id,
                displayName: source.displayName,
                iconUrl: source.iconUrl,
                size: 64,
                borderRadius: 16,
              ),
              const SizedBox(height: 16),
              Text(source.displayName, key: const Key('data-source-detail-name'), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                source.canDiscoverAndSearch ? _statusLabel(source) : source.sourceStateLabel,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: AppThemeTokens.of(context).dataSourceAccent),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        actions,
      ],
    ),
    child: ListView(
      padding: const EdgeInsets.all(4),
      children: [
        TvSourcePanel(
          key: const Key('data-source-detail-card'),
          title: '数据源简介',
          icon: Icons.info_outline,
          child: SourceManagementInfo(
            child: Text(
              SourceBranding.description(sourceId: source.id, displayName: source.displayName, value: source.description),
              key: const Key('data-source-detail-description'),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _DetailMetadataGrid(
          fields: [
            _DetailFieldData(label: '类型', value: pluginContentKindsLabel(source.contentKinds)),
            _DetailFieldData(label: '来源方式', value: source.status == 'development' ? '开发数据源 · 即时生效' : '已安装数据源'),
            if (source.r18) const _DetailFieldData(label: '分级', value: 'R18'),
            _DetailFieldData(label: '版本', value: source.activeVersion ?? '等待激活', wide: true, expandable: true),
            if (source.pendingVersion != null) _DetailFieldData(label: '待生效版本', value: '${source.pendingVersion}（下次启动生效）', wide: true),
            _DetailFieldData(label: '来源网址', value: source.sourceUrl ?? '缺少', wide: true),
            if (!source.canDiscoverAndSearch)
              _DetailFieldData(label: '不可用说明', value: '${source.sourceStateReason ?? '发现和搜索不可用。'} 已缓存内容仍可查看。', wide: true),
            _DetailFieldData(label: '标识', value: source.id, wide: true),
          ],
        ),
        if (dataUsage != null && archiveUsage != null) ...[
          const SizedBox(height: 16),
          SourceManagementInfo(
            child: _InstallationSizeCard(archiveUsage: archiveUsage!, dataUsage: dataUsage!),
          ),
        ],
      ],
    ),
  );
}
