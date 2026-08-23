import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';

/// Host-controlled, lossless renderer for a validated source discovery tree.
class RuntimeDiscoveryPage extends StatelessWidget {
  const RuntimeDiscoveryPage({
    required this.result,
    required this.onDestinationRequested,
    this.onSearchRequested,
    required this.onSourcePressed,
    required this.onTabSelected,
    required this.onCategorySelected,
    required this.onContentPressed,
    required this.onRefreshRequested,
    required this.onLoadMore,
    required this.canNavigateBack,
    required this.onBackRequested,
    required this.loadingCollectionId,
    this.sourceName,
    this.isContentLoading = false,
    this.contentIsEmpty = false,
    this.contentFailureMessage,
    this.contentFailureCode,
    super.key,
  });

  final PluginDiscoveryDocumentResult? result;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final VoidCallback? onSearchRequested;
  final VoidCallback onSourcePressed;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final VoidCallback onRefreshRequested;
  final ValueChanged<PluginDiscoveryContentCollectionComponent> onLoadMore;
  final bool canNavigateBack;
  final VoidCallback onBackRequested;
  final String? loadingCollectionId;
  final String? sourceName;
  final bool isContentLoading;
  final bool contentIsEmpty;
  final String? contentFailureMessage;
  final String? contentFailureCode;

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    final components =
        result?.document.components ?? const <PluginDiscoveryComponent>[];
    final resolvedSourceName = sourceName ?? result?.sourceName ?? '当前来源';
    return CallbackShortcuts(
      // Discovery owns an in-page navigation stack. Keep Escape on the same
      // callback as the visible back button and PopScope; do not pop the
      // outer GoRouter destination while a category stack still exists.
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): onBackRequested,
      },
      child: Focus(
        autofocus: true,
        child: PopScope(
          canPop: !canNavigateBack,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) onBackRequested();
          },
          child: Scaffold(
            body: SafeArea(
              bottom: false,
              child: Align(
                alignment: canNavigateBack
                    ? Alignment.topLeft
                    : Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: canNavigateBack
                        ? AppSpacing.discoveryListMaxWidth
                        : AppSpacing.mobileContentMaxWidth,
                  ),
                  child: ListView(
                    key: const Key('runtime-discovery-content'),
                    padding: EdgeInsets.fromLTRB(
                      canNavigateBack
                          ? AppSpacing.regular
                          : AppSpacing.discoveryPagePadding,
                      AppSpacing.pageHeaderTopPadding,
                      canNavigateBack
                          ? AppSpacing.regular
                          : AppSpacing.discoveryPagePadding,
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
                              title: canNavigateBack
                                  ? _nestedPageTitle(components) ?? '发现'
                                  : '发现',
                              sourceName: resolvedSourceName,
                              onSourcePressed: onSourcePressed,
                              onSearchPressed:
                                  onSearchRequested ??
                                  () => onDestinationRequested(
                                    AppNavigationDestination.search,
                                  ),
                              onToggleTheme: () => AppThemeModeScope.of(
                                context,
                              ).onToggleTheme(Theme.of(context).brightness),
                              onRefreshPressed: onRefreshRequested,
                            ),
                          ),
                        ],
                      ),
                      if (result == null)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: AppSpacing.section,
                          ),
                          child: _DiscoveryContentState(
                            isLoading: isContentLoading,
                            isEmpty: contentIsEmpty,
                            failureMessage: contentFailureMessage,
                            failureCode: contentFailureCode,
                            onRetry: onRefreshRequested,
                          ),
                        )
                      else
                        for (final component in components) ...<Widget>[
                          _DiscoveryComponentRenderer(
                            component: component,
                            hideSectionTitle: canNavigateBack,
                            onTabSelected: onTabSelected,
                            onCategorySelected: onCategorySelected,
                            onContentPressed: onContentPressed,
                            onLoadMore: onLoadMore,
                            loadingCollectionId: loadingCollectionId,
                          ),
                          const SizedBox(height: AppSpacing.section),
                        ],
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
        ),
      ),
    );
  }
}

class _DiscoveryContentState extends StatelessWidget {
  const _DiscoveryContentState({
    required this.isLoading,
    required this.isEmpty,
    required this.onRetry,
    this.failureMessage,
    this.failureCode,
  });

