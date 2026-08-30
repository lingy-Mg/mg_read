/// 视频发现集合组件。
///
/// 职责：
/// - 以 16:9 横版缩略图渲染视频网格、横向栏和紧凑列表。
/// - 统一视频的播放提示、指标、书架状态、点击和拖动行为。
///
/// 注意：
/// - 本文件只接受 `contentKind=video` 的内容；小说、漫画与音频使用纵向封面组件。
/// - 来源只声明语义布局，列数、尺寸、颜色和断点继续由宿主持有。
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_bookshelf_badge.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_drag_scroll_behavior.dart';

class DiscoveryVideoGrid extends StatelessWidget {
  const DiscoveryVideoGrid({required this.items, required this.onPressed, required this.isInBookshelf, super.key});

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
        final thumbnailHeight = width * AppSpacing.discoveryLandscapeCoverAspectRatio;
        return GridView.builder(
          key: const Key('runtime-discovery-video-grid'),
          shrinkWrap: true,
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: AppSpacing.discoverySectionContentGap,
            mainAxisExtent: thumbnailHeight + AppSpacing.discoveryCoverMetadataExtent,
          ),
          itemBuilder: (context, index) {
            final item = items[index];
            return _VideoTile(
              item: item,
              width: width,
              thumbnailHeight: thumbnailHeight,
              inBookshelf: isInBookshelf(item.content),
              onPressed: () => onPressed(item.content),
            );
          },
        );
      },
    );
  }
}

class DiscoveryVideoShelf extends StatelessWidget {
  const DiscoveryVideoShelf({required this.items, required this.onPressed, required this.isInBookshelf, super.key});

  final List<PluginDiscoveryContentItem> items;
  final ValueChanged<PluginContentSummary> onPressed;
  final bool Function(PluginContentSummary content) isInBookshelf;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    const itemWidth = 224.0;
    const thumbnailHeight = itemWidth * AppSpacing.discoveryLandscapeCoverAspectRatio;
    return SizedBox(
      key: const Key('runtime-discovery-video-shelf'),
      height: thumbnailHeight + AppSpacing.discoveryCoverMetadataExtent,
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
              child: _VideoTile(
                item: item,
                width: itemWidth,
                thumbnailHeight: thumbnailHeight,
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

class DiscoveryVideoCompactList extends StatelessWidget {
  const DiscoveryVideoCompactList({
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
    return Material(
      key: const Key('runtime-discovery-video-compact-list'),
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.discoveryPanel,
        side: BorderSide(color: tokens.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (var index = 0; index < items.length; index++) ...<Widget>[
            Builder(
              builder: (context) {
                final item = items[index];
                final content = item.content;
                final rank = item.rank ?? index + 1;
                final rankColor = rank <= 3 ? tokens.notification : tokens.mutedText;
                return Semantics(
                  button: true,
                  label: '${showRanks ? '第 $rank 名，' : ''}播放 ${content.title}',
                  child: InkWell(
                    key: ValueKey<String>('runtime-discovery-video-compact-${content.id}'),
                    onTap: () => onPressed(content),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: AppSpacing.discoveryCompactRowMinHeight),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.discoveryPanelPadding, vertical: AppSpacing.compact),
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
                            Icon(Icons.play_circle_fill_rounded, size: 24, color: tokens.accent),
                            const SizedBox(width: AppSpacing.compact),
                            Expanded(
                              child: Text(content.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
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
                  ),
                );
              },
            ),
            if (index != items.length - 1) Divider(height: 1, indent: showRanks ? 80 : 56, color: tokens.divider),
          ],
        ],
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({
    required this.item,
    required this.width,
    required this.thumbnailHeight,
    required this.inBookshelf,
    required this.onPressed,
  });

  final PluginDiscoveryContentItem item;
  final double width;
  final double thumbnailHeight;
  final bool inBookshelf;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final content = item.content;
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final metadata = content.categories.isEmpty ? '视频' : content.categories.first;
    return Semantics(
      button: true,
      label: '播放 ${content.title}${inBookshelf ? '，已在书架' : ''}',
      child: InkWell(
        key: ValueKey<String>('runtime-discovery-video-${content.id}'),
        onTap: onPressed,
        borderRadius: AppRadii.discoveryTile,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: width,
              height: thumbnailHeight,
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
                    height: thumbnailHeight,
                  ),
                  Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.56), shape: BoxShape.circle),
                      child: const Padding(
                        padding: EdgeInsets.all(7),
                        child: Icon(Icons.play_arrow_rounded, size: 20, color: Colors.white),
                      ),
                    ),
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
            const SizedBox(height: 2),
            Row(
              children: <Widget>[
                Icon(Icons.movie_rounded, size: 14, color: tokens.accent),
                const SizedBox(width: AppSpacing.unit),
                Expanded(
                  child: Text(
                    metadata,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (sum, value) => sum + value);
  return DiscoveryCoverVariant.values[checksum % DiscoveryCoverVariant.values.length];
}
