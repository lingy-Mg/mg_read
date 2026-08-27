/// 发现页组合式内容组件。
///
/// 职责：
/// - 将书源声明的封面网格、横向书架、紧凑榜单和分类布局渲染为自适应宿主 UI。
/// - 保持点击、书架状态、封面代理与无障碍语义由宿主统一控制。
///
/// 注意：
/// - 组件只消费 Runtime 已校验的数据，不执行 IO，也不接受书源颜色、尺寸或任意 UI 代码。
/// - 布局名称表达内容语义；列数、间距和主题始终由 MgRead 根据可用宽度决定。
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/discovery_semantic_icons.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_bookshelf_badge.dart';

class DiscoveryCoverGrid extends StatelessWidget {
  const DiscoveryCoverGrid({required this.items, required this.onPressed, required this.isInBookshelf, super.key});

  final List<PluginDiscoveryContentItem> items;
  final ValueChanged<PluginContentSummary> onPressed;
  final bool Function(PluginContentSummary content) isInBookshelf;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = switch (constraints.maxWidth) {
          < 600 => 3,
          < 1040 => 4,
          < 1440 => 5,
          _ => 6,
        };
        const gap = AppSpacing.regular;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        final coverHeight = width * 1.38;
        return GridView.builder(
          key: const Key('runtime-discovery-cover-grid'),
          shrinkWrap: true,
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: AppSpacing.comfortable,
            mainAxisExtent: coverHeight + 58,
          ),
          itemBuilder: (context, index) {
            final item = items[index];
            return _CoverTile(
              item: item,
              width: width,
              coverHeight: coverHeight,
              inBookshelf: isInBookshelf(item.content),
              onPressed: () => onPressed(item.content),
            );
          },
        );
      },
    );
  }
}

class DiscoveryBookShelf extends StatelessWidget {
  const DiscoveryBookShelf({required this.items, required this.onPressed, required this.isInBookshelf, super.key});

  final List<PluginDiscoveryContentItem> items;
  final ValueChanged<PluginContentSummary> onPressed;
  final bool Function(PluginContentSummary content) isInBookshelf;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const Key('runtime-discovery-book-shelf'),
      height: 224,
      child: ListView.separated(
        primary: false,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(right: AppSpacing.regular),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.regular),
        itemBuilder: (context, index) {
          final item = items[index];
          return SizedBox(
            width: 112,
            child: _CoverTile(
              item: item,
              width: 112,
              coverHeight: 154,
              inBookshelf: isInBookshelf(item.content),
              onPressed: () => onPressed(item.content),
            ),
          );
        },
      ),
    );
  }
}

class DiscoveryCompactBookList extends StatelessWidget {
  const DiscoveryCompactBookList({
    required this.items,
    required this.onPressed,
    required this.isInBookshelf,
    this.showRanks = false,
    super.key,
  });

