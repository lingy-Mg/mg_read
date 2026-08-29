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
/// TODO:
/// - 无。
library;

import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';

import 'data_source_management_row.dart';

List<DataSourceManagementRowData> pluginManagementSourcesFromConnection(PluginRuntimeConnection connection) {
  return connection.plugins
      .where((PluginRuntimePlugin plugin) => plugin.contentKinds.contains('novel') || plugin.contentKinds.contains('manga'))
      .map(
        (PluginRuntimePlugin plugin) => DataSourceManagementRowData(
          id: plugin.id,
          name: plugin.displayName,
          description: SourceBranding.description(sourceId: plugin.id, displayName: plugin.displayName, value: plugin.description),
          kindLabel: _sourceMetadataLabel(plugin),
          enabled: plugin.enabled,
          brand: dataSourceBrandFor(plugin.displayName),
          isDevelopment: plugin.status == 'development',
          iconUrl: plugin.iconUrl,
        ),
      )
      .toList(growable: false);
}

String _contentKindLabel(List<String> contentKinds) {
  final labels = <String>[if (contentKinds.contains('novel')) '小说', if (contentKinds.contains('manga')) '漫画'];
  return labels.isEmpty ? '数据源' : labels.join(' · ');
}

String _sourceMetadataLabel(PluginRuntimePlugin plugin) {
  final kindLabel = _contentKindLabel(plugin.contentKinds);
  if (plugin.status == 'development') return '$kindLabel · 开发数据源插件（即时生效）';
  final String? origin = switch (plugin.displayName) {
    '起点中文网' || '番茄小说' || '七猫中文网' || '纵横中文网' => '官方源',
    '晋江文学城' || '17K小说网' || '17K 小说网' => '社区源',
    _ => null,
  };
  return origin == null ? kindLabel : '$kindLabel · $origin';
}
