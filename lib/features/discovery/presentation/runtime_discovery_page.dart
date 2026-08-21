import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

/// Lossless production rendering of plugin-defined discovery sections.
///
/// Every section and item returned by the typed Runtime Facade remains present.
/// Layout hints change presentation only; they never select, duplicate, or
/// discard plugin data.
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
    super.key,
  });

  final PluginDiscoverResult result;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final VoidCallback onSourcePressed;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final ValueChanged<PluginContentSummary> onAddToShelf;
  final VoidCallback onRefreshRequested;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                DiscoveryTopBar(
                  sourceName: result.sourceName,
                  onSourcePressed: onSourcePressed,
                  onSearchPressed: () =>
                      onDestinationRequested(AppNavigationDestination.search),
                  onToggleTheme: () => AppThemeModeScope.of(
                    context,
                  ).onToggleTheme(Theme.of(context).brightness),
                ),
                if (result.tabs.isNotEmpty) ...<Widget>[
                  const SizedBox(height: AppSpacing.compact),
                  _RuntimeDiscoveryTabs(
                    tabs: result.tabs,
                    selectedTabId: result.selectedTabId,
                    onSelected: (tab) => onTabSelected(tab.target),
                  ),
                ],
                const SizedBox(height: AppSpacing.compact),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    key: const Key('runtime-discovery-refresh'),
                    onPressed: onRefreshRequested,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('刷新'),
                  ),
                ),
                for (final section in result.sections) ...<Widget>[
                  _RuntimeDiscoverySection(
                    section: section,
                    onCategorySelected: onCategorySelected,
                    onContentPressed: onContentPressed,
                    onAddToShelf: onAddToShelf,
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
    );
  }
}

class _RuntimeDiscoveryTabs extends StatelessWidget {
  const _RuntimeDiscoveryTabs({
    required this.tabs,
    required this.selectedTabId,
    required this.onSelected,
  });

  final List<PluginDiscoveryTab> tabs;
  final String? selectedTabId;
  final ValueChanged<PluginDiscoveryTab> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('runtime-discovery-tabs'),
      height: AppSpacing.minimumTouchTarget,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.compact),
        itemBuilder: (context, index) {
          final tab = tabs[index];
          return ChoiceChip(
            key: ValueKey<String>('runtime-discovery-tab-${tab.id}'),
            label: Text(tab.label),
            selected: tab.id == selectedTabId,
            onSelected: (_) => onSelected(tab),
          );
        },
      ),
    );
  }
}

class _RuntimeDiscoverySection extends StatelessWidget {
  const _RuntimeDiscoverySection({
    required this.section,
    required this.onCategorySelected,
    required this.onContentPressed,
    required this.onAddToShelf,
  });

  final PluginDiscoverySection section;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<PluginContentSummary> onContentPressed;
  final ValueChanged<PluginContentSummary> onAddToShelf;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: ValueKey<String>('runtime-discovery-section-${section.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            section.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (section.subtitle != null) ...<Widget>[
          const SizedBox(height: AppSpacing.unit),
          Text(
            section.subtitle!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppThemeTokens.of(context).mutedText,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.compact),
        _sectionContent(),
      ],
    );
  }

  Widget _sectionContent() {
    return switch (section.layout) {
      PluginDiscoveryLayout.featured => _RuntimeFeaturedSection(
        items: section.items,
        onPressed: onContentPressed,
      ),
      PluginDiscoveryLayout.carousel => _RuntimeCarouselSection(
        items: section.items,
        onPressed: onContentPressed,
      ),
      PluginDiscoveryLayout.ranking => _RuntimeListSection(
        items: section.items,
        ranked: true,
        onPressed: onContentPressed,
        onAddToShelf: onAddToShelf,
      ),
      PluginDiscoveryLayout.list => _RuntimeListSection(
        items: section.items,
        ranked: false,
        onPressed: onContentPressed,
        onAddToShelf: onAddToShelf,
      ),
      PluginDiscoveryLayout.categories => _RuntimeCategorySection(
        categories: section.categories,
        onPressed: onCategorySelected,
      ),
    };
  }
}

class _RuntimeFeaturedSection extends StatelessWidget {
  const _RuntimeFeaturedSection({required this.items, required this.onPressed});

  final List<PluginDiscoveryContentItem> items;
  final ValueChanged<PluginContentSummary> onPressed;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _ExplicitEmptySection();
    return Column(
      children: <Widget>[
        for (var index = 0; index < items.length; index += 1) ...<Widget>[
          _RuntimeDiscoveryCard(
            item: items[index],
            featured: true,
            onPressed: () => onPressed(items[index].content),
          ),
          if (index != items.length - 1)
            const SizedBox(height: AppSpacing.compact),
        ],
      ],
    );
  }
}

class _RuntimeCarouselSection extends StatelessWidget {
  const _RuntimeCarouselSection({required this.items, required this.onPressed});

