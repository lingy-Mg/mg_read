/// 按封面方向与媒介元数据分发的发现内容列表项。
///
/// 职责：
/// - 先按 `coverOrientation` 选择独立的竖向或横向组件。
/// - 竖向组件再按媒介类型解释章节、话数或集数等元数据。
/// - 保持调用方只依赖统一的内容项、点击和书架状态接口。
///
/// 注意：
/// - 封面方向与媒介类型相互独立；不得再用 `contentKind` 猜测横竖组件。
/// - 横向组件是通用内容组件，不添加视频标识或播放图标。
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_landscape_content_list_item.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_portrait_content_list_item.dart';

/// Shared entry point used by discovery and source search results.
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
    if (item.content.coverOrientation == PluginCoverOrientation.landscape) {
      return DiscoveryLandscapeContentListItem(
        item: item,
        variant: variant,
        onPressed: onPressed,
        keyPrefix: keyPrefix,
        isInBookshelf: isInBookshelf,
        showRank: showRank,
      );
    }
    return switch (item.content.contentKind) {
      PluginContentKind.novel => DiscoveryNovelListItem(
        item: item,
        variant: variant,
        onPressed: onPressed,
        keyPrefix: keyPrefix,
        isInBookshelf: isInBookshelf,
        showRank: showRank,
      ),
      PluginContentKind.manga => DiscoveryMangaListItem(
        item: item,
        variant: variant,
        onPressed: onPressed,
        keyPrefix: keyPrefix,
        isInBookshelf: isInBookshelf,
        showRank: showRank,
      ),
      PluginContentKind.audio => DiscoveryAudioListItem(
        item: item,
        variant: variant,
        onPressed: onPressed,
        keyPrefix: keyPrefix,
        isInBookshelf: isInBookshelf,
        showRank: showRank,
      ),
      PluginContentKind.video => DiscoveryPortraitVideoListItem(
        item: item,
        variant: variant,
        onPressed: onPressed,
        keyPrefix: keyPrefix,
        isInBookshelf: isInBookshelf,
        showRank: showRank,
      ),
    };
  }
}