  final bool isLoading;
  final bool isEmpty;
  final String? failureMessage;
  final String? failureCode;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const AppLoadingState(
        key: Key('discovery-loading-content'),
        label: '正在加载发现内容',
        message: '插件正在生成分区、榜单和分类。',
      );
    }
    return Column(
      key: Key(isEmpty ? 'discovery-empty' : 'discovery-failure'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          isEmpty ? Icons.inbox_outlined : Icons.error_outline_rounded,
          size: 40,
          color: AppThemeTokens.of(context).mutedText,
        ),
        const SizedBox(height: AppSpacing.regular),
        Text(failureMessage ?? '当前来源没有发现内容。'),
        if (failureCode != null) ...<Widget>[
          const SizedBox(height: AppSpacing.unit),
          Text(
            '稳定错误码：$failureCode',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: AppSpacing.regular),
        TextButton(onPressed: onRetry, child: const Text('刷新')),
      ],
    );
  }
}

class _DiscoveryComponentRenderer extends StatelessWidget {
  const _DiscoveryComponentRenderer({
    required this.component,
    required this.onTabSelected,
    required this.onCategorySelected,
    required this.onContentPressed,
    required this.onLoadMore,
    required this.loadingCollectionId,
    this.hideSectionTitle = false,
  });

  final PluginDiscoveryComponent component;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final ValueChanged<PluginDiscoveryContentCollectionComponent> onLoadMore;
  final String? loadingCollectionId;
  final bool hideSectionTitle;

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
          hideTitle: hideSectionTitle,
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
              onLoadMore: renderer.onLoadMore,
              loadingCollectionId: renderer.loadingCollectionId,
              hideSectionTitle: renderer.hideSectionTitle,
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
  const _SectionComponent({
    required this.component,
    required this.child,
    required this.hideTitle,
  });

  final PluginDiscoverySectionComponent component;
  final Widget child;
  final bool hideTitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      if (!hideTitle)
        Semantics(
          header: true,
          child: Text(
            component.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      if (!hideTitle) const SizedBox(height: AppSpacing.compact),
      if (component.subtitle != null) ...<Widget>[
        const SizedBox(height: AppSpacing.unit),
        Text(component.subtitle!, style: Theme.of(context).textTheme.bodySmall),
      ],
      if (hideTitle && component.subtitle == null)
        const SizedBox(height: AppSpacing.unit),
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
            onLoadMore: renderer.onLoadMore,
            loadingCollectionId: renderer.loadingCollectionId,
            hideSectionTitle: renderer.hideSectionTitle,
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
    required this.onLoadMore,
    required this.isLoading,
  });

  final PluginDiscoveryContentCollectionComponent component;
  final ValueChanged<PluginContentSummary> onContentPressed;
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
      PluginDiscoveryContentLayout.list => Column(children: cards),
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

String? _nestedPageTitle(List<PluginDiscoveryComponent> components) {
  for (final component in components) {
    final title = switch (component) {
      PluginDiscoverySectionComponent(:final title) => title,
      PluginDiscoveryGroupComponent(:final children) => _nestedPageTitle(
        children,
      ),
      _ => null,
    };
    if (title != null && title.trim().isNotEmpty) return title;
  }
  return null;
}

extension on List<String> {
  String? get firstOrNull => isEmpty ? null : first;
}

class _DiscoveryBookCard extends StatelessWidget {
  const _DiscoveryBookCard({
    required this.item,
    required this.onPressed,
    required this.showRank,
  });

  final PluginDiscoveryContentItem item;
  final VoidCallback onPressed;
  final bool showRank;

