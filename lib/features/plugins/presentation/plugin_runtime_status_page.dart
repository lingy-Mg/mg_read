/// 数据源 Runtime 管理页面。
///
/// 职责：
/// - 展示 Runtime 数据源状态及受控管理操作。
/// - 以内容类型、用途说明和临时浏览为主；添加和启停作为次要管理操作。
///
/// 注意：
/// - 页面只调用应用层窄端口，不接触 Runtime HTTP 或资源 token。
/// - 低频工具统一收纳到更多面板；安装和卸载互斥，调试持久化仍归 Runtime 所有。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/source_collection_import.dart';
import 'package:mg_read/features/plugins/application/source_plugin_transfer_gateway.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

import 'data_source_management_row.dart';
import 'data_source_management_sheets.dart';
import 'plugin_runtime_help_page.dart';
import 'plugin_import_error_dialog.dart';
import 'plugin_runtime_source_projection.dart';
import 'source_collection_import_sheet.dart';

/// Runtime-backed data-source management presentation.
class PluginRuntimeStatusPage extends ConsumerWidget {
  const PluginRuntimeStatusPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    this.onSourcePressed = _ignoreSourcePressed,
    this.onDiscoverSource,
    this.onSearchSource,
    this.onRuntimeStatusRequested,
    this.launchSourceUrl,
    this.onVerifyAllRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String> onSourcePressed;
  final ValueChanged<String>? onDiscoverSource;
  final ValueChanged<String>? onSearchSource;
  final VoidCallback? onRuntimeStatusRequested;
  final Future<bool> Function(Uri url)? launchSourceUrl;
  final VoidCallback? onVerifyAllRequested;

  bool _managementBusy(WidgetRef ref) =>
      ref.read(pluginRuntimeSourceImportProvider).isImporting || ref.read(pluginRuntimeSourceActionProvider).isNotEmpty;

