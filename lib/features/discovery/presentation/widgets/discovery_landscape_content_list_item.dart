/// 通用横向封面发现列表项。
///
/// 职责：
/// - 使用横向缩略图展示任意媒介的发现与搜索结果。
/// - 保持统一颜色、间距、书架状态和无障碍语义。
///
/// 注意：
/// - 本组件只由 `coverOrientation=landscape` 选择，不按内容媒介类型选择。
/// - 横向封面不表示视频，不显示播放按钮或“视频”标识。
/// - 缺失的来源字段直接隐藏，不伪造时长、作者或热度。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_bookshelf_badge.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_list_tag.dart';

class DiscoveryLandscapeContentListItem extends StatelessWidget {
  const DiscoveryLandscapeContentListItem({
    required this.item,
    required this.variant,
    required this.onPressed,
    required this.keyPrefix,
    this.isInBookshelf = false,
    this.showRank = false,
    super.key,
  });

  final PluginDiscoveryContentItem item;
  final DiscoveryCoverVariant variant;
  final VoidCallback onPressed;
  final String keyPrefix;
  final bool showRank;
  final bool isInBookshelf;

  @override
  Widget build(BuildContext context) {
    final content = item.content;
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final description = item.recommendation ?? content.description;
    final tags = <String>[...content.categories, ...content.tags].take(2).toList(growable: false);
    final metadata = _landscapeListMetadata(content);
    return LayoutBuilder(
      builder: (context, constraints) {
        final thumbnailWidth = math.min(208.0, math.max(132.0, constraints.maxWidth * 0.34));
        final thumbnailHeight = thumbnailWidth * AppSpacing.discoveryLandscapeCoverAspectRatio;
        final rowBackground = isInBookshelf ? tokens.featureSurface.withValues(alpha: 0.48) : tokens.surface;
        return Semantics(
          button: true,
          label: '查看 ${content.title}${isInBookshelf ? '，已在书架' : ''}',
          child: Material(
            color: rowBackground,
            child: InkWell(
              key: ValueKey<String>('$keyPrefix-${content.id}'),
              onTap: onPressed,
              child: Container(
                constraints: BoxConstraints(minHeight: thumbnailHeight),
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: tokens.divider, width: 0.8)),
                ),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (showRank && item.rank != null) ...<Widget>[
                        Text('${item.rank}', style: theme.textTheme.titleMedium),
                        const SizedBox(width: AppSpacing.compact),
                      ],
                      SizedBox(
                        width: thumbnailWidth,
                        height: thumbnailHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: <Widget>[
                            DiscoveryBookCover(
                              title: content.title,
                              coverBytes: content.coverBytes,
                              remoteContentId: content.id,
                              coverUrl: content.coverUrl,
                              variant: variant,
                              presentation: DiscoveryCoverPresentation.landscape,
                              width: thumbnailWidth,
                              height: thumbnailHeight,
                            ),
                            if (isInBookshelf) const Positioned(top: 6, right: 6, child: DiscoveryBookshelfBadge()),
                            if (item.metric != null)
                              Positioned(left: 7, bottom: 6, child: _LandscapeOverlayLabel(label: item.metric!.value)),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.regular),
                      Expanded(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minHeight: thumbnailHeight),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                content.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, height: 1.25),
                              ),
                              if (tags.isNotEmpty) ...<Widget>[
                                const SizedBox(height: AppSpacing.unit),
                                Wrap(
                                  spacing: AppSpacing.compact,
                                  runSpacing: AppSpacing.unit,
                                  children: tags.map((tag) => DiscoveryListTag(label: tag)).toList(growable: false),
                                ),
                              ],
                              if (description != null && description.trim().isNotEmpty) ...<Widget>[
                                const SizedBox(height: AppSpacing.unit),
                                Text(
                                  description,
                                  maxLines: constraints.maxWidth < 520 ? 1 : 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                                ),
                              ],
                              if (metadata != null) ...<Widget>[
                                const Spacer(),
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

String? _landscapeListMetadata(PluginContentSummary content) {
  final values = <String>[
    if (content.author case final author? when author.trim().isNotEmpty) author,
    if (content.latestChapter case final latest?) latest.title,
  ];
  return values.isEmpty ? null : values.join(' · ');
}

class _LandscapeOverlayLabel extends StatelessWidget {
  const _LandscapeOverlayLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.66), borderRadius: AppRadii.pill),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
      ),
    ),
  );
}
