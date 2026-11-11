/// 数据源列表状态所有者：内容类型、运行状态、查询与视图密度。
/// Runtime 数据与写操作由应用层持有；刷新复用本状态，控件与 TV 焦点在 dispose 释放。
part of 'plugin_runtime_status_page.dart';

class _DataSourceContent extends ConsumerStatefulWidget {
  const _DataSourceContent({
    required this.sources,
    required this.onSourcePressed,
    required this.onOpenSourceUrl,
    this.onDiscoverSource,
    this.onSearchSource,
  });

  final List<DataSourceManagementRowData> sources;
  final ValueChanged<String> onSourcePressed;
  final ValueChanged<DataSourceManagementRowData> onOpenSourceUrl;
  final ValueChanged<String>? onDiscoverSource;
  final ValueChanged<String>? onSearchSource;

  @override
  ConsumerState<_DataSourceContent> createState() => _DataSourceContentState();
}

class _DataSourceContentState extends ConsumerState<_DataSourceContent> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _addFocus = FocusNode(debugLabel: 'Add data source');
  final FocusNode _tvCategoryFocus = FocusNode(debugLabel: 'All data sources');
  final ScrollController _tvCategoryScroll = ScrollController();
  bool _tvEntryFocused = false;
  _DataSourceFilter _filter = _DataSourceFilter.all;
  _DataSourceStatusFilter _statusFilter = _DataSourceStatusFilter.all;
  String _query = '';
  bool _compactSources = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_tvEntryFocused || !TvModeScope.isEnabled(context)) return;
    _tvEntryFocused = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      requestTvFocus(widget.sources.isEmpty ? _addFocus : _tvCategoryFocus);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _addFocus.dispose();
    _tvCategoryFocus.dispose();
    _tvCategoryScroll.dispose();
    super.dispose();
  }

  Future<void> _setSourceEnabled(DataSourceManagementRowData source, bool enabled) async {
    if (ref.read(pluginRuntimeSourceManagementBusyProvider) || source.isDevelopment) return;
    try {
      await ref.read(pluginRuntimeSourceActionProvider.notifier).setEnabled(pluginId: source.id, enabled: enabled);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已${enabled ? '启用' : '停用'}“${source.name}”。')));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源状态更新失败，请稍后重试。')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Set<String> pendingSourceIds = ref.watch(pluginRuntimeSourceActionProvider);
    final bool isClearingAll = pendingSourceIds.contains('__all_installed_sources__');
    final PluginSourceRemovalProgress removalProgress = ref.watch(pluginRuntimeSourceRemovalProgressProvider);
    final PluginSourceImportState importState = ref.watch(pluginRuntimeSourceImportProvider);
    final String normalizedQuery = _query.trim().toLowerCase();
    final List<DataSourceManagementRowData> visibleSources = widget.sources
        .where((DataSourceManagementRowData source) {
          final bool matchesFilter = switch (_filter) {
            _DataSourceFilter.all => true,
            _DataSourceFilter.novel => source.contentKinds.contains('novel'),
            _DataSourceFilter.manga => source.contentKinds.contains('manga'),
            _DataSourceFilter.audio => source.contentKinds.contains('audio'),
            _DataSourceFilter.video => source.contentKinds.contains('video'),
          };
          if (!matchesFilter || !_statusFilter.matches(source)) return false;
          if (normalizedQuery.isEmpty) return true;
          return '${source.name} ${source.id} ${source.description} ${source.kindLabel} ${source.sourceUrl ?? ''}'.toLowerCase().contains(
            normalizedQuery,
          );
        })
        .toList(growable: false);
    Widget sourceRow(BuildContext context, int index) {
      final source = visibleSources[index];
      return Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.regular),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: AppRadii.detailCard,
          border: Border.all(color: tokens.divider),
        ),
        child: DataSourceManagementRow(
          compact: _compactSources,
          source: source,
          isPending: importState.isImporting || pendingSourceIds.isNotEmpty,
          onPressed: () => widget.onSourcePressed(source.id),
          onDiscover: widget.onDiscoverSource == null ? null : () => widget.onDiscoverSource!(source.id),
          onSearch: widget.onSearchSource == null ? null : () => widget.onSearchSource!(source.id),
          onOpenSourceUrl: source.sourceUrl == null ? null : () => widget.onOpenSourceUrl(source),
          onChanged: (enabled) => _setSourceEnabled(source, enabled),
        ),
      );
    }

    if (TvModeScope.isEnabled(context)) {
      return _TvDataSourceContent(
        sources: widget.sources,
        visibleCount: visibleSources.length,
        sourceBuilder: sourceRow,
        filter: _filter,
        onFilter: (value) => setState(() => _filter = value),
        statusFilter: _statusFilter,
        onStatusFilter: (value) => setState(() => _statusFilter = value),
        query: _query,
        onQuery: (value) => setState(() {
          _query = value;
          _searchController.text = value;
        }),
        onReset: () {
          setState(() {
            _query = '';
            _searchController.clear();
            _filter = _DataSourceFilter.all;
            _statusFilter = _DataSourceStatusFilter.all;
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (_tvCategoryScroll.hasClients) _tvCategoryScroll.jumpTo(0);
            requestTvFocus(_tvCategoryFocus);
          });
        },
        addFocus: _addFocus,
        categoryFocus: _tvCategoryFocus,
        categoryScroll: _tvCategoryScroll,
        onAdd: importState.isImporting || pendingSourceIds.isNotEmpty ? null : _importDataSource,
        importState: importState,
        removalProgress: removalProgress,
      );
    }
    return ListView.builder(
      key: const Key('data-source-management-content'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.section,
      ),
      itemCount: visibleSources.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _DataSourceOverviewCard(
                addFocusNode: _addFocus,
                sources: widget.sources,
                importState: importState,
                onAddPressed: importState.isImporting || pendingSourceIds.isNotEmpty ? null : _importDataSource,
                isClearingAll: isClearingAll,
                removalProgress: removalProgress,
              ),
              const SizedBox(height: AppSpacing.comfortable),
              _DataSourceSearchField(
                controller: _searchController,
                query: _query,
                onChanged: (String value) => setState(() => _query = value),
                onClear: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
              const SizedBox(height: AppSpacing.regular),
              _DataSourceFilterBar(selected: _filter, onSelected: (_DataSourceFilter value) => setState(() => _filter = value)),
              const SizedBox(height: AppSpacing.regular),
              _DataSourceStatusBar(
                sources: widget.sources,
                selected: _statusFilter,
                onSelected: (value) => setState(() => _statusFilter = value),
              ),
              const SizedBox(height: AppSpacing.compact),
              _DataSourceListHeader(
                visibleCount: visibleSources.length,
                totalCount: widget.sources.length,
                compact: _compactSources,
                onToggle: () => setState(() => _compactSources = !_compactSources),
              ),
              const SizedBox(height: AppSpacing.regular),
              if (widget.sources.isEmpty)
                const _DataSourceEmptyState(message: '暂无已安装的数据源')
              else if (visibleSources.isEmpty)
                _DataSourceEmptyState(
                  message: '没有符合条件的数据源',
                  actionLabel: '清除筛选',
                  onAction: () {
                    _searchController.clear();
                    setState(() {
                      _query = '';
                      _filter = _DataSourceFilter.all;
                      _statusFilter = _DataSourceStatusFilter.all;
                    });
                  },
                ),
            ],
          );
        }
        if (index == visibleSources.length + 1) {
          return Text(
            '点击数据源查看详情；开关控制启停，停用会保留数据。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
          );
        }

        return sourceRow(context, index - 1);
      },
    );
  }
}

enum _DataSourceFilter { all, novel, manga, audio, video }

enum _DataSourceStatusFilter {
  all('全部状态'),
  enabled('已启用'),
  disabled('已停用'),
  attention('待处理'),
  development('开发');

  const _DataSourceStatusFilter(this.label);
  final String label;
  bool matches(DataSourceManagementRowData source) => switch (this) {
    all => true,
    enabled => source.enabled,
    disabled => !source.enabled,
    attention => source.needsAttention,
    development => source.isDevelopment,
  };
}