  Future<void> _openManagementTools(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<DataSourceManagementAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => Consumer(
        builder: (context, sheetRef, _) {
          final connection = sheetRef.watch(pluginRuntimeConnectionProvider).asData?.value;
          final sources = connection == null ? <DataSourceManagementRowData>[] : pluginManagementSourcesFromConnection(connection);
          final importing = sheetRef.watch(pluginRuntimeSourceImportProvider).isImporting;
          final pending = sheetRef.watch(pluginRuntimeSourceActionProvider);
          return DataSourceManagementSheet(
            canCheckUpdates: supportsSourceCollectionImport,
            canVerify: onVerifyAllRequested != null,
            canDiagnose: onRuntimeStatusRequested != null,
            canUninstall: sources.any((source) => !source.isDevelopment),
            busy: importing || pending.isNotEmpty,
          );
        },
      ),
    );
    if (!context.mounted) return;
    switch (action) {
      case DataSourceManagementAction.checkUpdates:
        if (!_managementBusy(ref)) await _checkSourceUpdates(context, ref);
      case DataSourceManagementAction.verify:
        if (!_managementBusy(ref)) onVerifyAllRequested?.call();
      case DataSourceManagementAction.diagnostics:
        onRuntimeStatusRequested?.call();
      case DataSourceManagementAction.help:
        await Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const PluginRuntimeHelpPage()));
      case DataSourceManagementAction.uninstall:
        if (_managementBusy(ref)) return;
        final current = ref.read(pluginRuntimeConnectionProvider).asData?.value;
        if (current == null) return;
        final installed = pluginManagementSourcesFromConnection(current);
        if (installed.any((source) => !source.isDevelopment)) await _clearAllSources(context, ref, installed);
      case null:
        break;
    }
  }

  Future<void> _checkSourceUpdates(BuildContext context, WidgetRef ref) async {
    if (!supportsSourceCollectionImport || _managementBusy(ref)) return;
    List<SourceCollectionCandidate>? updates;
    var failureStage = '读取在线数据源仓库';
    try {
      final results = await ref.read(pluginRuntimeSourceImportProvider.notifier).importSourceCollection(() async {
        final collection = await ref.read(onlineSourceCatalogServiceProvider).loadCatalog();
        failureStage = '检查本机已安装版本';
        final transferGateway = ref.read(sourcePluginTransferGatewayProvider);
        final plan = await transferGateway.plan(<PluginTransferArtifact>[for (final item in collection.plugins) item.artifact]);
        final connection = await ref.read(pluginRuntimeConnectionProvider.future);
        final candidates = planSourceCollection(collection: collection, plan: plan, installed: connection.plugins);
        final availableUpdates = sourceCollectionAvailableUpdates(candidates);
        updates = availableUpdates;
        if (!context.mounted) return null;
        if (availableUpdates.isEmpty) return const <PluginTransferImportResult>[];
        final confirmed = await showSourceUpdatesConfirmationDialog(context, availableUpdates);
        if (!confirmed || !context.mounted) return null;
        failureStage = '下载并覆盖更新';
        final selection = sourceCollectionSelection(availableUpdates, <String>{
          for (final candidate in availableUpdates) candidate.plugin.id,
        });
        if (selection == null) return null;
        return transferGateway.importArtifacts(selection.artifacts, forceUpgradePluginIds: selection.forceUpgradePluginIds);
      }, initialMessage: '正在检查在线数据源更新');
      if (!context.mounted || results == null || updates == null) return;
      if (updates!.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已检查，当前已安装的数据源均为最新版本。')));
        return;
      }
      await showSourceCollectionImportResults(context, results, updates!, onlineRepository: true, updating: true);
    } on Object catch (error) {
      if (!context.mounted) return;
      final message = switch (error) {
        SourceCollectionImportException() => error.message,
        PluginRuntimeException() => '失败阶段：$failureStage\n错误代码：${error.code}\n${error.message}',
        _ => '失败阶段：$failureStage\n${error.runtimeType}: $error',
      };
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('数据源更新失败'),
          content: SelectableText(message),
          actions: <Widget>[TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('知道了'))],
        ),
      );
    }
  }

  Future<void> _clearAllSources(BuildContext context, WidgetRef ref, List<DataSourceManagementRowData> sources) async {
    final installedSourceCount = sources.where((source) => !source.isDevelopment).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('卸载全部数据源？'),
        content: Text('将删除 $installedSourceCount 个已安装数据源及其运行数据、缓存和安装包。书架内容和开发数据源项目会保留。此操作无法撤销。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(
            key: const Key('data-source-clear-all-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted || _managementBusy(ref)) return;
    try {
      await ref.read(pluginRuntimeSourceActionProvider.notifier).uninstallAll(totalItems: installedSourceCount);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已卸载 $installedSourceCount 个本地数据源。')));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('卸载失败，请稍后重试。')));
    }
  }

  Future<void> _openSourceUrl(BuildContext context, DataSourceManagementRowData source) async {
    final sourceUrl = source.sourceUrl;
    if (sourceUrl == null) return;
    try {
      final uri = Uri.parse(sourceUrl);
      final opened = launchSourceUrl == null ? await launchUrl(uri, mode: LaunchMode.externalApplication) : await launchSourceUrl!(uri);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法调用系统浏览器打开来源网址。')));
      }
    } on Object {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法调用系统浏览器打开来源网址。')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PluginRuntimeConnection> connection = ref.watch(pluginRuntimeConnectionProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                headerKey: const Key('data-source-top-bar'),
                backButtonKey: const Key('profile-detail-back'),
                title: '数据源',
                onBack: onBackRequested,
                actions: <Widget>[
                  AppSecondaryPageIconButton(
                    key: const Key('data-source-more'),
                    label: '更多管理',
                    icon: Icons.more_horiz_rounded,
                    onPressed: () => _openManagementTools(context, ref),
                  ),
                ],
              ),
              Expanded(
                child: connection.when(
                  loading: () => const _DataSourceLoading(),
                  error: (Object _, StackTrace _) => _DataSourceFailure(onRetry: () => ref.invalidate(pluginRuntimeConnectionProvider)),
                  data: (PluginRuntimeConnection value) => _DataSourceContent(
                    sources: pluginManagementSourcesFromConnection(value),
                    onSourcePressed: onSourcePressed,
                    onOpenSourceUrl: (source) => _openSourceUrl(context, source),
                    onDiscoverSource: onDiscoverSource,
                    onSearchSource: onSearchSource,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _ignoreSourcePressed(String _) {}

class _DataSourceLoading extends StatelessWidget {
  const _DataSourceLoading();

  @override
  Widget build(BuildContext context) {
    return const AppLoadingState(label: '正在加载数据源', message: '正在加载数据源', progressKey: Key('data-source-management-loading'));
  }
}

class _DataSourceFailure extends StatelessWidget {
  const _DataSourceFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(key: const Key('data-source-management-retry'), onPressed: onRetry, child: const Text('数据源暂不可用，点击重试')),
    );
  }
}

class _DataSourceContent extends ConsumerStatefulWidget {
  const _DataSourceContent({
    required this.sources,
    required this.onSourcePressed,
    required this.onOpenSourceUrl,
    this.onDiscoverSource,
    this.onSearchSource,
  });

  final List<DataSourceManagementRowData> sources;
  final ValueChanged<String> onSourcePressed;
  final ValueChanged<DataSourceManagementRowData> onOpenSourceUrl;
  final ValueChanged<String>? onDiscoverSource;
  final ValueChanged<String>? onSearchSource;

  @override
  ConsumerState<_DataSourceContent> createState() => _DataSourceContentState();
}

class _DataSourceContentState extends ConsumerState<_DataSourceContent> {
  final TextEditingController _searchController = TextEditingController();
  _DataSourceFilter _filter = _DataSourceFilter.all;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _setSourceEnabled(DataSourceManagementRowData source, bool enabled) async {
    try {
      await ref.read(pluginRuntimeSourceActionProvider.notifier).setEnabled(pluginId: source.id, enabled: enabled);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源状态更新失败，请稍后重试。')));
    }
  }

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
          final plan = await ref
              .read(pluginRuntimeFacadeProvider)
              .invoke(
                PluginTransferPlanInvocation(artifacts: <PluginTransferArtifact>[for (final item in collection.plugins) item.artifact]),
              );
          final connection = await ref.read(pluginRuntimeConnectionProvider.future);
          candidates = planSourceCollection(collection: collection, plan: plan, installed: connection.plugins);
          if (!mounted) return null;
          final selection = await showSourceCollectionImportSheet(context, candidates!, onlineRepository: useOnlineRepository);
          if (selection == null || !mounted) return null;
          return ref
              .read(pluginRuntimeFacadeProvider)
              .importPluginArtifacts(selection.artifacts, forceUpgradePluginIds: selection.forceUpgradePluginIds);
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
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Set<String> pendingSourceIds = ref.watch(pluginRuntimeSourceActionProvider);
    final bool isClearingAll = pendingSourceIds.contains('__all_installed_sources__');
    final PluginSourceRemovalProgress removalProgress = ref.watch(pluginRuntimeSourceRemovalProgressProvider);
    final PluginSourceImportState importState = ref.watch(pluginRuntimeSourceImportProvider);
    final String normalizedQuery = _query.trim().toLowerCase();
    final List<DataSourceManagementRowData> visibleSources = widget.sources
        .where((DataSourceManagementRowData source) {
          final bool matchesFilter = switch (_filter) {
            _DataSourceFilter.all => true,
            _DataSourceFilter.novel => source.contentKinds.contains('novel'),
            _DataSourceFilter.manga => source.contentKinds.contains('manga'),
            _DataSourceFilter.audio => source.contentKinds.contains('audio'),
            _DataSourceFilter.video => source.contentKinds.contains('video'),
          };
          if (!matchesFilter) return false;
          if (normalizedQuery.isEmpty) return true;
          return '${source.name} ${source.description} ${source.kindLabel}'.toLowerCase().contains(normalizedQuery);
        })
        .toList(growable: false);
    return ListView.builder(
      key: const Key('data-source-management-content'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.section,
      ),
      itemCount: visibleSources.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _DataSourceOverviewCard(
                sourceCount: widget.sources.length,
                importState: importState,
                onAddPressed: importState.isImporting || pendingSourceIds.isNotEmpty ? null : _importDataSource,
                isClearingAll: isClearingAll,
                removalProgress: removalProgress,
              ),
              const SizedBox(height: AppSpacing.comfortable),
              _DataSourceSearchField(
                controller: _searchController,
                query: _query,
                onChanged: (String value) => setState(() => _query = value),
                onClear: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
              const SizedBox(height: AppSpacing.regular),
              _DataSourceFilterBar(selected: _filter, onSelected: (_DataSourceFilter value) => setState(() => _filter = value)),
              const SizedBox(height: AppSpacing.regular),
              _DataSourceListHeader(visibleCount: visibleSources.length, totalCount: widget.sources.length),
              const SizedBox(height: AppSpacing.regular),
              if (widget.sources.isEmpty)
                const _DataSourceEmptyState(message: '暂无已安装的数据源')
              else if (visibleSources.isEmpty)
                _DataSourceEmptyState(
                  message: '没有符合条件的数据源',
                  actionLabel: '清除筛选',
                  onAction: () {
                    _searchController.clear();
                    setState(() {
                      _query = '';
                      _filter = _DataSourceFilter.all;
                    });
                  },
                ),
            ],
          );
        }
        if (index == visibleSources.length + 1) {
          return Text(
            '临时浏览后可返回此列表；更多菜单中可查看详情、启用或停用数据源。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
          );
        }

        final source = visibleSources[index - 1];
        return Container(
          margin: const EdgeInsets.only(bottom: AppSpacing.regular),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: AppRadii.detailCard,
            border: Border.all(color: tokens.divider),
          ),
          child: DataSourceManagementRow(
            source: source,
            isPending: importState.isImporting || isClearingAll || pendingSourceIds.contains(source.id),
            onPressed: () => widget.onSourcePressed(source.id),
            onDiscover: widget.onDiscoverSource == null ? null : () => widget.onDiscoverSource!(source.id),
            onSearch: widget.onSearchSource == null ? null : () => widget.onSearchSource!(source.id),
            onOpenSourceUrl: source.sourceUrl == null ? null : () => widget.onOpenSourceUrl(source),
            onChanged: (enabled) => _setSourceEnabled(source, enabled),
          ),
        );
      },
    );
  }
}

