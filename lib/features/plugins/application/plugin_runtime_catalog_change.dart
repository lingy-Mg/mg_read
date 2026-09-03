/// 数据源目录变更通知。
///
/// 职责：为所有安装、同步、启停和开发态更新提供进程内单调刷新代次。
/// 注意：pluginIds 为 null 表示调用方无法缩小受影响的数据源范围。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

final pluginRuntimeCatalogChangeProvider = NotifierProvider<PluginRuntimeCatalogChangeController, PluginRuntimeCatalogChange>(
  PluginRuntimeCatalogChangeController.new,
);

final class PluginRuntimeCatalogChange {
  const PluginRuntimeCatalogChange._({required this.revision, required this.pluginIds});

  const PluginRuntimeCatalogChange.initial() : revision = 0, pluginIds = const <String>{};

  final int revision;
  final Set<String>? pluginIds;

  bool affects(String pluginId) => pluginIds == null || pluginIds!.contains(pluginId);
}

final class PluginRuntimeCatalogChangeController extends Notifier<PluginRuntimeCatalogChange> {
  @override
  PluginRuntimeCatalogChange build() => const PluginRuntimeCatalogChange.initial();

  void publish({Iterable<String>? pluginIds}) {
    final normalized = pluginIds == null ? null : Set<String>.unmodifiable(pluginIds);
    if (normalized != null && normalized.isEmpty) return;
    state = PluginRuntimeCatalogChange._(revision: state.revision + 1, pluginIds: normalized);
  }
}
