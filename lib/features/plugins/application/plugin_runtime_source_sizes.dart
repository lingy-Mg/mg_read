/// 数据源安装目录大小查询 Provider。
///
/// 职责：按数据、归档和 npm 依赖范围读取单个插件大小，并随目录代次刷新。
/// 注意：查询保持 autoDispose，离开详情页后不保留文件系统扫描结果。
part of 'plugin_runtime_connection.dart';

final pluginRuntimeSourceDataSizeProvider = FutureProvider.autoDispose.family<PluginInstallationSize, String>((Ref ref, String pluginId) {
  ref.watch(pluginRuntimeCatalogChangeProvider);
  return ref.read(pluginRuntimeGatewayProvider).inspectInstallationSize(pluginId: pluginId, scope: PluginInstallationSizeScope.data);
});

final pluginRuntimeSourceArchiveSizeProvider = FutureProvider.autoDispose.family<PluginInstallationSize, String>((
  Ref ref,
  String pluginId,
) {
  ref.watch(pluginRuntimeCatalogChangeProvider);
  return ref.read(pluginRuntimeGatewayProvider).inspectInstallationSize(pluginId: pluginId, scope: PluginInstallationSizeScope.archive);
});

final pluginRuntimeSourceNpmSizeProvider = FutureProvider.autoDispose.family<PluginInstallationSize, String>((Ref ref, String pluginId) {
  ref.watch(pluginRuntimeCatalogChangeProvider);
  return ref.read(pluginRuntimeGatewayProvider).inspectInstallationSize(pluginId: pluginId, scope: PluginInstallationSizeScope.npm);
});