enum _DataSourceFilter { all, novel, manga, audio, video }

class _DataSourceImportProgress extends StatelessWidget {
  const _DataSourceImportProgress({required this.state});

  final PluginSourceImportState state;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final double? fraction = state.fraction?.clamp(0, 1).toDouble();
    final String percent = fraction == null ? '处理中' : '${(fraction * 100).round()}%';
    return Semantics(
      liveRegion: true,
      label: '${state.message}，$percent',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  state.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.dataSourceAccent, fontWeight: FontWeight.w600),
                ),
              ),
              Text(percent, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            ],
          ),
          const SizedBox(height: AppSpacing.unit),
          LinearProgressIndicator(value: fraction, minHeight: 4, backgroundColor: tokens.mutedSurface, color: tokens.dataSourceAccent),
        ],
      ),
    );
  }
}

class _DataSourceImportLog extends StatelessWidget {
  const _DataSourceImportLog({required this.logs});

  final List<String> logs;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Container(
      key: const Key('data-source-import-log'),
      constraints: const BoxConstraints(maxHeight: 128),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact, vertical: AppSpacing.unit),
      decoration: BoxDecoration(color: tokens.mutedSurface, borderRadius: AppRadii.detailControl),
      child: ListView(
        shrinkWrap: true,
        children: logs
            .map(
              (String log) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('· $log', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
              ),
            )
            .toList(growable: false),
      ),
    );
  }
}

