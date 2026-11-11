/// 数据源安装流程：选择方式、预览覆盖、执行安装与统一结果反馈。
/// IO 通过应用层端口执行；异步返回需检查页面生命周期，TV 完成后恢复添加入口焦点。
part of 'plugin_runtime_status_page.dart';

extension _DataSourceImportFlow on _DataSourceContentState {
  Future<void> _importDataSource() async {
    final choice = await showDataSourceImportSheet(context);
    if (!mounted ||
        choice == null ||
        ref.read(pluginRuntimeSourceImportProvider).isImporting ||
        ref.read(pluginRuntimeSourceActionProvider).isNotEmpty) {
      return;
    }
    try {
      final useOnlineRepository = choice == DataSourceImportChoice.onlineRepository;
      if (choice == DataSourceImportChoice.collection || useOnlineRepository) {
        if (!supportsSourceCollectionImport) return;
        List<SourceCollectionCandidate>? candidates;
        final results = await ref.read(pluginRuntimeSourceImportProvider.notifier).importSourceCollection(() async {
          final collection = useOnlineRepository
              ? await ref.read(onlineSourceCatalogServiceProvider).loadCatalog()
              : await ref.read(sourceCollectionImportServiceProvider).pickCollection();
          if (collection == null || !mounted) return null;
          final plan = await ref.read(sourcePluginTransferGatewayProvider).plan(<PluginTransferArtifact>[
            for (final item in collection.plugins) item.artifact,
          ]);
          final connection = await ref.read(pluginRuntimeConnectionProvider.future);
          candidates = planSourceCollection(collection: collection, plan: plan, installed: connection.plugins);
          if (!mounted) return null;
          final selection = await showSourceCollectionImportSheet(context, candidates!, onlineRepository: useOnlineRepository);
          if (selection == null || !mounted) return null;
          return ref
              .read(sourcePluginTransferGatewayProvider)
              .importArtifacts(selection.artifacts, forceUpgradePluginIds: selection.forceUpgradePluginIds);
        }, initialMessage: useOnlineRepository ? '正在读取在线插件仓库' : '正在准备数据源合集');
        if (!mounted || results == null) return;
        await showSourceCollectionImportResults(
          context,
          results,
          candidates ?? const <SourceCollectionCandidate>[],
          onlineRepository: useOnlineRepository,
        );
      } else {
        final imported = await ref
            .read(pluginRuntimeSourceImportProvider.notifier)
            .importLocalPlugin(native: choice == DataSourceImportChoice.native);
        if (!mounted || !imported) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源已添加。')));
      }
    } on Object catch (error) {
      if (!mounted) return;
      if (choice == DataSourceImportChoice.collection || choice == DataSourceImportChoice.onlineRepository) {
        await showSourceManagementDialog<void>(
          context: context,
          builder: (dialogContext) => SourceManagementDialog(
            title: Text(choice == DataSourceImportChoice.onlineRepository ? '在线插件仓库无法使用' : '数据源合集无法导入'),
            content: SelectableText(
              error is SourceCollectionImportException
                  ? error.message
                  : choice == DataSourceImportChoice.onlineRepository
                  ? 'Runtime 未能完成在线数据源安装，请稍后重试。'
                  : 'Runtime 未能完成合集批量安装，请稍后重试。',
            ),
            actions: <Widget>[TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('知道了'))],
          ),
        );
      } else {
        await showPluginImportErrorDialog(context, error);
      }
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && TvModeScope.isEnabled(context) && ModalRoute.of(context)?.isCurrent != false) requestTvFocus(_addFocus);
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }
}