  @override
  Widget build(BuildContext context) {
    final content = item.content;
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final tags = <String>[
      ...content.categories,
      ...content.tags,
    ].take(3).toList(growable: false);
    final description = item.recommendation ?? content.description;
    return LayoutBuilder(
      builder: (context, constraints) {
        final coverWidth = math.min(
          AppSpacing.discoveryListCoverMaxWidth,
          math.max(
            AppSpacing.discoveryListCoverMinWidth,
            constraints.maxWidth * 0.16,
          ),
        );
        final coverHeight =
            coverWidth * AppSpacing.discoveryListCoverAspectRatio;
        final titleStyle = theme.textTheme.titleMedium?.copyWith(
          fontSize: constraints.maxWidth >= 500 ? 20 : null,
        );
        final metadataStyle = theme.textTheme.bodyMedium?.copyWith(
          color: tokens.mutedText,
        );
        return Material(
          color: tokens.surface,
          child: InkWell(
            key: ValueKey<String>('runtime-discovery-item-${content.id}'),
            onTap: onPressed,
            child: Container(
              constraints: BoxConstraints(minHeight: coverHeight),
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: tokens.divider, width: 0.8),
                ),
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (showRank && item.rank != null) ...<Widget>[
                      Text('${item.rank}', style: theme.textTheme.titleMedium),
                      const SizedBox(width: AppSpacing.compact),
                    ],
                    DiscoveryBookCover(
                      title: content.title,
                      coverUrl: content.coverUrl,
                      variant: _coverVariant(content.id),
                      width: coverWidth,
                      height: coverHeight,
                    ),
                    const SizedBox(width: AppSpacing.regular),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            content.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                          const SizedBox(height: AppSpacing.unit),
                          Text(
                            _authorAndCategory(content),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (tags.isNotEmpty) ...<Widget>[
                            const SizedBox(height: AppSpacing.unit),
                            Wrap(
                              spacing: AppSpacing.compact,
                              runSpacing: AppSpacing.unit,
                              children: tags
                                  .map((tag) => _DiscoveryListTag(label: tag))
                                  .toList(growable: false),
                            ),
                          ],
                          if (description != null) ...<Widget>[
                            const SizedBox(height: AppSpacing.unit),
                            Text(
                              description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                          const Spacer(),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  _bookMetadata(content),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: metadataStyle,
                                ),
                              ),
                              if (item.metric != null) ...<Widget>[
                                const SizedBox(width: AppSpacing.compact),
                                Padding(
                                  padding: const EdgeInsets.only(
                                    right: AppSpacing.comfortable,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Icon(
                                        Icons.local_fire_department_rounded,
                                        size: 16,
                                        color: tokens.notification,
                                      ),
                                      const SizedBox(width: AppSpacing.unit),
                                      Text(
                                        '${item.metric!.value}${item.metric!.label}',
                                        style: metadataStyle,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DiscoveryListTag extends StatelessWidget {
  const _DiscoveryListTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Container(
      height: AppSpacing.discoveryListTagHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular),
      decoration: BoxDecoration(
        color: tokens.accentSoft.withValues(alpha: 0.62),
        borderRadius: AppRadii.pill,
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: tokens.accent),
      ),
    );
  }
}

String _authorAndCategory(PluginContentSummary content) {
  return <String>[
    if (content.author != null && content.author!.trim().isNotEmpty)
      content.author!,
    if (content.categories.isNotEmpty) content.categories.first,
  ].join(' · ');
}

String _bookMetadata(PluginContentSummary content) {
  final updateLabel = _attributeValue(
    content.attributes,
    'discoveryUpdatedLabel',
  );
  final resolvedUpdateLabel =
      updateLabel ?? _relativeUpdateLabel(content.updatedAt);
  return <String>[
    if (content.chapterCount != null) '${content.chapterCount}章',
    _statusLabel(content.status),
    ?resolvedUpdateLabel,
  ].join(' · ');
}

String? _relativeUpdateLabel(DateTime? updatedAt) {
  if (updatedAt == null) return null;
  final elapsed = DateTime.now().toUtc().difference(updatedAt.toUtc());
  if (elapsed.inDays > 0) return '${elapsed.inDays}天前更新';
  if (elapsed.inHours > 0) return '${elapsed.inHours}小时前更新';
  if (elapsed.inMinutes > 0) return '${elapsed.inMinutes}分钟前更新';
  return '刚刚更新';
}

String _statusLabel(PluginContentStatus value) => switch (value) {
  PluginContentStatus.ongoing => '连载中',
  PluginContentStatus.completed => '完结',
  PluginContentStatus.hiatus => '暂停',
  PluginContentStatus.unknown => '未知',
};

String? _attributeValue(
  Iterable<PluginContentAttribute> attributes,
  String key,
) {
  for (final attribute in attributes) {
    if (attribute.key == key) return attribute.value;
  }
  return null;
}

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return DiscoveryCoverVariant.values[checksum %
      DiscoveryCoverVariant.values.length];
}
