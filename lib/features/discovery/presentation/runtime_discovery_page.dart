import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

/// Host-controlled, lossless renderer for a validated source discovery tree.
class RuntimeDiscoveryPage extends StatelessWidget {
  const RuntimeDiscoveryPage({
    required this.result,
    required this.onDestinationRequested,
    required this.onSourcePressed,
    required this.onTabSelected,
    required this.onCategorySelected,
    required this.onContentPressed,
    required this.onAddToShelf,
    required this.onRefreshRequested,
    required this.onLoadMore,
    required this.canNavigateBack,
    required this.onBackRequested,
    required this.loadingCollectionId,
    super.key,
  });

  final PluginDiscoveryDocumentResult result;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final VoidCallback onSourcePressed;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final ValueChanged<PluginContentSummary> onAddToShelf;
  final VoidCallback onRefreshRequested;
  final ValueChanged<PluginDiscoveryContentCollectionComponent> onLoadMore;
  final bool canNavigateBack;
  final VoidCallback onBackRequested;
  final String? loadingCollectionId;

  @override
  Widget build(BuildContext context) {
    final components = result.document.components;
    return PopScope(
      canPop: !canNavigateBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onBackRequested();
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppSpacing.mobileContentMaxWidth,
              ),
              child: ListView(
                key: const Key('runtime-discovery-content'),
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.discoveryPagePadding,
                  AppSpacing.homeContentTopPadding,
                  AppSpacing.discoveryPagePadding,
                  AppSpacing.page,
                ),
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (canNavigateBack)
                        IconButton(
                          key: const Key('runtime-discovery-back'),
                          tooltip: '返回上一级',
                          onPressed: onBackRequested,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      Expanded(
                        child: DiscoveryTopBar(
                          sourceName: result.sourceName,
                          onSourcePressed: onSourcePressed,
                          onSearchPressed: () => onDestinationRequested(
                            AppNavigationDestination.search,
                          ),
                          onToggleTheme: () => AppThemeModeScope.of(
                            context,
                          ).onToggleTheme(Theme.of(context).brightness),
                        ),
                      ),
                    ],
                  ),
                  for (final component in components) ...<Widget>[
                    _DiscoveryComponentRenderer(
                      component: component,
                      onTabSelected: onTabSelected,
                      onCategorySelected: onCategorySelected,
                      onContentPressed: onContentPressed,
                      onAddToShelf: onAddToShelf,
                      onLoadMore: onLoadMore,
                      loadingCollectionId: loadingCollectionId,
                    ),
                    const SizedBox(height: AppSpacing.section),
                  ],
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      key: const Key('runtime-discovery-refresh'),
                      onPressed: onRefreshRequested,
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('刷新'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: AppBottomNavigation(
            selected: AppNavigationDestination.discover,
            onSelected: (destination) {
              if (destination != AppNavigationDestination.discover) {
                onDestinationRequested(destination);
              }
            },
          ),
        ),
      ),
    );
  }
}

class _DiscoveryComponentRenderer extends StatelessWidget {
  const _DiscoveryComponentRenderer({
    required this.component,
    required this.onTabSelected,
    required this.onCategorySelected,
    required this.onContentPressed,
    required this.onAddToShelf,
    required this.onLoadMore,
    required this.loadingCollectionId,
  });

