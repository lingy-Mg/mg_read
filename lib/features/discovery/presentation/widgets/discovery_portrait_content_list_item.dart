/// 通用竖向与方形封面列表项。
///
/// 职责：
/// - 复用统一的纵向封面列表骨架，并按媒介类型解释来源已有的元数据。
/// - 保持发现页与搜索页的间距、标签、书架状态和点击语义一致。
///
/// 注意：
/// - 本组件由 `coverOrientation=portrait|square` 选择；视频也可以使用竖向封面。
/// - 横向封面由独立的通用横向列表组件维护。
/// - 组件只消费 Runtime 已校验的数据，不执行封面以外的 IO。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_list_tag.dart';

class DiscoveryNovelListItem extends StatelessWidget {
  const DiscoveryNovelListItem({
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
  Widget build(BuildContext context) => _PortraitContentListItem(
    item: item,
    variant: variant,
    onPressed: onPressed,
    keyPrefix: keyPrefix,
    isInBookshelf: isInBookshelf,
    showRank: showRank,
    kind: _PortraitContentKind.novel,
  );
}

class DiscoveryMangaListItem extends StatelessWidget {
  const DiscoveryMangaListItem({
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
  Widget build(BuildContext context) => _PortraitContentListItem(
    item: item,
    variant: variant,
    onPressed: onPressed,
    keyPrefix: keyPrefix,
    isInBookshelf: isInBookshelf,
    showRank: showRank,
    kind: _PortraitContentKind.manga,
  );
}

class DiscoveryAudioListItem extends StatelessWidget {
  const DiscoveryAudioListItem({
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
  Widget build(BuildContext context) => _PortraitContentListItem(
    item: item,
    variant: variant,
    onPressed: onPressed,
    keyPrefix: keyPrefix,
    isInBookshelf: isInBookshelf,
    showRank: showRank,
    kind: _PortraitContentKind.audio,
  );
}

class DiscoveryPortraitVideoListItem extends StatelessWidget {
  const DiscoveryPortraitVideoListItem({
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
  Widget build(BuildContext context) => _PortraitContentListItem(
    item: item,
    variant: variant,
    onPressed: onPressed,
    keyPrefix: keyPrefix,
    isInBookshelf: isInBookshelf,
    showRank: showRank,
    kind: _PortraitContentKind.video,
  );
}

enum _PortraitContentKind { novel, manga, audio, video }

class _PortraitContentListItem extends StatelessWidget {
  const _PortraitContentListItem({
    required this.item,
    required this.variant,
    required this.onPressed,
    required this.keyPrefix,
    required this.isInBookshelf,
    required this.showRank,
    required this.kind,
  });

  final PluginDiscoveryContentItem item;
  final DiscoveryCoverVariant variant;
  final VoidCallback onPressed;
  final String keyPrefix;
  final bool showRank;
  final bool isInBookshelf;
  final _PortraitContentKind kind;

  @override
  Widget build(BuildContext context) {
    final content = item.content;
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final tags = <String>[...content.categories, ...content.tags].take(3).toList(growable: false);
    final description = item.recommendation ?? content.description;
    final metadataLine = _metadataLine(content, kind);
    return LayoutBuilder(
      builder: (context, constraints) {
        final coverWidth = math.min(
          AppSpacing.discoveryListCoverMaxWidth,
          math.max(AppSpacing.discoveryListCoverMinWidth, constraints.maxWidth * 0.16),
        );
        final coverHeight = content.coverOrientation == PluginCoverOrientation.square
            ? coverWidth
            : coverWidth * AppSpacing.discoveryListCoverAspectRatio;
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
                        presentation: discoveryCoverPresentation(content.coverOrientation),
                        width: coverWidth,
                        height: coverHeight,
                      ),
                      const SizedBox(width: AppSpacing.regular),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Icon(_kindIcon(kind), size: 16, color: tokens.accent),
                                const SizedBox(width: AppSpacing.unit),
                                Expanded(
                                  child: Text(content.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
                                ),
                              ],
                            ),
                            if (metadataLine.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: AppSpacing.unit),
                                child: Text(metadataLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: secondaryTextStyle),
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
                              Text(description, maxLines: 2, overflow: TextOverflow.ellipsis, style: secondaryTextStyle),
                            ],
                            const Spacer(),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    _contentMetadata(content, kind),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: metadataStyle,
                                  ),
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

String _metadataLine(PluginContentSummary content, _PortraitContentKind kind) {
  final author = content.author?.trim();
  final category = content.categories.isEmpty ? null : content.categories.first;
  return <String>[
    if (author != null && author.isNotEmpty)
      switch (kind) {
        _PortraitContentKind.audio => '主播 $author',
        _ => author,
      },
    ?category,
  ].join(' · ');
}

String _contentMetadata(PluginContentSummary content, _PortraitContentKind kind) {
  final updateLabel =
      _attributeValue(content.attributes, 'discoveryUpdatedLabel') ??
      _attributeValue(content.attributes, 'searchPreviewUpdate') ??
      _relativeUpdateLabel(content.updatedAt);
  final countLabel = content.chapterCount == null
      ? null
      : '${content.chapterCount}${switch (kind) {
          _PortraitContentKind.novel => '章',
          _PortraitContentKind.manga => '话',
          _PortraitContentKind.audio => '集',
          _PortraitContentKind.video => '集',
        }}';
  return <String>[?countLabel, _statusLabel(content.status), ?updateLabel].join(' · ');
}

IconData _kindIcon(_PortraitContentKind kind) => switch (kind) {
  _PortraitContentKind.novel => Icons.menu_book_rounded,
  _PortraitContentKind.manga => Icons.auto_stories_rounded,
  _PortraitContentKind.audio => Icons.headphones_rounded,
  _PortraitContentKind.video => Icons.image_rounded,
};

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
