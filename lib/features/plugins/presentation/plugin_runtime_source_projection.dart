/// 插件管理页数据源品牌投影。
///
/// 职责：
/// - 将 Runtime 插件投影为管理列表的不可变展示数据。
/// - 组合远程 icon、内置品牌回退、内容类型与来源标签。
///
/// 注意：
/// - 仅供插件管理页使用，不改变发现页的图标来源。
/// - 不发起网络请求或 Runtime 调用。
///
library;

import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';

import 'data_source_management_row.dart';
import 'plugin_content_kind_labels.dart';

List<DataSourceManagementRowData> pluginManagementSourcesFromConnection(PluginRuntimeConnection connection) {
  return connection.plugins
      .where((PluginRuntimePlugin plugin) => hasSupportedPluginContentKind(plugin.contentKinds))
      .map(
        (PluginRuntimePlugin plugin) => DataSourceManagementRowData(
          id: plugin.id,
          name: plugin.displayName,
          description: plugin.canDiscoverAndSearch
              ? _websiteDescription(plugin)
              : '${plugin.sourceStateLabel}：${plugin.sourceStateReason ?? '发现和搜索不可用，已缓存内容仍可查看。'}',
          kindLabel: plugin.canDiscoverAndSearch
              ? _sourceMetadataLabel(plugin)
              : '${_sourceMetadataLabel(plugin)} · ${plugin.sourceStateLabel}',
          enabled: plugin.enabled,
          brand: dataSourceBrandFor(plugin.displayName),
          isDevelopment: plugin.status == 'development',
          iconUrl: plugin.iconUrl,
          contentKinds: plugin.contentKinds,
          r18: plugin.r18,
          canOpen: plugin.enabled && plugin.canDiscoverAndSearch && plugin.activeVersion != null,
          sourceUrl: plugin.sourceUrl,
        ),
      )
      .toList(growable: false);
}

String _websiteDescription(PluginRuntimePlugin plugin) {
  final description = plugin.description?.trim();
  if (description != null && description.isNotEmpty) return description;
  return SourceBranding.fallbackDescription(plugin.id, displayName: plugin.displayName) ?? '暂无网站简介';
}

String _sourceMetadataLabel(PluginRuntimePlugin plugin) {
  String kindLabel = pluginContentKindsLabel(plugin.contentKinds);
  if (plugin.r18) kindLabel = '$kindLabel · R18';
  if (plugin.engine == 'native') return '$kindLabel · 原生数据源';
  if (plugin.status == 'development') return '$kindLabel · 开发数据源插件（即时生效）';
  final String? origin = switch (plugin.displayName) {
    '起点中文网' || '番茄小说' || '七猫中文网' || '纵横中文网' => '官方源',
    '晋江文学城' || '17K小说网' || '17K 小说网' => '社区源',
    _ => null,
  };
  return origin == null ? kindLabel : '$kindLabel · $origin';
}
