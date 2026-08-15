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
    required this.onRefreshRequested,
    super.key,
  });

  final PluginDiscoverResult result;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final VoidCallback onSourcePressed;
  final ValueChanged<String> onTabSelected;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<PluginContentSummary> onContentPressed;
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
  });

  final PluginDiscoverySection section;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<PluginContentSummary> onContentPressed;

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
      ),
      PluginDiscoveryLayout.list => _RuntimeListSection(
        items: section.items,
        ranked: false,
        onPressed: onContentPressed,
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
  });

  final List<PluginDiscoveryContentItem> items;
  final bool ranked;
  final ValueChanged<PluginContentSummary> onPressed;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _ExplicitEmptySection();
    return Column(
      children: <Widget>[
        for (var index = 0; index < items.length; index += 1) ...<Widget>[
          _RuntimeDiscoveryCard(
            item: items[index],
            showRank: ranked,
            onPressed: () => onPressed(items[index].content),
          ),
          if (index != items.length - 1)
            const SizedBox(height: AppSpacing.compact),
        ],
      ],
    );
  }
}

class _RuntimeDiscoveryCard extends StatelessWidget {
  const _RuntimeDiscoveryCard({
    required this.item,
    required this.onPressed,
    this.compact = false,
    this.featured = false,
    this.showRank = false,
  });

  final PluginDiscoveryContentItem item;
  final VoidCallback onPressed;
  final bool compact;
  final bool featured;
  final bool showRank;

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
              if (showRank && item.rank != null) ...<Widget>[
                CircleAvatar(
                  radius: 17,
                  backgroundColor: tokens.accentSoft,
                  child: Text('${item.rank}'),
                ),
                const SizedBox(width: AppSpacing.compact),
              ],
              DiscoveryBookCover(
                title: content.title,
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
