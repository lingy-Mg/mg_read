/// 书架详情启动契约。
///
/// 职责：
/// - 以稳定书架 ID 解析本地优先的详情摘要与目录预览。
/// - 向展示层隐藏 Content Library 持久化实现。
///
/// 注意：
/// - 启动数据只用于立即展示；书源新数据由详情页在后台刷新。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

/// Typed inputs for the shared source-detail presentation of a shelf item.
final class LibraryBookDetailLaunchData {
  const LibraryBookDetailLaunchData({
    required this.pluginId,
    required this.remoteContentId,
    required this.initialContent,
    required this.initialCatalog,
    required this.sourceName,
  });

  final String pluginId;
  final String remoteContentId;
  final PluginContentSummary initialContent;
  final PluginChaptersResult initialCatalog;
  final String sourceName;
}

/// Resolves a stable shelf ID without exposing Content Library persistence.
abstract interface class LibraryBookDetailLauncher {
  Future<LibraryBookDetailLaunchData> load(String bookId);
}

final libraryBookDetailLauncherProvider = Provider<LibraryBookDetailLauncher?>((Ref ref) => null);