class _DataSourceOverviewCard extends StatelessWidget {
  const _DataSourceOverviewCard({
    required this.sourceCount,
    required this.importState,
    required this.onAddPressed,
    required this.isClearingAll,
    required this.removalProgress,
  });

  final int sourceCount;
  final PluginSourceImportState importState;
  final VoidCallback? onAddPressed;
  final bool isClearingAll;
  final PluginSourceRemovalProgress removalProgress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Container(
      key: const Key('data-source-management-card'),
      padding: const EdgeInsets.all(AppSpacing.comfortable),
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(sourceCount == 0 ? '从一个数据源开始' : '找到想看的内容', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.compact),
          Text(
            sourceCount == 0 ? '添加数据源，即可浏览发现和搜索内容。' : '$sourceCount 个数据源 · 按类型浏览，选择一个直接试用。',
            key: const Key('data-source-enabled-count'),
            style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
          ),
          const SizedBox(height: AppSpacing.unit),
          _AddDataSourceButton(isImporting: importState.isImporting, onPressed: onAddPressed),
          if (isClearingAll) ...[const SizedBox(height: AppSpacing.regular), _DataSourceRemovalProgress(progress: removalProgress)],
          if (importState.isImporting) ...[
            const SizedBox(height: AppSpacing.regular),
            _DataSourceImportProgress(state: importState),
            if (importState.logs.isNotEmpty) ...[const SizedBox(height: AppSpacing.unit), _DataSourceImportLog(logs: importState.logs)],
          ],
        ],
      ),
    );
  }
}

