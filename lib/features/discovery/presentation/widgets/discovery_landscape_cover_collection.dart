/// 通用横向封面发现集合组件。
///
/// 职责：
/// - 以横向封面设计渲染网格和横向栏。
/// - 统一指标、书架状态、点击和拖动行为，但不解释内容媒介。
///
/// 注意：
/// - 本组件由 `coverOrientation=landscape` 选择，和小说、漫画、音频、视频类型无关。
/// - 横向封面不是播放器入口的同义词，不叠加播放图标或“视频”标识。
/// - 来源只声明封面方向；列数、尺寸、颜色和断点继续由宿主持有。
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_bookshelf_badge.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_drag_scroll_behavior.dart';

class DiscoveryLandscapeCoverGrid extends StatelessWidget {
  const DiscoveryLandscapeCoverGrid({required this.items, required this.onPressed, required this.isInBookshelf, super.key});

  final List<PluginDiscoveryContentItem> items;
  final ValueChanged<PluginContentSummary> onPressed;
  final bool Function(PluginContentSummary content) isInBookshelf;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = switch (constraints.maxWidth) {
          < 600 => 2,
          < 1040 => 3,
          < 1440 => 4,
          _ => 5,
        };
        const gap = AppSpacing.discoveryComponentGap;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        final coverHeight = width * AppSpacing.discoveryLandscapeCoverAspectRatio;
        return GridView.builder(
          key: const Key('runtime-discovery-landscape-cover-grid'),
          shrinkWrap: true,
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: AppSpacing.discoverySectionContentGap,
            mainAxisExtent: coverHeight + AppSpacing.discoveryCoverMetadataExtent,
          ),
          itemBuilder: (context, index) {
            final item = items[index];
            return _LandscapeCoverTile(
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

class DiscoveryLandscapeCoverShelf extends StatelessWidget {
  const DiscoveryLandscapeCoverShelf({required this.items, required this.onPressed, required this.isInBookshelf, super.key});

  final List<PluginDiscoveryContentItem> items;
  final ValueChanged<PluginContentSummary> onPressed;
  final bool Function(PluginContentSummary content) isInBookshelf;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    const itemWidth = 224.0;
    const coverHeight = itemWidth * AppSpacing.discoveryLandscapeCoverAspectRatio;
    return SizedBox(
      key: const Key('runtime-discovery-landscape-cover-shelf'),
      height: coverHeight + AppSpacing.discoveryCoverMetadataExtent,
      child: ScrollConfiguration(
        behavior: discoveryDragScrollBehavior(context),
        child: ListView.separated(
          primary: false,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.only(right: AppSpacing.discoveryComponentGap),
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.discoveryComponentGap),
          itemBuilder: (context, index) {
            final item = items[index];
            return SizedBox(
              width: itemWidth,
              child: _LandscapeCoverTile(
                item: item,
                width: itemWidth,
                coverHeight: coverHeight,
                inBookshelf: isInBookshelf(item.content),
                onPressed: () => onPressed(item.content),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _LandscapeCoverTile extends StatelessWidget {
  const _LandscapeCoverTile({
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
    final metadata = _metadata(content);
    return Semantics(
      button: true,
      label: '查看 ${content.title}${inBookshelf ? '，已在书架' : ''}',
      child: InkWell(
        key: ValueKey<String>('runtime-discovery-landscape-cover-${content.id}'),
        onTap: onPressed,
        borderRadius: AppRadii.discoveryTile,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: width,
              height: coverHeight,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  DiscoveryBookCover(
                    title: content.title,
                    coverBytes: content.coverBytes,
                    remoteContentId: content.id,
                    coverUrl: content.coverUrl,
                    variant: _coverVariant(content.id),
                    presentation: DiscoveryCoverPresentation.landscape,
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
            ),
            const SizedBox(height: 7),
            Text(
              content.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (metadata != null) ...<Widget>[
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
    );
  }
}

String? _metadata(PluginContentSummary content) {
  if (content.author case final author? when author.trim().isNotEmpty) return author;
  if (content.categories.isNotEmpty) return content.categories.first;
  if (content.latestChapter case final latest?) return latest.title;
  return null;
}

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (sum, value) => sum + value);
  return DiscoveryCoverVariant.values[checksum % DiscoveryCoverVariant.values.length];
}
