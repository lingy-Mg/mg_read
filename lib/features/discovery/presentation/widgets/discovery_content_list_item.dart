/// 按媒介类型分发的发现内容列表项。
///
/// 职责：
/// - 为发现页和搜索页选择小说、漫画、音频或视频专用列表组件。
/// - 保持调用方只依赖统一的内容项、点击和书架状态接口。
///
/// 注意：
/// - 视频始终进入独立横版组件；不得回退到小说纵向封面行。
/// - 媒介组件共享主题 token，但各自拥有字段解释和版式。
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_portrait_content_list_item.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_video_list_item.dart';

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
  Widget build(BuildContext context) => switch (item.content.contentKind) {
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
    PluginContentKind.video => DiscoveryVideoListItem(
      item: item,
      variant: variant,
      onPressed: onPressed,
      keyPrefix: keyPrefix,
      isInBookshelf: isInBookshelf,
      showRank: showRank,
    ),
  };
}