class _DataSourceRemovalProgress extends StatelessWidget {
  const _DataSourceRemovalProgress({required this.progress});

  final PluginSourceRemovalProgress progress;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final fraction = progress.fraction;
    final count = progress.totalItems == 0 ? '处理中' : '${progress.completedItems}/${progress.totalItems}';
    return Semantics(
      liveRegion: true,
      label: '${progress.message}，$count',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(progress.message, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
              ),
              Text(count, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            ],
          ),
          const SizedBox(height: AppSpacing.unit),
          LinearProgressIndicator(value: fraction, minHeight: 4, backgroundColor: tokens.mutedSurface, color: tokens.notification),
        ],
      ),
    );
  }
}

class _DataSourceSearchField extends StatelessWidget {
  const _DataSourceSearchField({required this.controller, required this.query, required this.onChanged, required this.onClear});

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return TextField(
      key: const Key('data-source-search'),
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: '筛选名称或用途',
        prefixIcon: const Icon(Icons.search_rounded, size: 21),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                key: const Key('data-source-search-clear'),
                tooltip: '清除搜索',
                onPressed: onClear,
                icon: const Icon(Icons.close_rounded),
              ),
        filled: true,
        fillColor: tokens.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.comfortable),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadii.detailControl,
          borderSide: BorderSide(color: tokens.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadii.detailControl,
          borderSide: BorderSide(color: tokens.dataSourceAccent, width: 1.4),
        ),
      ),
    );
  }
}

class _DataSourceFilterBar extends StatelessWidget {
  const _DataSourceFilterBar({required this.selected, required this.onSelected});

  final _DataSourceFilter selected;
  final ValueChanged<_DataSourceFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Wrap(
      key: const Key('data-source-filters'),
      spacing: AppSpacing.compact,
      children: <Widget>[
        for (final _DataSourceFilter filter in _DataSourceFilter.values)
          ChoiceChip(
            key: Key('data-source-filter-${filter.name}'),
            label: Text(_filterLabel(filter)),
            selected: selected == filter,
            showCheckmark: false,
            side: BorderSide(color: selected == filter ? tokens.dataSourceAccent.withValues(alpha: 0.26) : tokens.divider),
            selectedColor: tokens.accentSoft,
            backgroundColor: tokens.surface,
            labelStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: selected == filter ? tokens.dataSourceAccent : tokens.mutedText,
              fontWeight: selected == filter ? FontWeight.w600 : FontWeight.w400,
            ),
            onSelected: (_) => onSelected(filter),
          ),
      ],
    );
  }
}

class _DataSourceListHeader extends StatelessWidget {
  const _DataSourceListHeader({required this.visibleCount, required this.totalCount});

  final int visibleCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Row(
      children: <Widget>[
        Expanded(child: Text('我的数据源', style: theme.textTheme.titleMedium)),
        Text(
          visibleCount == totalCount ? '共 $totalCount 个' : '$visibleCount / $totalCount',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
        ),
      ],
    );
  }
}

class _DataSourceEmptyState extends StatelessWidget {
  const _DataSourceEmptyState({required this.message, this.actionLabel, this.onAction});

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('data-source-management-empty'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.section),
        child: Column(
          children: <Widget>[
            Icon(Icons.manage_search_rounded, size: 34, color: tokens.mutedText),
            const SizedBox(height: AppSpacing.compact),
            Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
            if (onAction != null && actionLabel != null) ...<Widget>[
              const SizedBox(height: AppSpacing.compact),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddDataSourceButton extends StatelessWidget {
  const _AddDataSourceButton({required this.isImporting, this.onPressed});

  final bool isImporting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.minimumTouchTarget),
      child: TextButton.icon(
        key: const Key('data-source-add'),
        onPressed: onPressed,
        icon: isImporting
            ? SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary),
              )
            : const Icon(Icons.add_rounded, size: 21),
        label: Text(isImporting ? '正在导入…' : '添加数据源'),
        style: TextButton.styleFrom(foregroundColor: tokens.dataSourceAccent, alignment: Alignment.centerLeft),
      ),
    );
  }
}

String _filterLabel(_DataSourceFilter value) => switch (value) {
  _DataSourceFilter.all => '全部',
  _DataSourceFilter.novel => '小说',
  _DataSourceFilter.manga => '漫画',
  _DataSourceFilter.audio => '音频',
  _DataSourceFilter.video => '视频',
};