  final List<PluginDiscoveryContentItem> items;
  final ValueChanged<PluginContentSummary> onPressed;
  final bool Function(PluginContentSummary content) isInBookshelf;
  final bool showRanks;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('runtime-discovery-compact-list'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.discoveryPanel,
        border: Border.all(color: tokens.divider),
      ),
      child: Column(
        children: <Widget>[
          for (var index = 0; index < items.length; index++) ...<Widget>[
            Builder(
              builder: (context) {
                final item = items[index];
                final content = item.content;
                final rank = item.rank ?? index + 1;
                final metadata = <String>[
                  if (content.author != null) content.author!,
                  if (content.categories.isNotEmpty) content.categories.first,
                ].join(' · ');
                final rankColor = rank <= 3 ? tokens.notification : tokens.mutedText;
                return Semantics(
                  button: true,
                  label: '${showRanks ? '第 $rank 名，' : ''}${content.title}',
                  child: InkWell(
                    key: ValueKey<String>('runtime-discovery-compact-${content.id}'),
                    onTap: () => onPressed(content),
                    borderRadius: _rowRadius(index, items.length),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: 10),
                      child: Row(
                        children: <Widget>[
                          if (showRanks) ...<Widget>[
                            SizedBox(
                              width: 24,
                              child: Text(
                                '$rank',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.titleSmall?.copyWith(color: rankColor, fontWeight: FontWeight.w800),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.compact),
                          ],
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(content.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                                if (metadata.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 2),
                                  Text(
                                    metadata,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (isInBookshelf(content)) ...<Widget>[
                            const SizedBox(width: AppSpacing.compact),
                            Icon(Icons.bookmark_added_rounded, size: 17, color: tokens.accent),
                          ],
                          if (item.metric != null) ...<Widget>[
                            const SizedBox(width: AppSpacing.compact),
                            Text(item.metric!.value, style: theme.textTheme.labelSmall?.copyWith(color: tokens.mutedText)),
                          ],
                          const SizedBox(width: AppSpacing.unit),
                          Icon(Icons.chevron_right_rounded, size: 18, color: tokens.mutedText),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            if (index != items.length - 1) Divider(height: 1, indent: showRanks ? 56 : AppSpacing.regular, color: tokens.divider),
          ],
        ],
      ),
    );
  }
}

class DiscoveryCategoryCollection extends StatelessWidget {
  const DiscoveryCategoryCollection({required this.categories, required this.layout, required this.onSelected, super.key});

  final List<PluginDiscoveryCategory> categories;
  final PluginDiscoveryCategoryLayout layout;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => switch (layout) {
    PluginDiscoveryCategoryLayout.chips => Wrap(
      key: const Key('runtime-discovery-category-chips'),
      spacing: AppSpacing.compact,
      runSpacing: AppSpacing.compact,
      children: categories
          .map(
            (category) => ActionChip(
              key: ValueKey<String>('runtime-discovery-category-${category.id}'),
              avatar: category.icon == null ? null : Icon(discoverySemanticIcon(category.icon), size: 17),
              label: Text(category.count == null ? category.title : '${category.title}  ${category.count}'),
              onPressed: () => onSelected(category.target),
              side: BorderSide(color: AppThemeTokens.of(context).divider),
            ),
          )
          .toList(growable: false),
    ),
    PluginDiscoveryCategoryLayout.grid => _CategoryGrid(categories: categories, onSelected: onSelected),
    PluginDiscoveryCategoryLayout.list => _CategoryList(categories: categories, onSelected: onSelected),
  };
}

class _CoverTile extends StatelessWidget {
  const _CoverTile({
    required this.item,
    required this.width,
    required this.coverHeight,
    required this.inBookshelf,
    required this.onPressed,
  });

  final PluginDiscoveryContentItem item;
  final double width;
  final double coverHeight;
  final bool inBookshelf;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final content = item.content;
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: '查看 ${content.title}${inBookshelf ? '，已在书架' : ''}',
      child: InkWell(
        key: ValueKey<String>('runtime-discovery-cover-${content.id}'),
        onTap: onPressed,
        borderRadius: AppRadii.discoveryTile,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Stack(
              children: <Widget>[
                DiscoveryBookCover(
                  title: content.title,
                  coverBytes: content.coverBytes,
                  remoteContentId: content.id,
                  coverUrl: content.coverUrl,
                  variant: _coverVariant(content.id),
                  width: width,
                  height: coverHeight,
                ),
                if (inBookshelf) const Positioned(top: 6, right: 6, child: DiscoveryBookshelfBadge()),
                if (item.metric != null)
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.66), borderRadius: AppRadii.pill),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        child: Text(
                          item.metric!.value,
                          style: theme.textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              content.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              content.author ?? (content.categories.isEmpty ? '来源精选' : content.categories.first),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryGrid extends StatelessWidget {
  const _CategoryGrid({required this.categories, required this.onSelected});

  final List<PluginDiscoveryCategory> categories;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth < 420
          ? 2
          : constraints.maxWidth < 760
          ? 3
          : 4;
      const gap = AppSpacing.compact;
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        key: const Key('runtime-discovery-category-grid'),
        spacing: gap,
        runSpacing: gap,
        children: categories
            .map(
              (category) => SizedBox(
                width: width,
                child: Material(
                  color: AppThemeTokens.of(context).featureSurface,
                  borderRadius: AppRadii.discoveryTile,
                  child: InkWell(
                    key: ValueKey<String>('runtime-discovery-category-${category.id}'),
                    onTap: () => onSelected(category.target),
                    borderRadius: AppRadii.discoveryTile,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.comfortable),
                      child: Row(
                        children: <Widget>[
                          Icon(discoverySemanticIcon(category.icon), size: 19, color: AppThemeTokens.of(context).accent),
                          const SizedBox(width: AppSpacing.compact),
                          Expanded(child: Text(category.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
                          if (category.count != null) Text('${category.count}', style: Theme.of(context).textTheme.labelSmall),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            )
            .toList(growable: false),
      );
    },
  );
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.categories, required this.onSelected});

  final List<PluginDiscoveryCategory> categories;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('runtime-discovery-category-list'),
    children: categories
        .map(
          (category) => ListTile(
            key: ValueKey<String>('runtime-discovery-category-${category.id}'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular),
            leading: Icon(discoverySemanticIcon(category.icon), size: 20),
            title: Text(category.title),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[if (category.count != null) Text('${category.count}'), const Icon(Icons.chevron_right_rounded)],
            ),
            onTap: () => onSelected(category.target),
          ),
        )
        .toList(growable: false),
  );
}

BorderRadius _rowRadius(int index, int length) {
  const radius = Radius.circular(12);
  return BorderRadius.only(
    topLeft: index == 0 ? radius : Radius.zero,
    topRight: index == 0 ? radius : Radius.zero,
    bottomLeft: index == length - 1 ? radius : Radius.zero,
    bottomRight: index == length - 1 ? radius : Radius.zero,
  );
}

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (sum, value) => sum + value);
  return DiscoveryCoverVariant.values[checksum % DiscoveryCoverVariant.values.length];
}