  final PluginDiscoveryComponent component;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final ValueChanged<PluginContentSummary> onAddToShelf;
  final ValueChanged<PluginDiscoveryContentCollectionComponent> onLoadMore;
  final String? loadingCollectionId;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey<String>('runtime-discovery-component-${component.id}'),
    child: switch (component) {
      PluginDiscoveryTabsComponent(:final tabs, :final selectedTabId) =>
        _TabsComponent(
          component: PluginDiscoveryTabsComponent(
            id: component.id,
            tabs: tabs,
            selectedTabId: selectedTabId,
          ),
          onSelected: onTabSelected,
        ),
      PluginDiscoverySectionComponent(
        :final title,
        :final subtitle,
        :final children,
      ) =>
        _SectionComponent(
          component: PluginDiscoverySectionComponent(
            id: component.id,
            title: title,
            subtitle: subtitle,
            children: children,
          ),
          child: _ChildrenComponent(children: children, renderer: this),
        ),
      PluginDiscoveryGroupComponent(:final layout, :final children) =>
        _GroupComponent(
          component: PluginDiscoveryGroupComponent(
            id: component.id,
            layout: layout,
            children: children,
          ),
          renderer: this,
        ),
      PluginDiscoveryContentCollectionComponent(
        :final layout,
        :final items,
        :final continuation,
      ) =>
        _ContentCollection(
          component: PluginDiscoveryContentCollectionComponent(
            id: component.id,
            layout: layout,
            items: items,
            continuation: continuation,
          ),
          onContentPressed: onContentPressed,
          onAddToShelf: onAddToShelf,
          onLoadMore: onLoadMore,
          isLoading: loadingCollectionId == component.id,
        ),
      PluginDiscoveryCategoryCollectionComponent(
        :final layout,
        :final categories,
      ) =>
        _CategoryCollection(
          component: PluginDiscoveryCategoryCollectionComponent(
            id: component.id,
            layout: layout,
            categories: categories,
          ),
          onSelected: onCategorySelected,
        ),
      PluginDiscoveryTextComponent(:final text) => Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: AppThemeTokens.of(context).mutedText,
        ),
      ),
      PluginDiscoveryDividerComponent() => const Divider(),
    },
  );
}

class _ChildrenComponent extends StatelessWidget {
  const _ChildrenComponent({required this.children, required this.renderer});

  final List<PluginDiscoveryComponent> children;
  final _DiscoveryComponentRenderer renderer;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children
        .map(
          (child) => Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.compact),
            child: _DiscoveryComponentRenderer(
              component: child,
              onTabSelected: renderer.onTabSelected,
              onCategorySelected: renderer.onCategorySelected,
              onContentPressed: renderer.onContentPressed,
              onAddToShelf: renderer.onAddToShelf,
              onLoadMore: renderer.onLoadMore,
              loadingCollectionId: renderer.loadingCollectionId,
            ),
          ),
        )
        .toList(growable: false),
  );
}

class _TabsComponent extends StatelessWidget {
  const _TabsComponent({required this.component, required this.onSelected});

  final PluginDiscoveryTabsComponent component;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('runtime-discovery-tabs'),
    height: AppSpacing.minimumTouchTarget,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: component.tabs.length,
      separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.compact),
      itemBuilder: (_, index) {
        final tab = component.tabs[index];
        return ChoiceChip(
          key: ValueKey<String>('runtime-discovery-tab-${tab.id}'),
          label: Text(tab.label),
          selected: tab.id == component.selectedTabId,
          onSelected: (_) => onSelected(tab.target),
        );
      },
    ),
  );
}

class _SectionComponent extends StatelessWidget {
  const _SectionComponent({required this.component, required this.child});

  final PluginDiscoverySectionComponent component;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Semantics(
        header: true,
        child: Text(
          component.title,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      if (component.subtitle != null) ...<Widget>[
        const SizedBox(height: AppSpacing.unit),
        Text(component.subtitle!, style: Theme.of(context).textTheme.bodySmall),
      ],
      const SizedBox(height: AppSpacing.compact),
      child,
    ],
  );
}

class _GroupComponent extends StatelessWidget {
  const _GroupComponent({required this.component, required this.renderer});

  final PluginDiscoveryGroupComponent component;
  final _DiscoveryComponentRenderer renderer;

