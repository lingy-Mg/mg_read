/// 运行时发现页。
///
/// 职责：
/// - 渲染来源提供的发现内容、分类和内容列表。
/// - 转发分类、搜索、详情和导航操作。
/// - 将递归组件树编排为封面网格、横向书架、紧凑榜单和自适应组合容器。
/// - 统一递归 section 的主标题、副标题、语义图标和内容间距。
/// - 将旧 ranking 布局兼容映射到标准紧凑榜单，避免来源选择宿主尺寸。
/// - 将加载/空/失败状态交给独立展示组件，保持页面容器聚焦。
///
/// 注意：
/// - 页面只渲染已由 application 层准备好的数据，不在 build() 中执行 IO。
/// - 分类列表标签需与复用的发现内容列表项保持一致的视觉规格。
///
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/discovery_composite_components.dart';
import 'package:mg_read/features/discovery/presentation/discovery_content_state.dart';
import 'package:mg_read/features/discovery/presentation/discovery_semantic_icons.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_drag_scroll_behavior.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_list_tag.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

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
    this.isInBookshelf = _neverInBookshelf,
    required this.canNavigateBack,
    required this.onBackRequested,
    required this.loadingCollectionId,
    this.allowsRoutePop = false,
    this.navigationDepth = 0,
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
  final bool Function(PluginContentSummary content) isInBookshelf;
  final bool canNavigateBack;
  final VoidCallback onBackRequested;
  final String? loadingCollectionId;
  final bool allowsRoutePop;
  final int navigationDepth;
  final String? sourceName;
  final bool isContentLoading;
  final bool contentIsEmpty;
  final String? contentFailureMessage;
  final String? contentFailureCode;

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    final components = result?.document.components ?? const <PluginDiscoveryComponent>[];
    final resolvedSourceName = sourceName ?? result?.sourceName ?? '当前来源';
    final isNestedPage = navigationDepth > 0;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return BookCoverSourceScope(
      pluginId: result?.pluginId ?? 'unavailable',
      child: CallbackShortcuts(
        // Discovery owns an in-page navigation stack. Keep Escape on the same
        // callback as the visible back button and PopScope; do not pop the
        // outer GoRouter destination while a category stack still exists.
        bindings: <ShortcutActivator, VoidCallback>{const SingleActivator(LogicalKeyboardKey.escape): onBackRequested},
        child: Focus(
          autofocus: true,
          child: PopScope(
            canPop: allowsRoutePop || !canNavigateBack,
            onPopInvokedWithResult: (didPop, _) {
              if (!allowsRoutePop && !didPop) onBackRequested();
            },
            child: Scaffold(
              body: SafeArea(
                bottom: false,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool useWidePagePadding = constraints.maxWidth >= AppSpacing.compactLayoutBreakpoint;
                    final double pagePadding = useWidePagePadding ? AppSpacing.widePagePadding : AppSpacing.discoveryPagePadding;
                    return Align(
                      alignment: isNestedPage ? Alignment.topLeft : Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: isNestedPage ? AppSpacing.discoveryListMaxWidth : AppSpacing.contentMaxWidth),
                        child: AnimatedSwitcher(
                          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 180),
                          reverseDuration: reduceMotion ? Duration.zero : const Duration(milliseconds: 150),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) => SlideTransition(
                            position: Tween<Offset>(begin: const Offset(0.07, 0), end: Offset.zero).animate(animation),
                            child: FadeTransition(opacity: animation, child: child),
                          ),
                          child: KeyedSubtree(
                            key: ValueKey<String>('runtime-discovery-page-$navigationDepth-${result == null ? 'loading' : 'content'}'),
                            child: ListView(
                              key: PageStorageKey<int>(navigationDepth),
                              padding: EdgeInsets.fromLTRB(
                                pagePadding,
                                AppSpacing.pageHeaderTopPaddingFor(context),
                                pagePadding,
                                AppSpacing.page,
                              ),
                              children: <Widget>[
                                DiscoveryTopBar(
                                  title: isNestedPage ? _nestedPageTitle(components) ?? '发现' : '发现',
                                  sourceName: resolvedSourceName,
                                  onSourcePressed: onSourcePressed,
                                  onSearchPressed: onSearchRequested ?? () => onDestinationRequested(AppNavigationDestination.search),
                                  onToggleTheme: () => AppThemeModeScope.of(context).onToggleTheme(Theme.of(context).brightness),
                                  onRefreshPressed: onRefreshRequested,
                                  onBackPressed: isNestedPage ? onBackRequested : null,
                                  barKey: isNestedPage ? const Key('runtime-discovery-nested-header') : null,
                                  backButtonKey: isNestedPage ? const Key('runtime-discovery-back') : null,
                                  showSourceSelector: !isNestedPage,
                                ),
                                if (result == null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: AppSpacing.section),
                                    child: DiscoveryContentState(
                                      isLoading: isContentLoading,
                                      isEmpty: contentIsEmpty,
                                      failureMessage: contentFailureMessage,
                                      failureCode: contentFailureCode,
                                      onRetry: onRefreshRequested,
                                    ),
                                  )
                                else
                                  for (var index = 0; index < components.length; index++) ...<Widget>[
                                    _DiscoveryComponentRenderer(
                                      component: components[index],
                                      hideSectionTitle: canNavigateBack,
                                      onTabSelected: onTabSelected,
                                      onCategorySelected: onCategorySelected,
                                      onContentPressed: onContentPressed,
                                      onLoadMore: onLoadMore,
                                      loadingCollectionId: loadingCollectionId,
                                      isInBookshelf: isInBookshelf,
                                    ),
                                    if (index != components.length - 1) const SizedBox(height: AppSpacing.discoverySectionSpacing),
                                  ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              bottomNavigationBar: isNestedPage
                  ? null
                  : SafeArea(
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
      ),
    );
  }
}

bool _neverInBookshelf(PluginContentSummary _) => false;

class _DiscoveryComponentRenderer extends StatelessWidget {
  const _DiscoveryComponentRenderer({
    required this.component,
    required this.onTabSelected,
    required this.onCategorySelected,
    required this.onContentPressed,
    required this.onLoadMore,
    required this.loadingCollectionId,
    required this.isInBookshelf,
    this.hideSectionTitle = false,
  });

  final PluginDiscoveryComponent component;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final ValueChanged<PluginDiscoveryContentCollectionComponent> onLoadMore;
  final String? loadingCollectionId;
  final bool Function(PluginContentSummary content) isInBookshelf;
  final bool hideSectionTitle;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey<String>('runtime-discovery-component-${component.id}'),
    child: switch (component) {
      PluginDiscoveryTabsComponent(:final tabs, :final selectedTabId) => _TabsComponent(
        component: PluginDiscoveryTabsComponent(id: component.id, tabs: tabs, selectedTabId: selectedTabId),
        onSelected: onTabSelected,
      ),
      PluginDiscoverySectionComponent(:final title, :final subtitle, :final children, :final icon) => _SectionComponent(
        component: PluginDiscoverySectionComponent(id: component.id, title: title, subtitle: subtitle, children: children, icon: icon),
        hideTitle: hideSectionTitle,
        child: _ChildrenComponent(children: children, renderer: this),
      ),
      PluginDiscoveryGroupComponent(:final layout, :final children) => _GroupComponent(
        component: PluginDiscoveryGroupComponent(id: component.id, layout: layout, children: children),
        renderer: this,
      ),
      PluginDiscoveryContentCollectionComponent(:final layout, :final items, :final continuation) => _ContentCollection(
        component: PluginDiscoveryContentCollectionComponent(id: component.id, layout: layout, items: items, continuation: continuation),
        onContentPressed: onContentPressed,
        onLoadMore: onLoadMore,
        isLoading: loadingCollectionId == component.id,
        isInBookshelf: isInBookshelf,
      ),
      PluginDiscoveryCategoryCollectionComponent(:final layout, :final categories) => _CategoryCollection(
        component: PluginDiscoveryCategoryCollectionComponent(id: component.id, layout: layout, categories: categories),
        onSelected: onCategorySelected,
      ),
      PluginDiscoveryTextComponent(:final text) => Text(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppThemeTokens.of(context).mutedText),
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
    children: <Widget>[
      for (var index = 0; index < children.length; index++) ...<Widget>[
        _DiscoveryComponentRenderer(
          component: children[index],
          onTabSelected: renderer.onTabSelected,
          onCategorySelected: renderer.onCategorySelected,
          onContentPressed: renderer.onContentPressed,
          onLoadMore: renderer.onLoadMore,
          loadingCollectionId: renderer.loadingCollectionId,
          isInBookshelf: renderer.isInBookshelf,
          hideSectionTitle: renderer.hideSectionTitle,
        ),
        if (index != children.length - 1) const SizedBox(height: AppSpacing.discoveryComponentGap),
      ],
    ],
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
        return DiscoveryComponentChip(
          key: ValueKey<String>('runtime-discovery-tab-${tab.id}'),
          icon: tab.icon == null ? null : discoverySemanticIcon(tab.icon),
          label: tab.label,
          selected: tab.id == component.selectedTabId,
          onPressed: () => onSelected(tab.target),
        );
      },
    ),
  );
}

class _SectionComponent extends StatelessWidget {
  const _SectionComponent({required this.component, required this.child, required this.hideTitle});

  final PluginDiscoverySectionComponent component;
  final Widget child;
  final bool hideTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (!hideTitle)
          Semantics(
            header: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (component.icon != null) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.unit / 2),
                    child: Icon(discoverySemanticIcon(component.icon), size: 20, color: tokens.accent),
                  ),
                  const SizedBox(width: AppSpacing.compact),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        component.title,
                        key: ValueKey<String>('runtime-discovery-section-title-${component.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onSurface),
                      ),
                      if (component.subtitle != null) ...<Widget>[
                        const SizedBox(height: AppSpacing.unit),
                        Text(
                          component.subtitle!,
                          key: ValueKey<String>('runtime-discovery-section-subtitle-${component.id}'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          )
        else if (component.subtitle != null)
          Text(
            component.subtitle!,
            key: ValueKey<String>('runtime-discovery-section-subtitle-${component.id}'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
          ),
        if (!hideTitle || component.subtitle != null) const SizedBox(height: AppSpacing.discoverySectionContentGap),
        child,
      ],
    );
  }
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
            isInBookshelf: renderer.isInBookshelf,
            hideSectionTitle: renderer.hideSectionTitle,
          ),
        )
        .toList(growable: false);
    return switch (component.layout) {
      PluginDiscoveryGroupLayout.vertical => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var index = 0; index < children.length; index++) ...<Widget>[
            children[index],
            if (index != children.length - 1) const SizedBox(height: AppSpacing.discoverySectionSpacing),
          ],
        ],
      ),
      PluginDiscoveryGroupLayout.horizontal => ScrollConfiguration(
        behavior: discoveryDragScrollBehavior(context),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children
                .map(
                  (child) => Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.discoveryComponentGap),
                    child: SizedBox(width: AppSpacing.discoveryGroupCardWidth, child: child),
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ),
      PluginDiscoveryGroupLayout.grid => LayoutBuilder(
        builder: (context, constraints) {
          final columnCount = constraints.maxWidth >= AppSpacing.compactLayoutBreakpoint ? 2 : 1;
          final width = (constraints.maxWidth - AppSpacing.discoveryComponentGap * (columnCount - 1)) / columnCount;
          return Wrap(
            spacing: AppSpacing.discoveryComponentGap,
            runSpacing: AppSpacing.discoveryComponentGap,
            children: children.map((child) => SizedBox(width: width, child: child)).toList(growable: false),
          );
        },
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
    required this.isInBookshelf,
  });

  final PluginDiscoveryContentCollectionComponent component;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final ValueChanged<PluginDiscoveryContentCollectionComponent> onLoadMore;
  final bool isLoading;
  final bool Function(PluginContentSummary content) isInBookshelf;

  @override
  Widget build(BuildContext context) {
    final heroItems = component.items.map(_heroData).toList(growable: false);
    final cards = component.items
        .map(
          (item) => _DiscoveryBookCard(
            item: item,
            onPressed: () => onContentPressed(item.content),
            showRank: component.layout == PluginDiscoveryContentLayout.ranking,
            isInBookshelf: isInBookshelf(item.content),
          ),
        )
        .toList(growable: false);
    final body = switch (component.layout) {
      PluginDiscoveryContentLayout.featured => Column(
        children: <Widget>[
          if (component.items.isNotEmpty)
            DiscoveryHeroCard(data: _heroData(component.items.first), onPressed: () => onContentPressed(component.items.first.content)),
          ...cards.skip(1),
        ],
      ),
      PluginDiscoveryContentLayout.carousel => DiscoveryCarouselBooks(
        books: heroItems,
        onBookPressed: (book) {
          final index = heroItems.indexOf(book);
          if (index >= 0) onContentPressed(component.items[index].content);
        },
      ),
      PluginDiscoveryContentLayout.coverGrid => DiscoveryCoverGrid(
        items: component.items,
        onPressed: onContentPressed,
        isInBookshelf: isInBookshelf,
      ),
      PluginDiscoveryContentLayout.shelf => DiscoveryBookShelf(
        items: component.items,
        onPressed: onContentPressed,
        isInBookshelf: isInBookshelf,
      ),
      PluginDiscoveryContentLayout.compact || PluginDiscoveryContentLayout.ranking => DiscoveryCompactBookList(
        items: component.items,
        onPressed: onContentPressed,
        isInBookshelf: isInBookshelf,
        showRanks: component.layout == PluginDiscoveryContentLayout.ranking || component.items.any((item) => item.rank != null),
      ),
      PluginDiscoveryContentLayout.list => Column(children: cards),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        body,
        if (component.continuation != null) ...<Widget>[
          const SizedBox(height: AppSpacing.discoveryComponentGap),
          OutlinedButton(
            key: ValueKey<String>('runtime-discovery-load-more-${component.id}'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(AppSpacing.discoveryLoadMoreHeight),
              shape: const RoundedRectangleBorder(borderRadius: AppRadii.discoveryButton),
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
  const _CategoryCollection({required this.component, required this.onSelected});

  final PluginDiscoveryCategoryCollectionComponent component;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return DiscoveryCategoryCollection(categories: component.categories, layout: component.layout, onSelected: onSelected);
  }
}

DiscoveryHeroViewData _heroData(PluginDiscoveryContentItem item) => DiscoveryHeroViewData(
  title: item.content.title,
  category: item.content.categories.firstOrNull,
  description: item.recommendation ?? item.content.description,
  metadata: item.content.author,
  coverVariant: _coverVariant(item.content.id),
  coverBytes: item.content.coverBytes,
  remoteContentId: item.content.id,
  coverUrl: item.content.coverUrl,
  heat: item.metric == null ? null : '${item.metric!.label} ${item.metric!.value}',
);

String? _nestedPageTitle(List<PluginDiscoveryComponent> components) {
  for (final component in components) {
    final title = switch (component) {
      PluginDiscoverySectionComponent(:final title) => title,
      PluginDiscoveryGroupComponent(:final children) => _nestedPageTitle(children),
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
  const _DiscoveryBookCard({required this.item, required this.onPressed, required this.showRank, required this.isInBookshelf});

  final PluginDiscoveryContentItem item;
  final VoidCallback onPressed;
  final bool showRank;
  final bool isInBookshelf;

  @override
  Widget build(BuildContext context) {
    final content = item.content;
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final tags = <String>[...content.categories, ...content.tags].take(3).toList(growable: false);
    final description = item.recommendation ?? content.description;
    return LayoutBuilder(
      builder: (context, constraints) {
        final coverWidth = math.min(
          AppSpacing.discoveryListCoverMaxWidth,
          math.max(AppSpacing.discoveryListCoverMinWidth, constraints.maxWidth * 0.16),
        );
        final coverHeight = coverWidth * AppSpacing.discoveryListCoverAspectRatio;
        final titleStyle = theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);
        final secondaryTextStyle = theme.textTheme.bodySmall;
        final metadataStyle = theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText);
        final rowBackground = isInBookshelf ? tokens.featureSurface.withValues(alpha: 0.48) : tokens.surface;
        return Semantics(
          button: true,
          label: '查看 ${content.title}${isInBookshelf ? '，已在书架' : ''}',
          child: Material(
            color: rowBackground,
            child: InkWell(
              key: ValueKey<String>('runtime-discovery-item-${content.id}'),
              onTap: onPressed,
              child: Container(
                constraints: BoxConstraints(minHeight: coverHeight),
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: tokens.divider, width: 0.8)),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (showRank && item.rank != null) ...<Widget>[
                        Text('${item.rank}', style: titleStyle),
                        const SizedBox(width: AppSpacing.compact),
                      ],
                      DiscoveryBookCover(
                        title: content.title,
                        coverBytes: content.coverBytes,
                        remoteContentId: content.id,
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
                            Text(content.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                            const SizedBox(height: AppSpacing.unit),
                            Text(_authorAndCategory(content), maxLines: 1, overflow: TextOverflow.ellipsis, style: secondaryTextStyle),
                            if (tags.isNotEmpty) ...<Widget>[
                              const SizedBox(height: AppSpacing.unit),
                              Wrap(
                                spacing: AppSpacing.compact,
                                runSpacing: AppSpacing.unit,
                                children: tags.map((tag) => DiscoveryListTag(label: tag)).toList(growable: false),
                              ),
                            ],
                            if (description != null) ...<Widget>[
                              const SizedBox(height: AppSpacing.unit),
                              Text(description, maxLines: 2, overflow: TextOverflow.ellipsis, style: secondaryTextStyle),
                            ],
                            const Spacer(),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(_bookMetadata(content), maxLines: 1, overflow: TextOverflow.ellipsis, style: metadataStyle),
                                ),
                                if (item.metric != null) ...<Widget>[
                                  const SizedBox(width: AppSpacing.compact),
                                  Padding(
                                    padding: const EdgeInsets.only(right: AppSpacing.comfortable),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        Icon(Icons.local_fire_department_rounded, size: 16, color: tokens.notification),
                                        const SizedBox(width: AppSpacing.unit),
                                        Text('${item.metric!.value}${item.metric!.label}', style: metadataStyle),
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
          ),
        );
      },
    );
  }
}

String _authorAndCategory(PluginContentSummary content) {
  return <String>[
    if (content.author != null && content.author!.trim().isNotEmpty) content.author!,
    if (content.categories.isNotEmpty) content.categories.first,
  ].join(' · ');
}

String _bookMetadata(PluginContentSummary content) {
  final updateLabel = _attributeValue(content.attributes, 'discoveryUpdatedLabel');
  final resolvedUpdateLabel = updateLabel ?? _relativeUpdateLabel(content.updatedAt);
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

String? _attributeValue(Iterable<PluginContentAttribute> attributes, String key) {
  for (final attribute in attributes) {
    if (attribute.key == key) return attribute.value;
  }
  return null;
}

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return DiscoveryCoverVariant.values[checksum % DiscoveryCoverVariant.values.length];
}
