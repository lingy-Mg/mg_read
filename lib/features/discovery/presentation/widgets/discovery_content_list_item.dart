/// 发现内容列表项。
///
/// 职责：
/// - 展示发现和搜索结果中的封面、标题、标签及元数据。
/// - 通过显式回调转发列表项点击操作。
///
/// 注意：
/// - 组件只接收已完成封面 hydration 的数据，不直接访问网络或持久化。
/// - 分类列表标签的视觉规格需与运行时发现页保持一致。
///
/// TODO:
/// - 无。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_list_tag.dart';

/// Shared compact content row used by discovery and source search results.
class DiscoveryContentListItem extends StatelessWidget {
  const DiscoveryContentListItem({
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
              key: ValueKey<String>('$keyPrefix-${content.id}'),
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
                        Text('${item.rank}', style: theme.textTheme.titleMedium),
                        const SizedBox(width: AppSpacing.compact),
                      ],
                      DiscoveryBookCover(
                        title: content.title,
                        coverBytes: content.coverBytes,
                        remoteContentId: content.id,
                        coverUrl: content.coverUrl,
                        variant: variant,
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
  final updateLabel =
      _attributeValue(content.attributes, 'discoveryUpdatedLabel') ??
      _attributeValue(content.attributes, 'searchPreviewUpdate') ??
      _relativeUpdateLabel(content.updatedAt);
  return <String>[if (content.chapterCount != null) '${content.chapterCount}章', _statusLabel(content.status), ?updateLabel].join(' · ');
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