  @override
  Widget build(BuildContext context) {
    final children = component.children
        .map(
          (child) => _DiscoveryComponentRenderer(
            component: child,
            onTabSelected: renderer.onTabSelected,
            onCategorySelected: renderer.onCategorySelected,
            onContentPressed: renderer.onContentPressed,
            onAddToShelf: renderer.onAddToShelf,
            onLoadMore: renderer.onLoadMore,
            loadingCollectionId: renderer.loadingCollectionId,
          ),
        )
        .toList(growable: false);
    return switch (component.layout) {
      PluginDiscoveryGroupLayout.vertical => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
      PluginDiscoveryGroupLayout.horizontal => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
      PluginDiscoveryGroupLayout.grid => LayoutBuilder(
        builder: (context, constraints) => Wrap(
          spacing: AppSpacing.compact,
          runSpacing: AppSpacing.compact,
          children: children
              .map(
                (child) => SizedBox(
                  width: (constraints.maxWidth - AppSpacing.compact) / 2,
                  child: child,
                ),
              )
              .toList(growable: false),
        ),
      ),
    };
  }
}

class _ContentCollection extends StatelessWidget {
  const _ContentCollection({
    required this.component,
    required this.onContentPressed,
    required this.onAddToShelf,
    required this.onLoadMore,
    required this.isLoading,
  });

  final PluginDiscoveryContentCollectionComponent component;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final ValueChanged<PluginContentSummary> onAddToShelf;
  final ValueChanged<PluginDiscoveryContentCollectionComponent> onLoadMore;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final popularItems = <DiscoveryBookViewData, PluginDiscoveryContentItem>{
      for (final item in component.items) _popularData(item): item,
    };
    final rankedItems =
        <DiscoveryRankedBookViewData, PluginDiscoveryContentItem>{
          for (final item in component.items) _rankedData(item): item,
        };
    final cards = component.items
        .map(
          (item) => _DiscoveryBookCard(
            item: item,
            onPressed: () => onContentPressed(item.content),
            onAddToShelf: () => onAddToShelf(item.content),
            showRank: component.layout == PluginDiscoveryContentLayout.ranking,
          ),
        )
        .toList(growable: false);
    final body = switch (component.layout) {
      PluginDiscoveryContentLayout.featured => Column(
        children: <Widget>[
          if (component.items.isNotEmpty)
            DiscoveryHeroCard(
              data: _heroData(component.items.first),
              onPressed: () => onContentPressed(component.items.first.content),
            ),
          ...cards.skip(1),
        ],
      ),
      PluginDiscoveryContentLayout.carousel => DiscoveryPopularBooks(
        books: popularItems.keys.toList(growable: false),
        onBookPressed: (book) => onContentPressed(popularItems[book]!.content),
      ),
      PluginDiscoveryContentLayout.ranking => SizedBox(
        height: AppSpacing.discoveryBoardHeight,
        child: DiscoveryRankingBoard(
          title: '排行榜',
          books: rankedItems.keys.toList(growable: false),
          onPressed: (book) => onContentPressed(rankedItems[book]!.content),
          onMorePressed: component.continuation == null
              ? () {}
              : () => onLoadMore(component),
        ),
      ),
      PluginDiscoveryContentLayout.list => Column(
        children: <Widget>[
          if (component.items.isNotEmpty)
            DiscoveryEditorsChoiceCard(
              data: _editorsChoiceData(component.items.first),
              onPressed: () => onContentPressed(component.items.first.content),
            ),
          ...cards.skip(1),
        ],
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        body,
        if (component.continuation != null) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          OutlinedButton(
            key: ValueKey<String>(
              'runtime-discovery-load-more-${component.id}',
            ),
            onPressed: isLoading ? null : () => onLoadMore(component),
            child: Text(isLoading ? '正在加载' : '加载更多'),
          ),
        ],
      ],
    );
  }
}

class _CategoryCollection extends StatelessWidget {
  const _CategoryCollection({
    required this.component,
    required this.onSelected,
  });

