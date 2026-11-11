/// 数据源管理的无状态列表控件、概览与任务进度。
/// 仅接收展示数据和显式回调，不执行 IO 或持有业务状态。
part of 'plugin_runtime_status_page.dart';

class _DataSourceImportProgress extends StatelessWidget {
  const _DataSourceImportProgress({required this.state});

  final PluginSourceImportState state;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final double? fraction = state.fraction?.clamp(0, 1).toDouble();
    final String percent = fraction == null ? '处理中' : '${(fraction * 100).round()}%';
    return Semantics(
      liveRegion: true,
      label: '${state.message}，$percent',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  state.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.dataSourceAccent, fontWeight: FontWeight.w600),
                ),
              ),
              Text(percent, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            ],
          ),
          const SizedBox(height: AppSpacing.unit),
          LinearProgressIndicator(value: fraction, minHeight: 4, backgroundColor: tokens.mutedSurface, color: tokens.dataSourceAccent),
        ],
      ),
    );
  }
}

class _DataSourceImportLog extends StatelessWidget {
  const _DataSourceImportLog({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Container(
      key: const Key('data-source-import-log'),
      constraints: const BoxConstraints(maxHeight: 128),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact, vertical: AppSpacing.unit),
      decoration: BoxDecoration(color: tokens.mutedSurface, borderRadius: AppRadii.detailControl),
      child: ListView(
        shrinkWrap: true,
        children: logs
            .map(
              (String log) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('· $log', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _DataSourceOverviewCard extends StatelessWidget {
  const _DataSourceOverviewCard({
    required this.sources,
    required this.importState,
    required this.onAddPressed,
    required this.isClearingAll,
    required this.removalProgress,
    required this.addFocusNode,
  });

  final List<DataSourceManagementRowData> sources;
  final PluginSourceImportState importState;
  final VoidCallback? onAddPressed;
  final bool isClearingAll;
  final PluginSourceRemovalProgress removalProgress;
  final FocusNode addFocusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final sourceCount = sources.length;
    final enabledCount = sources.where((source) => source.enabled).length;
    if (sourceCount > 0 && !importState.isImporting && !isClearingAll) {
      return Row(
        key: const Key('data-source-management-card'),
        children: [
          Expanded(
            child: Text(
              '$sourceCount 个数据源 · $enabledCount 已启用',
              key: const Key('data-source-enabled-count'),
              style: theme.textTheme.titleMedium,
            ),
          ),
          _AddDataSourceButton(isImporting: false, onPressed: onAddPressed, focusNode: addFocusNode),
        ],
      );
    }
    return Container(
      key: const Key('data-source-management-card'),
      padding: const EdgeInsets.all(AppSpacing.comfortable),
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(sourceCount == 0 ? '还没有数据源' : '正在处理数据源', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.compact),
          Text(
            sourceCount == 0 ? '从在线仓库选择，或导入已有安装包。' : '安装、更新和卸载完成后会自动刷新列表。',
            key: const Key('data-source-enabled-count'),
            style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
          ),
          const SizedBox(height: AppSpacing.unit),
          _AddDataSourceButton(isImporting: importState.isImporting, onPressed: onAddPressed, focusNode: addFocusNode),
          if (isClearingAll) ...[const SizedBox(height: AppSpacing.regular), _DataSourceRemovalProgress(progress: removalProgress)],
          if (importState.isImporting) ...[
            const SizedBox(height: AppSpacing.regular),
            _DataSourceImportProgress(state: importState),
            if (importState.logs.isNotEmpty)
              Material(
                color: Colors.transparent,
                child: ExpansionTile(
                  title: const Text('查看处理记录'),
                  tilePadding: EdgeInsets.zero,
                  children: [_DataSourceImportLog(logs: importState.logs)],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _DataSourceRemovalProgress extends StatelessWidget {
  const _DataSourceRemovalProgress({required this.progress});

  final PluginSourceRemovalProgress progress;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final fraction = progress.fraction;
    final count = progress.totalItems == 0 ? '处理中' : '${progress.completedItems}/${progress.totalItems}';
    return Semantics(
      liveRegion: true,
      label: '${progress.message}，$count',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(progress.message, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
              ),
              Text(count, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            ],
          ),
          const SizedBox(height: AppSpacing.unit),
          LinearProgressIndicator(value: fraction, minHeight: 4, backgroundColor: tokens.mutedSurface, color: tokens.notification),
        ],
      ),
    );
  }
}

class _DataSourceSearchField extends StatelessWidget {
  const _DataSourceSearchField({required this.controller, required this.query, required this.onChanged, required this.onClear});

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return TvTextInputNavigation(
      child: TextField(
        key: const Key('data-source-search'),
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: '搜索名称、标识或网址',
          prefixIcon: const Icon(Icons.search_rounded, size: 21),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  key: const Key('data-source-search-clear'),
                  tooltip: '清除搜索',
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded),
                ),
          filled: true,
          fillColor: tokens.surface,
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.comfortable),
          enabledBorder: OutlineInputBorder(
            borderRadius: AppRadii.detailControl,
            borderSide: BorderSide(color: tokens.divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: AppRadii.detailControl,
            borderSide: BorderSide(color: tokens.dataSourceAccent, width: 1.4),
          ),
        ),
      ),
    );
  }
}

class _DataSourceFilterBar extends StatelessWidget {
  const _DataSourceFilterBar({required this.selected, required this.onSelected});

  final _DataSourceFilter selected;
  final ValueChanged<_DataSourceFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Wrap(
      key: const Key('data-source-filters'),
      spacing: AppSpacing.compact,
      children: <Widget>[
        for (final _DataSourceFilter filter in _DataSourceFilter.values)
          if (TvModeScope.isEnabled(context))
            TvFocusable(
              key: Key('data-source-filter-${filter.name}'),
              selected: selected == filter,
              onPressed: () => onSelected(filter),
              child: Text(_filterLabel(filter)),
            )
          else
            ChoiceChip(
              key: Key('data-source-filter-${filter.name}'),
              label: Text(_filterLabel(filter)),
              selected: selected == filter,
              showCheckmark: false,
              side: BorderSide(color: selected == filter ? tokens.dataSourceAccent.withValues(alpha: 0.26) : tokens.divider),
              selectedColor: tokens.accentSoft,
              backgroundColor: tokens.surface,
              labelStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: selected == filter ? tokens.dataSourceAccent : tokens.mutedText,
                fontWeight: selected == filter ? FontWeight.w600 : FontWeight.w400,
              ),
              onSelected: (_) => onSelected(filter),
            ),
      ],
    );
  }
}

class _DataSourceListHeader extends StatelessWidget {
  const _DataSourceListHeader({required this.visibleCount, required this.totalCount, required this.compact, required this.onToggle});

