import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/search_page_state.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_content_list_item.dart';

/// The local interaction-only content above a source search result list.
class SearchSuggestionSections extends StatelessWidget {
  const SearchSuggestionSections({
    required this.history,
    required this.onHistorySelected,
    required this.onHistoryCleared,
    required this.onHotSearchSelected,
    required this.hotSearches,
    required this.onHotSearchRefreshed,
    super.key,
  });

  final List<String> history;
  final ValueChanged<String> onHistorySelected;
  final VoidCallback onHistoryCleared;
  final ValueChanged<String> onHotSearchSelected;
  final List<PluginSearchSuggestion> hotSearches;
  final VoidCallback onHotSearchRefreshed;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SearchHistoryRow(
          history: history,
          onHistorySelected: onHistorySelected,
          onHistoryCleared: onHistoryCleared,
        ),
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
                    onPressed: () =>
                        onHotSearchSelected(hotSearches[index].query),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SearchHistoryRow extends StatefulWidget {
  const _SearchHistoryRow({
    required this.history,
    required this.onHistorySelected,
    required this.onHistoryCleared,
  });

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
            child: Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                key: const Key('search-history-scroll'),
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: AppSpacing.unit),
                child: Row(
                  children: widget.history.isEmpty
                      ? <Widget>[
                          Text(
                            '暂无历史关键词',
                            style: textTheme.bodySmall?.copyWith(
                              color: tokens.mutedText,
                            ),
                          ),
                        ]
                      : widget.history
                            .map(
                              (value) => Padding(
                                padding: const EdgeInsets.only(
                                  right: AppSpacing.compact,
                                ),
                                child: _SearchHistoryChip(
                                  label: value,
                                  onPressed: () =>
                                      widget.onHistorySelected(value),
                                ),
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

class SearchResultsSection extends StatelessWidget {
  const SearchResultsSection({
    required this.result,
    required this.status,
    required this.error,
    required this.onContentPressed,
    required this.onRetry,
    super.key,
  });

  final PluginSearchResult? result;
  final SearchPageStatus status;
  final AppError? error;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final isSearching = status == SearchPageStatus.searching;
    if (result == null) {
      return _SearchResultMessage(
        key: const Key('app-empty-search-page'),
        icon: status == SearchPageStatus.loadingSources
            ? Icons.hourglass_top_rounded
            : error == null
            ? Icons.manage_search_rounded
            : Icons.error_outline_rounded,
        title: status == SearchPageStatus.loadingSources
            ? '正在准备搜索'
            : error == null
            ? '输入关键词开始搜索'
            : _sourceErrorTitle(error!),
        message: status == SearchPageStatus.loadingSources
            ? '正在读取可用书源。'
            : error == null
            ? '书源数据接入后，结果会显示在这里。'
            : '稳定错误码：${error!.code.wireValue}',
        loading: status == SearchPageStatus.loadingSources,
        onRetry: error == null ? null : onRetry,
      );
    }
    final searchResult = result!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Divider(),
        const SizedBox(height: AppSpacing.comfortable),
        _ResultHeader(result: searchResult),
        if (isSearching) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          const LinearProgressIndicator(),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          _InlineSearchFailure(error: error!, onRetry: onRetry),
        ],
        const SizedBox(height: AppSpacing.compact),
        if (searchResult.items.isEmpty)
          const _SearchResultMessage(
            key: Key('search-empty-result'),
            icon: Icons.search_off_rounded,
            title: '没有搜索结果',
            message: '当前书源没有返回匹配内容。',
          )
        else
          Column(
            key: const Key('source-search-results'),
            children: <Widget>[
              for (
                var index = 0;
                index < searchResult.items.length;
                index++
              ) ...<Widget>[
                SearchResultTile(
                  content: searchResult.items[index],
                  variant: _coverVariantFor(searchResult.items[index], index),
                  onPressed: () => onContentPressed(searchResult.items[index]),
                ),
              ],
            ],
          ),
      ],
    );
  }
}

DiscoveryCoverVariant _coverVariantFor(
  PluginContentSummary content,
  int index,
) => switch (content.id) {
  'preview-1' || 'preview-2' || 'preview-4' => DiscoveryCoverVariant.gothic,
  'preview-3' => DiscoveryCoverVariant.abyss,
  _ =>
    DiscoveryCoverVariant.values[index % DiscoveryCoverVariant.values.length],
};

/// A compact, source-neutral search result. Runtime data populates it later.
class SearchResultTile extends StatelessWidget {
  const SearchResultTile({
    required this.content,
    required this.variant,
    required this.onPressed,
    super.key,
  });
  final PluginContentSummary content;
  final DiscoveryCoverVariant variant;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DiscoveryContentListItem(
      item: PluginDiscoveryContentItem(
        content: content,
        rank: null,
        metric: _searchMetric(content),
        recommendation: null,
      ),
      variant: variant,
      onPressed: onPressed,
      keyPrefix: 'search-result',
    );
  }
}

PluginDiscoveryMetric? _searchMetric(PluginContentSummary content) {
  for (final attribute in content.attributes) {
    if (attribute.key == 'searchHeat' || attribute.key == 'heat') {
      return PluginDiscoveryMetric(
        label: attribute.label.trim().isEmpty ? '热度' : attribute.label,
        value: attribute.value,
      );
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
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
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
          constraints: const BoxConstraints(
            minHeight: AppSpacing.searchHistoryChipHeight,
          ),
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
  const _HotSearchItem({
    required this.rank,
    required this.label,
    required this.metric,
    required this.onPressed,
  });
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
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: isTopRank ? tokens.accent : tokens.mutedText,
                ),
              ),
            ),
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (metric != null) ...<Widget>[
              const SizedBox(width: AppSpacing.compact),
              Text(
                metric!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
              ),
            ],
            if (isTopRank)
              Icon(
                Icons.local_fire_department_rounded,
                size: 17,
                color: tokens.notification,
                semanticLabel: '热门',
              ),
          ],
        ),
      ),
    );
  }
}

class _ResultHeader extends StatelessWidget {
  const _ResultHeader({required this.result});
  final PluginSearchResult result;
  @override
  Widget build(BuildContext context) {
    final count = result.totalCount ?? result.items.length;
    final tokens = AppThemeTokens.of(context);
    return Row(
      children: <Widget>[
        Text('搜索结果', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(width: AppSpacing.compact),
        Text('（共 $count 条）', style: Theme.of(context).textTheme.bodyMedium),
        const Spacer(),
        Text(
          '按相关性',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
        ),
        Icon(Icons.arrow_drop_down_rounded, color: tokens.mutedText),
      ],
    );
  }
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
    super.key,
  });
  final IconData icon;
  final String title;
  final String message;
  final bool loading;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.section),
      child: Center(
        child: Column(
          children: <Widget>[
            if (loading)
              const SizedBox(
                width: AppSpacing.section,
                height: AppSpacing.section,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, size: AppSpacing.section, color: tokens.mutedText),
            const SizedBox(height: AppSpacing.regular),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.unit),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('重试')),
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
