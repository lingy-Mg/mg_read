/// TV 数据源双栏视图：固定工具栏、独立滚动分类与列表、单一任务进度。
/// 业务状态和 IO 由管理页持有；搜索弹窗持有临时输入，确认后才应用查询。
/// 空库隐藏筛选；短屏保留可滚动内容，不把导入日志展开成焦点障碍。
part of 'plugin_runtime_status_page.dart';

class _TvDataSourceContent extends StatelessWidget {
  const _TvDataSourceContent({
    required this.sources,
    required this.visibleCount,
    required this.sourceBuilder,
    required this.filter,
    required this.onFilter,
    required this.query,
    required this.onQuery,
    required this.onReset,
    required this.addFocus,
    required this.categoryFocus,
    required this.categoryScroll,
    required this.onAdd,
    required this.importState,
    required this.removalProgress,
  });

  final List<DataSourceManagementRowData> sources;
  final int visibleCount;
  final IndexedWidgetBuilder sourceBuilder;
  final _DataSourceFilter filter;
  final ValueChanged<_DataSourceFilter> onFilter;
  final String query;
  final ValueChanged<String> onQuery;
  final VoidCallback onReset;
  final FocusNode addFocus;
  final FocusNode categoryFocus;
  final ScrollController categoryScroll;
  final VoidCallback? onAdd;
  final PluginSourceImportState importState;
  final PluginSourceRemovalProgress removalProgress;

  Future<void> _search(BuildContext context) async {
    final value = await showSourceManagementDialog<String>(
      context: context,
      builder: (_) => _TvSourceSearchDialog(query: query),
    );
    if (context.mounted && value != null) onQuery(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final busy = importState.isImporting || removalProgress.isRemoving;
    return LayoutBuilder(
      builder: (context, constraints) {
        final showHint = constraints.maxHeight >= 360;
        return Padding(
          key: const Key('data-source-management-content'),
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      sources.isEmpty ? '内容从这里开始' : '我的数据源 · ${sources.length}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  if (sources.isNotEmpty) ...[
                    TvFocusable(
                      key: const Key('tv-data-source-search'),
                      label: query.isEmpty ? '搜索数据源' : '修改搜索：$query',
                      selected: query.isNotEmpty,
                      onPressed: () => _search(context),
                      child: const Icon(Icons.search_rounded),
                    ),
                    const SizedBox(width: 12),
                  ],
                  TvFocusable(
                    key: const Key('data-source-add'),
                    focusNode: addFocus,
                    autofocus: sources.isEmpty,
                    onPressed: onAdd,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_rounded, color: onAdd == null ? tokens.mutedText : null),
                        const SizedBox(width: 8),
                        Text('添加数据源', style: theme.textTheme.titleMedium?.copyWith(color: onAdd == null ? tokens.mutedText : null)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (busy) ...[
                Container(
                  key: const Key('tv-data-source-progress'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: tokens.featureSurface, borderRadius: AppRadii.detailControl),
                  child: importState.isImporting
                      ? _DataSourceImportProgress(state: importState)
                      : _DataSourceRemovalProgress(progress: removalProgress),
                ),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: sources.isEmpty
                    ? _TvSourceEmpty(busy: busy)
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(width: (constraints.maxWidth * .23).clamp(156.0, 224.0), child: _categories(context)),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Text(
                                    '${_filterLabel(filter)} · $visibleCount 个${query.isEmpty ? '' : ' · “$query”'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                                  ),
                                ),
                                Expanded(
                                  child: visibleCount == 0
                                      ? _TvSourceEmpty(onReset: onReset)
                                      : ListView.builder(
                                          key: ValueKey('tv-source-list-${filter.name}-$query'),
                                          padding: const EdgeInsets.all(4),
                                          itemCount: visibleCount,
                                          itemBuilder: sourceBuilder,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
              if (showHint) ...[
                const SizedBox(height: 12),
                Text(
                  busy
                      ? '正在处理，请稍候'
                      : sources.isEmpty
                      ? '选择「添加数据源」，可从在线仓库安装'
                      : '方向键选择   ·   确认打开   ·   长按确认 / 菜单键管理',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _categories(BuildContext context) {
    const categories = [
      (_DataSourceFilter.all, Icons.apps_rounded),
      (_DataSourceFilter.video, Icons.movie_outlined),
      (_DataSourceFilter.audio, Icons.headphones_rounded),
      (_DataSourceFilter.novel, Icons.menu_book_rounded),
      (_DataSourceFilter.manga, Icons.auto_stories_outlined),
    ];
    return SingleChildScrollView(
      key: const Key('data-source-filters'),
      controller: categoryScroll,
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (value, icon) in categories)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TvFocusable(
                key: Key('data-source-filter-${value.name}'),
                focusNode: value == _DataSourceFilter.all ? categoryFocus : null,
                selected: filter == value,
                onPressed: () => onFilter(value),
                child: Row(
                  children: [
                    Icon(icon, size: 24),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_filterLabel(value), maxLines: 1)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TvSourceEmpty extends StatelessWidget {
  const _TvSourceEmpty({this.busy = false, this.onReset});
  final bool busy;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 220;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!compact) ...[
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(color: tokens.featureSurface, shape: BoxShape.circle),
                    child: Icon(
                      onReset == null ? Icons.video_library_outlined : Icons.search_off_rounded,
                      size: 56,
                      color: tokens.dataSourceAccent,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                Text(
                  onReset != null
                      ? '没有匹配的数据源'
                      : busy
                      ? '安装完成后，即可开始浏览'
                      : '添加一个数据源，开启大屏体验',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
                if (!compact && onReset == null) ...[
                  const SizedBox(height: 12),
                  Text('电影、剧集、听书与阅读，都在这里', style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText)),
                ],
                if (onReset != null) ...[
                  const SizedBox(height: 16),
                  TvFocusable(key: const Key('tv-source-reset'), onPressed: onReset, child: const Text('清除筛选')),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TvSourceSearchDialog extends StatefulWidget {
  const _TvSourceSearchDialog({required this.query});
  final String query;
  @override
  State<_TvSourceSearchDialog> createState() => _TvSourceSearchDialogState();
}

class _TvSourceSearchDialogState extends State<_TvSourceSearchDialog> {
  late final _controller = TextEditingController(text: widget.query);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply() => Navigator.of(context).pop(_controller.text.trim());

  @override
  Widget build(BuildContext context) => SourceManagementDialog(
    title: const Text('搜索数据源'),
    content: SizedBox(
      width: 480,
      child: TvTextInputNavigation(
        child: TextField(
          key: const Key('data-source-search'),
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _apply(),
          decoration: const InputDecoration(hintText: '输入名称或用途', prefixIcon: Icon(Icons.search_rounded)),
        ),
      ),
    ),
    actions: [
      TvFocusable(key: const Key('tv-source-search-cancel'), onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
      TvFocusable(key: const Key('tv-source-search-clear'), onPressed: () => Navigator.of(context).pop(''), child: const Text('清除')),
      TvFocusable(key: const Key('tv-source-search-apply'), onPressed: _apply, child: const Text('搜索')),
    ],
  );
}