  final List<PluginDiscoveryContentItem> items;
  final ValueChanged<PluginContentSummary> onPressed;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _ExplicitEmptySection();
    return SizedBox(
      height: 238,
      child: ListView.separated(
        key: const Key('runtime-discovery-carousel'),
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.compact),
        itemBuilder: (context, index) => SizedBox(
          width: 278,
          child: _RuntimeDiscoveryCard(
            item: items[index],
            compact: true,
            onPressed: () => onPressed(items[index].content),
          ),
        ),
      ),
    );
  }
}

class _RuntimeListSection extends StatelessWidget {
  const _RuntimeListSection({
    required this.items,
    required this.ranked,
    required this.onPressed,
    required this.onAddToShelf,
  });

  final List<PluginDiscoveryContentItem> items;
  final bool ranked;
  final ValueChanged<PluginContentSummary> onPressed;
  final ValueChanged<PluginContentSummary> onAddToShelf;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _ExplicitEmptySection();
    return Column(
      children: <Widget>[
        for (var index = 0; index < items.length; index += 1) ...<Widget>[
          _RuntimeBookListTile(
            item: items[index],
            showRank: ranked,
            onPressed: () => onPressed(items[index].content),
            onAddToShelf: () => onAddToShelf(items[index].content),
          ),
          if (index != items.length - 1)
            Divider(height: 1, color: AppThemeTokens.of(context).divider),
        ],
      ],
    );
  }
}

/// Compact, information-first source result row matching the mobile book list.
class _RuntimeBookListTile extends StatelessWidget {
  const _RuntimeBookListTile({
    required this.item,
    required this.showRank,
    required this.onPressed,
    required this.onAddToShelf,
  });

  final PluginDiscoveryContentItem item;
  final bool showRank;
  final VoidCallback onPressed;
  final VoidCallback onAddToShelf;

  @override
  Widget build(BuildContext context) {
    final content = item.content;
    final tokens = AppThemeTokens.of(context);
    final labels = <String>{
      ...content.categories,
      ...content.tags,
    }.take(3).toList(growable: false);
    final String byline = <String>[
      if (content.author != null) content.author!,
      if (content.categories.isNotEmpty) content.categories.first,
    ].join(' · ');
    final String? update = switch ((content.latestChapter, content.updatedAt)) {
      (final chapter?, final updatedAt?) =>
        '${chapter.title} · ${_formatDateTime(updatedAt)}',
      (final chapter?, null) => chapter.title,
      (null, final updatedAt?) => _formatDateTime(updatedAt),
      (null, null) =>
        content.wordCount == null ? null : '${content.wordCount} 字',
    };

    return Material(
      color: tokens.surface,
      child: InkWell(
        key: ValueKey<String>('runtime-discovery-item-${content.id}'),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.bookListVerticalPadding,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (showRank && item.rank != null) ...<Widget>[
                SizedBox(
                  width: AppSpacing.regular,
                  child: Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.compact),
                    child: Text(
                      '${item.rank}',
                      textAlign: TextAlign.center,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge?.copyWith(color: tokens.accent),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.compact),
              ],
              DiscoveryBookCover(
                key: ValueKey<String>('runtime-discovery-cover-${content.id}'),
                title: content.title,
                coverUrl: content.coverUrl,
                variant: _coverVariant(content.id),
                width: AppSpacing.listCoverWidth,
                height: AppSpacing.listCoverHeight,
              ),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            content.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.compact),
                        SizedBox(
                          height: 30,
                          child: OutlinedButton.icon(
                            key: ValueKey<String>(
                              'runtime-discovery-add-shelf-${content.id}',
                            ),
                            onPressed: onAddToShelf,
                            icon: const Icon(Icons.add_rounded, size: 17),
                            label: const Text('加入书架'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: tokens.accent,
                              side: BorderSide(color: tokens.accent),
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.compact,
                              ),
                              textStyle: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (byline.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        byline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.mutedText,
                        ),
                      ),
                    ],
                    if (labels.isNotEmpty) ...<Widget>[
                      const SizedBox(height: AppSpacing.unit),
                      Wrap(
                        spacing: AppSpacing.unit,
                        runSpacing: AppSpacing.unit,
                        children: labels
                            .map((label) => _RuntimeMetadataTag(label: label))
                            .toList(growable: false),
                      ),
                    ],
                    if (content.description != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        content.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (update != null || item.metric != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.unit),
                      Row(
                        children: <Widget>[
                          if (update != null)
                            Expanded(
                              child: Text(
                                update,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: tokens.mutedText),
                              ),
                            ),
                          if (item.metric != null) ...<Widget>[
                            if (update != null)
                              const SizedBox(width: AppSpacing.compact),
                            Icon(
                              Icons.local_fire_department_rounded,
                              size: 14,
                              color: tokens.notification,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              '${item.metric!.value}${item.metric!.label}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: tokens.mutedText),
                            ),
                          ],
                        ],
                      ),
                    ],
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

class _RuntimeMetadataTag extends StatelessWidget {
  const _RuntimeMetadataTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.mutedSurface,
        borderRadius: AppRadii.pill,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.unit),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: tokens.mutedText,
            fontSize: 10,
          ),
        ),
      ),
    );
  }
}

