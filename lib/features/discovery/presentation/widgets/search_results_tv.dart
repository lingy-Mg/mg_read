/// TV 搜索结果卡片和状态。排序沿用父级的稳定序列，卡片以聚合身份维持焦点。
/// 错误、取消、分页与来源切换都使用既有回调；来源数量不替代真实结果数据。
part of 'search_page_sections.dart';

class _TvSearchResults extends StatelessWidget {
  const _TvSearchResults({required this.owner, required this.items});
  final SearchResultsSection owner;
  final List<AggregatedSearchItem> items;

  @override
  Widget build(BuildContext context) {
    final result = owner.result!;
    final searching = owner.status == SearchPageStatus.searching;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('搜索结果 · ${items.length}', style: Theme.of(context).textTheme.titleLarge),
            TvFocusable(
              key: const Key('search-result-sort'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => TvDiscoveryDialog(
                  title: '结果排序',
                  actions: [TvFocusable(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消'))],
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final order in SearchResultSortOrder.values)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TvFocusable(
                            autofocus: order == owner.sortOrder,
                            selected: order == owner.sortOrder,
                            onPressed: () {
                              Navigator.pop(dialogContext);
                              owner.onSortOrderChanged(order);
                            },
                            child: Text(order.label),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              child: Text(owner.sortOrder.label),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '已完成 ${result.completedSourceCount}/${result.totalSourceCount} 个来源${searching
              ? ' · 搜索中'
              : result.isComplete
              ? ''
              : ' · 已取消'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (owner.error != null || result.failedSources.isNotEmpty) ...[
          const SizedBox(height: 12),
          TvFocusable(
            key: const Key('tv-search-retry'),
            onPressed: searching ? null : owner.onRetry,
            child: Text(
              result.failedSources.isNotEmpty ? '${result.failedSources.length} 个来源失败 · 重试' : '${_sourceErrorTitle(owner.error!)} · 重试',
            ),
          ),
        ],
        const SizedBox(height: 20),
        if (items.isEmpty)
          searching
              ? _SearchInProgressState(query: owner.query)
              : _SearchResultMessage(
                  icon: result.isComplete ? Icons.search_off_rounded : Icons.cancel_outlined,
                  title: result.isComplete ? '没有搜索结果' : '搜索已取消',
                  message: '更换关键词或数据源后再试。',
                )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / (230 * MediaQuery.textScalerOf(context).scale(1))).floor().clamp(1, 5);
              final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
              return Wrap(
                key: const Key('source-search-results'),
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (final item in items)
                    SizedBox(
                      key: ValueKey(item.key),
                      width: width,
                      child: _TvSearchCard(item: item, inShelf: owner.isInBookshelf(item), onPressed: () => owner.onContentPressed(item)),
                    ),
                ],
              );
            },
          ),
        if (result.hasMore) ...[
          const SizedBox(height: 20),
          TvFocusable(
            key: const Key('search-load-more'),
            onPressed: searching ? null : owner.onLoadMore,
            child: Text(searching ? '正在加载更多…' : '加载更多来源结果'),
          ),
        ],
      ],
    );
  }
}

class _TvSearchCard extends StatelessWidget {
  const _TvSearchCard({required this.item, required this.inShelf, required this.onPressed});
  final AggregatedSearchItem item;
  final bool inShelf;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final hit = item.primary;
    final content = hit.content;
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText);
    return BookCoverSourceScope(
      pluginId: hit.pluginId,
      pluginVersion: hit.source.pluginVersion,
      child: TvFocusable(
        key: ValueKey('search-result-${content.id}'),
        onPressed: onPressed,
        padding: const EdgeInsets.all(10),
        child: LayoutBuilder(
          builder: (context, constraints) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DiscoveryBookCover(
                title: content.title,
                variant: _coverVariantFor(content, 0),
                contentKind: content.contentKind,
                remoteContentId: content.id,
                coverUrl: content.coverUrl,
                coverBytes: content.coverBytes,
                presentation: discoveryCoverPresentation(content.coverOrientation),
                width: constraints.maxWidth,
                height: constraints.maxWidth * 9 / 16,
              ),
              const SizedBox(height: 12),
              Text(content.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                [hit.source.displayName, if (item.sourceCount > 1) '${item.sourceCount} 个来源', if (inShelf) '已收藏'].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
