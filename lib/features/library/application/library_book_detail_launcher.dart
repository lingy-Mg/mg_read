/// 书架详情启动契约。
///
/// 职责：
/// - 以稳定书架 ID 解析本地优先的完整详情快照与目录预览。
/// - 向展示层隐藏 Content Library 持久化实现。
///
/// 注意：
/// - 启动数据只用于立即展示；数据源新数据由详情页在后台刷新。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

/// Typed inputs for the shared source-detail presentation of a shelf item.
final class LibraryBookDetailLaunchData {
  const LibraryBookDetailLaunchData({
    required this.pluginId,
    required this.pluginVersion,
    required this.remoteContentId,
    required this.initialDetail,
    required this.initialCatalog,
  });

  final String pluginId;
  final String pluginVersion;
  final String remoteContentId;
  final PluginContentDetail initialDetail;
  final PluginChaptersResult initialCatalog;

  PluginContentSummary get initialContent => initialDetail.summary;
  String get sourceName => initialDetail.sourceName;
}

/// Resolves a stable shelf ID without exposing Content Library persistence.
abstract interface class LibraryBookDetailLauncher {
  Future<LibraryBookDetailLaunchData> load(String bookId);
}

final libraryBookDetailLauncherProvider = Provider<LibraryBookDetailLauncher?>((Ref ref) => null);