  final int visibleCount;
  final int totalCount;
  final bool compact;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Row(
      children: <Widget>[
        Expanded(child: Text('我的数据源', style: theme.textTheme.titleMedium)),
        if (!TvModeScope.isEnabled(context))
          IconButton(
            key: const Key('data-source-density'),
            tooltip: compact ? '切换详细视图' : '切换紧凑视图',
            onPressed: onToggle,
            icon: Icon(compact ? Icons.view_agenda_outlined : Icons.view_list_outlined),
          ),
        Text(
          visibleCount == totalCount ? '共 $totalCount 个' : '$visibleCount / $totalCount',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
        ),
      ],
    );
  }
}

class _DataSourceEmptyState extends StatelessWidget {
  const _DataSourceEmptyState({required this.message, this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('data-source-management-empty'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.section),
        child: Column(
          children: <Widget>[
            Icon(Icons.manage_search_rounded, size: 34, color: tokens.mutedText),
            const SizedBox(height: AppSpacing.compact),
            Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
            if (onAction != null && actionLabel != null) ...<Widget>[
              const SizedBox(height: AppSpacing.compact),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddDataSourceButton extends StatelessWidget {
  const _AddDataSourceButton({required this.isImporting, required this.focusNode, this.onPressed});

  final bool isImporting;
  final VoidCallback? onPressed;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    if (TvModeScope.isEnabled(context)) {
      return TvFocusable(
        key: const Key('data-source-add'),
        focusNode: focusNode,
        onPressed: onPressed,
        child: Text(isImporting ? '正在导入…' : '添加数据源'),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.minimumTouchTarget),
      child: TextButton.icon(
        key: const Key('data-source-add'),
        onPressed: onPressed,
        icon: isImporting
            ? SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary),
              )
            : const Icon(Icons.add_rounded, size: 21),
        label: Text(isImporting ? '正在导入…' : '添加数据源'),
        style: TextButton.styleFrom(foregroundColor: tokens.dataSourceAccent, alignment: Alignment.centerLeft),
      ),
    );
  }
}

String _filterLabel(_DataSourceFilter value) => switch (value) {
  _DataSourceFilter.all => '全部',
  _DataSourceFilter.novel => '小说',
  _DataSourceFilter.manga => '漫画',
  _DataSourceFilter.audio => '音频',
  _DataSourceFilter.video => '视频',
};

class _DataSourceStatusBar extends StatelessWidget {
  const _DataSourceStatusBar({required this.sources, required this.selected, required this.onSelected});
  final List<DataSourceManagementRowData> sources;
  final _DataSourceStatusFilter selected;
  final ValueChanged<_DataSourceStatusFilter> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: AppSpacing.compact,
    children: [
      for (final value in _DataSourceStatusFilter.values)
        ChoiceChip(
          key: Key('data-source-status-${value.name}'),
          label: Text('${value.label} ${sources.where(value.matches).length}'),
          selected: value == selected,
          showCheckmark: false,
          onSelected: (_) => onSelected(value),
        ),
    ],
  );
}
