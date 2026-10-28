/// 搜索建议、状态与结果展示；来源和请求生命周期由页面控制器持有。
/// 搜索过程中保持已展示结果顺序，完成或用户改排序后再统一排序。
/// 历史关键词由本组件持有横向滚动控制器，保留滑动但不显示滚动条。
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/batch_search.dart';
import 'package:mg_read/features/discovery/application/search_page_state.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_content_list_item.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

/// The local interaction-only content above a source search result list.
class SearchSuggestionSections extends StatelessWidget {
  const SearchSuggestionSections({
    required this.history,
    required this.onHistorySelected,
    required this.onHistoryCleared,
    required this.onHotSearchSelected,
    required this.hotSearches,
    required this.isSearchStarted,
    required this.onHotSearchRefreshed,
    super.key,
  });

  final List<String> history;
  final ValueChanged<String> onHistorySelected;
  final VoidCallback onHistoryCleared;
  final ValueChanged<String> onHotSearchSelected;
  final List<PluginSearchSuggestion> hotSearches;
  final bool isSearchStarted;
  final VoidCallback onHotSearchRefreshed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SearchHistoryRow(history: history, onHistorySelected: onHistorySelected, onHistoryCleared: onHistoryCleared),
        if (hotSearches.isNotEmpty && !isSearchStarted) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          _SectionHeading(
            title: '热门搜索',
            trailing: TextButton.icon(
              key: const Key('search-hot-refresh'),
              onPressed: onHotSearchRefreshed,
              icon: const Icon(Icons.refresh_rounded, size: 20),
              label: const Text('换一换'),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final columnWidth = (constraints.maxWidth - AppSpacing.section) / 2;
              return Wrap(
                spacing: AppSpacing.section,
                runSpacing: AppSpacing.compact,
                children: List<Widget>.generate(
                  hotSearches.length,
                  (index) => SizedBox(
                    width: columnWidth,
                    child: _HotSearchItem(
                      rank: index + 1,
                      label: hotSearches[index].query,
                      metric: hotSearches[index].metric,
                      onPressed: () => onHotSearchSelected(hotSearches[index].query),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class _SearchHistoryRow extends StatefulWidget {
  const _SearchHistoryRow({required this.history, required this.onHistorySelected, required this.onHistoryCleared});

  final List<String> history;
  final ValueChanged<String> onHistorySelected;
  final VoidCallback onHistoryCleared;

  @override
  State<_SearchHistoryRow> createState() => _SearchHistoryRowState();
}

class _SearchHistoryRowState extends State<_SearchHistoryRow> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      height: AppSpacing.searchHistoryChipHeight,
      child: Row(
        children: <Widget>[
          Text('历史', style: textTheme.titleSmall),
          const SizedBox(width: AppSpacing.compact),
          Expanded(
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                key: const Key('search-history-scroll'),
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: AppSpacing.unit),
                child: Row(
                  children: widget.history.isEmpty
                      ? <Widget>[Text('暂无历史关键词', style: textTheme.bodySmall?.copyWith(color: tokens.mutedText))]
                      : widget.history
                            .map(
                              (value) => Padding(
                                padding: const EdgeInsets.only(right: AppSpacing.compact),
                                child: _SearchHistoryChip(label: value, onPressed: () => widget.onHistorySelected(value)),
                              ),
                            )
                            .toList(growable: false),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.unit),
          IconButton(
            key: const Key('search-history-clear'),
            tooltip: '清空搜索历史',
            onPressed: widget.history.isEmpty ? null : widget.onHistoryCleared,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(
              width: AppSpacing.searchHistoryChipHeight,
              height: AppSpacing.searchHistoryChipHeight,
            ),
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

class SearchResultsSection extends StatefulWidget {
  const SearchResultsSection({
    required this.result,
    required this.status,
    required this.query,
    required this.error,
    required this.sortOrder,
    required this.onSortOrderChanged,
    this.isInBookshelf = _neverInBookshelf,
    required this.onContentPressed,
    required this.onRetry,
    required this.onLoadMore,
    this.hasSources = true,
    this.onManageSources,
    super.key,
  });

  final AggregatedSearchResult? result;
  final SearchPageStatus status;
  final String query;
  final AppError? error;
  final SearchResultSortOrder sortOrder;
  final ValueChanged<SearchResultSortOrder> onSortOrderChanged;
  final bool Function(AggregatedSearchItem item) isInBookshelf;
  final ValueChanged<AggregatedSearchItem> onContentPressed;
  final VoidCallback onRetry;
  final VoidCallback onLoadMore;
  final bool hasSources;
  final VoidCallback? onManageSources;

  @override
  State<SearchResultsSection> createState() => _SearchResultsSectionState();
}

class _SearchResultsSectionState extends State<SearchResultsSection> {
  final List<String> _visibleKeys = <String>[];
  String? _resultQuery;
  SearchResultSortOrder? _order;

  @override
  Widget build(BuildContext context) {
    final SearchResultsSection(
      :result,
      :status,
      :query,
      :error,
      :sortOrder,
      :onSortOrderChanged,
      :isInBookshelf,
      :onContentPressed,
      :onRetry,
      :onLoadMore,
      :hasSources,
      :onManageSources,
    ) = widget;
    final isSearching = status == SearchPageStatus.searching;
    if (result == null) {
      return AnimatedSwitcher(
        duration: AppMotion.navigationSelection,
        switchInCurve: AppMotion.navigationCurve,
        switchOutCurve: AppMotion.navigationReverseCurve,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SizeTransition(alignment: Alignment.topCenter, sizeFactor: animation, child: child),
        ),
        child: isSearching
            ? _SearchInProgressState(query: query)
            : _SearchResultMessage(
                key: const Key('app-empty-search-page'),
                icon: status == SearchPageStatus.loadingSources
                    ? Icons.hourglass_top_rounded
                    : error == null
                    ? Icons.manage_search_rounded
                    : Icons.error_outline_rounded,
                title: status == SearchPageStatus.loadingSources
                    ? '正在准备搜索'
                    : error == null
                    ? (hasSources ? '输入关键词开始搜索' : '先添加一个数据源')
                    : _sourceErrorTitle(error),
                message: status == SearchPageStatus.loadingSources
                    ? '正在读取可用数据源。'
                    : error == null
                    ? (hasSources ? '输入书名、作者，或点选上方关键词。' : '添加并启用数据源后，即可搜索喜欢的内容。')
                    : '稳定错误码：${error.code.wireValue}',
                loading: status == SearchPageStatus.loadingSources,
                onRetry: error == null ? null : onRetry,
                onManageSources: !hasSources && error == null ? onManageSources : null,
              ),
      );
    }
    final searchResult = result;
    final ordered = searchResult.sortedItems(sortOrder);
    if (_resultQuery != searchResult.query || _order != sortOrder || !isSearching) {
      _visibleKeys.clear();
    }
    _resultQuery = searchResult.query;
    _order = sortOrder;
    final byKey = {for (final item in ordered) item.key: item};
    _visibleKeys.removeWhere((key) => !byKey.containsKey(key));
    final known = _visibleKeys.toSet();
    _visibleKeys.addAll(ordered.where((item) => known.add(item.key)).map((item) => item.key));
    final sortedItems = _visibleKeys.map((key) => byKey[key]!).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Divider(),
        const SizedBox(height: AppSpacing.comfortable),
        _ResultHeader(result: searchResult, sortOrder: sortOrder, onSortOrderChanged: onSortOrderChanged),
        AnimatedSize(
          duration: AppMotion.navigationSelection,
          curve: AppMotion.navigationCurve,
          child: isSearching && searchResult.items.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.compact),
                  child: Text('搜索中 · 新结果追加在下方', style: Theme.of(context).textTheme.bodySmall),
                )
              : const SizedBox.shrink(),
        ),
        if (error != null) ...<Widget>[const SizedBox(height: AppSpacing.compact), _InlineSearchFailure(error: error, onRetry: onRetry)],
        if (searchResult.failedSources.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          _PartialSearchFailure(result: searchResult, onRetry: onRetry),
        ],
        const SizedBox(height: AppSpacing.compact),
        if (searchResult.items.isEmpty && isSearching && !searchResult.isComplete)
          _SearchInProgressState(query: query)
        else if (searchResult.items.isEmpty && !searchResult.isComplete)
          const _SearchResultMessage(
            key: Key('search-cancelled'),
            icon: Icons.cancel_outlined,
            title: '搜索已取消',
            message: '已停止搜索。再次点击“搜索”即可重新开始。',
          )
        else if (searchResult.items.isEmpty)
          const _SearchResultMessage(
            key: Key('search-empty-result'),
            icon: Icons.search_off_rounded,
            title: '没有搜索结果',
            message: '当前数据源没有返回匹配内容。',
          )
        else
          Column(
            key: const Key('source-search-results'),
            children: <Widget>[
              for (var index = 0; index < sortedItems.length; index++) ...<Widget>[
                SearchResultTile(
                  key: ValueKey(sortedItems[index].key),
                  item: sortedItems[index],
                  variant: _coverVariantFor(sortedItems[index].content, index),
                  isInBookshelf: isInBookshelf(sortedItems[index]),
                  onPressed: () => onContentPressed(sortedItems[index]),
                ),
              ],
            ],
          ),
        if (searchResult.hasMore) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          OutlinedButton.icon(
            key: const Key('search-load-more'),
            onPressed: isSearching ? null : onLoadMore,
            icon: const Icon(Icons.expand_more_rounded),
            label: Text(isSearching ? '正在加载更多…' : '加载更多来源结果'),
          ),
        ],
      ],
    );
  }
}

class _SearchInProgressState extends StatelessWidget {
  const _SearchInProgressState({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      key: const Key('source-search-progress'),
      label: '正在搜索“$query”',
      liveRegion: true,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.section),
          child: Center(
            child: Column(
              children: <Widget>[
                const SizedBox(width: AppSpacing.section, height: AppSpacing.section, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(height: AppSpacing.regular),
                Text('正在搜索“$query”', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.unit),
                Text('搜索结果将自动显示', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

DiscoveryCoverVariant _coverVariantFor(PluginContentSummary content, int index) => switch (content.id) {
  'preview-1' || 'preview-2' || 'preview-4' => DiscoveryCoverVariant.gothic,
  'preview-3' => DiscoveryCoverVariant.abyss,
  _ => DiscoveryCoverVariant.values[index % DiscoveryCoverVariant.values.length],
};

/// A compact, source-neutral search result. Runtime data populates it later.
class SearchResultTile extends StatelessWidget {
  const SearchResultTile({required this.item, required this.variant, required this.onPressed, this.isInBookshelf = false, super.key});
  final AggregatedSearchItem item;
  final DiscoveryCoverVariant variant;
  final VoidCallback onPressed;
  final bool isInBookshelf;

  @override
  Widget build(BuildContext context) {
    final primary = item.primary;
    return BookCoverSourceScope(
      pluginId: primary.source.id,
      pluginVersion: primary.source.pluginVersion,
      child: Stack(
        children: <Widget>[
          DiscoveryContentListItem(
            item: PluginDiscoveryContentItem(
              content: primary.content,
              rank: null,
              metric: _searchMetric(primary.content),
              recommendation: null,
            ),
            variant: variant,
            onPressed: onPressed,
            isInBookshelf: isInBookshelf,
            keyPrefix: 'search-result',
          ),
          if (item.sourceCount > 1)
            Positioned(
              right: 8,
              top: 8,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface.withValues(alpha: .92),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text('${item.sourceCount} 个来源', style: Theme.of(context).textTheme.labelSmall),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

bool _neverInBookshelf(AggregatedSearchItem _) => false;

PluginDiscoveryMetric? _searchMetric(PluginContentSummary content) {
  for (final attribute in content.attributes) {
    if (attribute.key == 'searchHeat' || attribute.key == 'heat') {
      return PluginDiscoveryMetric(label: attribute.label.trim().isEmpty ? '热度' : attribute.label, value: attribute.value);
    }
  }
  return null;
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
      ?trailing,
    ],
  );
}

class _SearchHistoryChip extends StatelessWidget {
  const _SearchHistoryChip({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Material(
      color: tokens.mutedSurface,
      borderRadius: AppRadii.control,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadii.control,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSpacing.searchHistoryChipHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.unit),
            child: Align(
              widthFactor: 1,
              alignment: Alignment.center,
              child: Text(label, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
        ),
      ),
    );
  }
}

class _HotSearchItem extends StatelessWidget {
  const _HotSearchItem({required this.rank, required this.label, required this.metric, required this.onPressed});
  final int rank;
  final String label;
  final String? metric;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final isTopRank = rank <= 3;
    return InkWell(
      key: ValueKey<String>('search-hot-$rank'),
      onTap: onPressed,
      borderRadius: AppRadii.control,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.unit),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: AppSpacing.section,
              child: Text(
                '$rank',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(color: isTopRank ? tokens.accent : tokens.mutedText),
              ),
            ),
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (metric != null) ...<Widget>[
              const SizedBox(width: AppSpacing.compact),
              Text(metric!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            ],
            if (isTopRank) Icon(Icons.local_fire_department_rounded, size: 17, color: tokens.notification, semanticLabel: '热门'),
          ],
        ),
      ),
    );
  }
}

class _ResultHeader extends StatelessWidget {
  const _ResultHeader({required this.result, required this.sortOrder, required this.onSortOrderChanged});
  final AggregatedSearchResult result;
  final SearchResultSortOrder sortOrder;
  final ValueChanged<SearchResultSortOrder> onSortOrderChanged;
  @override
  Widget build(BuildContext context) {
    final count = result.items.length;
    final tokens = AppThemeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('搜索结果', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            PopupMenuButton<SearchResultSortOrder>(
              key: const Key('search-result-sort'),
              tooltip: '选择搜索结果排序',
              onSelected: onSortOrderChanged,
              itemBuilder: (context) => <PopupMenuEntry<SearchResultSortOrder>>[
                for (final order in SearchResultSortOrder.values)
                  PopupMenuItem<SearchResultSortOrder>(
                    value: order,
                    child: Row(
                      children: <Widget>[
                        SizedBox(width: 24, child: order == sortOrder ? const Icon(Icons.check_rounded, size: 18) : null),
                        Text(order.label),
                      ],
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.unit, vertical: AppSpacing.unit),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(sortOrder.label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
                    Icon(Icons.arrow_drop_down_rounded, color: tokens.mutedText),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.unit),
        Wrap(
          spacing: AppSpacing.compact,
          runSpacing: AppSpacing.unit,
          children: <Widget>[
            Text('（已聚合 $count 条）', style: Theme.of(context).textTheme.bodyMedium),
            Text(
              '已完成 ${result.completedSourceCount}/${result.totalSourceCount} 个来源',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
            ),
          ],
        ),
      ],
    );
  }
}

class _PartialSearchFailure extends StatelessWidget {
  const _PartialSearchFailure({required this.result, required this.onRetry});

  final AggregatedSearchResult result;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Material(
    color: AppThemeTokens.of(context).mutedSurface,
    borderRadius: AppRadii.control,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.compact),
      child: Row(
        children: <Widget>[
          Expanded(child: Text('${result.failedSources.length} 个数据源搜索失败，已展示其他来源结果。', maxLines: 2, overflow: TextOverflow.ellipsis)),
          TextButton(onPressed: onRetry, child: const Text('重试失败来源')),
        ],
      ),
    ),
  );
}

class _InlineSearchFailure extends StatelessWidget {
  const _InlineSearchFailure({required this.error, required this.onRetry});
  final AppError error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    borderRadius: AppRadii.control,
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.regular),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(_sourceErrorTitle(error))),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

class _SearchResultMessage extends StatelessWidget {
  const _SearchResultMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.loading = false,
    this.onRetry,
    this.onManageSources,
    super.key,
  });
  final IconData icon;
  final String title;
  final String message;
  final bool loading;
  final VoidCallback? onRetry;
  final VoidCallback? onManageSources;
  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.section),
      child: Center(
        child: Column(
          children: <Widget>[
            if (loading)
              const SizedBox(width: AppSpacing.section, height: AppSpacing.section, child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(icon, size: AppSpacing.section, color: tokens.mutedText),
            const SizedBox(height: AppSpacing.regular),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.unit),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
            ),
            if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('重试')),
            if (onManageSources != null) TextButton(onPressed: onManageSources, child: const Text('添加数据源')),
          ],
        ),
      ),
    );
  }
}

String _sourceErrorTitle(AppError error) => switch (error.category) {
  AppErrorCategory.retryableTemporary => '暂时无法搜索',
  _ => '无法安全完成搜索',
};