  final PluginDiscoveryCategoryCollectionComponent component;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final viewData = component.categories
        .map(_categoryData)
        .toList(growable: false);
    if (component.layout == PluginDiscoveryCategoryLayout.grid &&
        component.categories.length <= 8) {
      return SizedBox(
        height: AppSpacing.discoveryBoardHeight,
        child: DiscoveryCategoryBoard(
          title: '分类',
          categories: viewData,
          onPressed: () {},
          onCategoryPressed: (category) {
            final target = category.target;
            if (target != null) onSelected(target);
          },
        ),
      );
    }
    final children = component.categories
        .map(
          (category) => OutlinedButton(
            key: ValueKey<String>('runtime-discovery-category-${category.id}'),
            onPressed: () => onSelected(category.target),
            child: Text(category.title),
          ),
        )
        .toList(growable: false);
    return switch (component.layout) {
      PluginDiscoveryCategoryLayout.grid => LayoutBuilder(
        builder: (context, constraints) => Wrap(
          spacing: AppSpacing.compact,
          runSpacing: AppSpacing.compact,
          children: children
              .map(
                (child) => SizedBox(
                  width: (constraints.maxWidth - AppSpacing.compact) / 2,
                  child: child,
                ),
              )
              .toList(growable: false),
        ),
      ),
      PluginDiscoveryCategoryLayout.list => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    };
  }
}

DiscoveryHeroViewData _heroData(PluginDiscoveryContentItem item) =>
    DiscoveryHeroViewData(
      title: item.content.title,
      category: item.content.categories.firstOrNull,
      description: item.recommendation ?? item.content.description,
      metadata: item.content.author,
      coverVariant: _coverVariant(item.content.id),
    );

DiscoveryBookViewData _popularData(PluginDiscoveryContentItem item) =>
    DiscoveryBookViewData(
      title: item.content.title,
      author: item.content.author,
      coverVariant: _coverVariant(item.content.id),
    );

DiscoveryRankedBookViewData _rankedData(PluginDiscoveryContentItem item) =>
    DiscoveryRankedBookViewData(
      rank: item.rank,
      title: item.content.title,
      author: item.content.author,
      heat: item.metric?.value,
      coverVariant: _coverVariant(item.content.id),
    );

DiscoveryEditorsChoiceViewData _editorsChoiceData(
  PluginDiscoveryContentItem item,
) => DiscoveryEditorsChoiceViewData(
  title: item.content.title,
  category: item.content.categories.firstOrNull,
  description: item.recommendation ?? item.content.description,
  metadata: item.content.author,
  coverVariant: _coverVariant(item.content.id),
);

DiscoveryCategoryViewData _categoryData(PluginDiscoveryCategory category) =>
    DiscoveryCategoryViewData(
      title: category.title,
      count: category.count == null ? null : '${category.count} 本',
      icon:
          DiscoveryCategoryIcon.values[category.id.codeUnits.fold<int>(
                0,
                (sum, value) => sum + value,
              ) %
              DiscoveryCategoryIcon.values.length],
      target: category.target,
    );

extension on List<String> {
  String? get firstOrNull => isEmpty ? null : first;
}

class _DiscoveryBookCard extends StatelessWidget {
  const _DiscoveryBookCard({
    required this.item,
    required this.onPressed,
    required this.onAddToShelf,
    required this.showRank,
  });

  final PluginDiscoveryContentItem item;
  final VoidCallback onPressed;
  final VoidCallback onAddToShelf;
  final bool showRank;

  @override
  Widget build(BuildContext context) {
    final content = item.content;
    return Card(
      child: InkWell(
        key: ValueKey<String>('runtime-discovery-item-${content.id}'),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.regular),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (showRank && item.rank != null) ...<Widget>[
                Text(
                  '${item.rank}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: AppSpacing.compact),
              ],
              DiscoveryBookCover(
                title: content.title,
                coverUrl: content.coverUrl,
                variant: _coverVariant(content.id),
                width: 54,
                height: 76,
              ),
              const SizedBox(width: AppSpacing.compact),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      content.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (content.author != null)
                      Text(
                        content.author!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (content.description != null)
                      Text(
                        content.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: ValueKey<String>(
                          'runtime-discovery-add-shelf-${content.id}',
                        ),
                        onPressed: onAddToShelf,
                        child: const Text('加入书架'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return DiscoveryCoverVariant.values[checksum %
      DiscoveryCoverVariant.values.length];
}