class _RuntimeDiscoveryCard extends StatelessWidget {
  const _RuntimeDiscoveryCard({
    required this.item,
    required this.onPressed,
    this.compact = false,
    this.featured = false,
  });

  final PluginDiscoveryContentItem item;
  final VoidCallback onPressed;
  final bool compact;
  final bool featured;

  @override
  Widget build(BuildContext context) {
    final content = item.content;
    final tokens = AppThemeTokens.of(context);
    final facts = <String>[
      _contentKindLabel(content.contentKind),
      if (content.author != null) '作者：${content.author}',
      if (content.wordCount != null) '字数：${content.wordCount}',
      if (content.chapterCount != null) '章节：${content.chapterCount}',
      '状态：${_statusLabel(content.status)}',
      '访问：${_accessLabel(content.access)}',
    ];
    return Card(
      key: ValueKey<String>('runtime-discovery-item-${content.id}'),
      margin: EdgeInsets.zero,
      color: featured ? tokens.featureSurface : tokens.surface,
      child: InkWell(
        onTap: onPressed,
        borderRadius: AppRadii.surface,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.regular),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DiscoveryBookCover(
                title: content.title,
                coverUrl: content.coverUrl,
                variant: _coverVariant(content.id),
                width: compact ? 54 : 66,
                height: compact ? 76 : 94,
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
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: AppSpacing.unit),
                    Text(
                      '来源标识：${content.id}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                    ),
                    if (item.metric != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.unit),
                      Text('${item.metric!.label}：${item.metric!.value}'),
                    ],
                    const SizedBox(height: AppSpacing.compact),
                    Wrap(
                      spacing: AppSpacing.compact,
                      runSpacing: AppSpacing.unit,
                      children: facts.map((value) => Text(value)).toList(),
                    ),
                    if (content.updatedAt != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.unit),
                      Text('更新时间：${_formatDateTime(content.updatedAt!)}'),
                    ],
                    if (content.latestChapter != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        '最新章节：${content.latestChapter!.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (!compact &&
                        (item.recommendation != null ||
                            content.description != null)) ...<Widget>[
                      const SizedBox(height: AppSpacing.compact),
                      Text(
                        item.recommendation ?? content.description!,
                        maxLines: featured ? 3 : 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (content.url != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.unit),
                      Tooltip(
                        message: content.url.toString(),
                        child: Text(
                          'URL：${content.url}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: tokens.accent),
                        ),
                      ),
                    ],
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

class _RuntimeCategorySection extends StatelessWidget {
  const _RuntimeCategorySection({
    required this.categories,
    required this.onPressed,
  });

  final List<PluginDiscoveryCategory> categories;
  final ValueChanged<String> onPressed;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const _ExplicitEmptySection();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - AppSpacing.compact) / 2;
        return Wrap(
          spacing: AppSpacing.compact,
          runSpacing: AppSpacing.compact,
          children: <Widget>[
            for (final category in categories)
              SizedBox(
                width: width,
                child: OutlinedButton(
                  key: ValueKey<String>(
                    'runtime-discovery-category-${category.id}',
                  ),
                  onPressed: () => onPressed(category.target),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.all(AppSpacing.regular),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(category.title),
                      if (category.count != null) Text('${category.count} 本'),
                      if (category.url != null)
                        Text(
                          category.url.toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ExplicitEmptySection extends StatelessWidget {
  const _ExplicitEmptySection();

  @override
  Widget build(BuildContext context) {
    return Text(
      '插件明确返回了空分区。',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: AppThemeTokens.of(context).mutedText,
      ),
    );
  }
}

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return DiscoveryCoverVariant.values[checksum %
      DiscoveryCoverVariant.values.length];
}

String _contentKindLabel(PluginContentKind value) => switch (value) {
  PluginContentKind.novel => '小说',
  PluginContentKind.manga => '漫画',
};

String _statusLabel(PluginContentStatus value) => switch (value) {
  PluginContentStatus.ongoing => '连载中',
  PluginContentStatus.completed => '已完结',
  PluginContentStatus.hiatus => '暂停更新',
  PluginContentStatus.unknown => '未知',
};

String _accessLabel(PluginAccessKind value) => switch (value) {
  PluginAccessKind.free => '免费',
  PluginAccessKind.paid => '付费',
  PluginAccessKind.mixed => '部分付费',
  PluginAccessKind.unknown => '未知',
};

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
