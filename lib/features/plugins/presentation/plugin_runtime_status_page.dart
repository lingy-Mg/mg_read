/// 数据源 Runtime 管理页面。
///
/// 职责：
/// - 展示 Runtime 数据源状态及受控管理操作。
/// - 管理列表负责筛选与启停，单源详情负责维护；内容操作作为次级入口。
///
/// 注意：
/// - 页面只调用应用层窄端口，不接触 Runtime HTTP 或资源 token。
/// - 低频工具统一收纳到更多面板；安装和卸载互斥，调试持久化仍归 Runtime 所有。
/// - TV 使用独立双栏布局；分类、查询共用本页状态，导入只展示一次进度。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focus_traversal.dart';
import 'source_management_tv.dart';
import 'package:mg_read/shared/presentation/widgets/tv_text_input_navigation.dart';
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
import 'source_update_actions.dart';

part 'data_source_management_tv.dart';
part 'data_source_management_content.dart';
part 'data_source_management_widgets.dart';
part 'data_source_management_import.dart';

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

  bool _managementBusy(WidgetRef ref) => ref.read(pluginRuntimeSourceManagementBusyProvider);

  Future<void> _openManagementTools(BuildContext context, WidgetRef ref) async {
    final action = await showSourceManagementSheet<DataSourceManagementAction>(
      context: context,
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
    await checkSourceUpdates(context, ref);
  }

  Future<void> _clearAllSources(BuildContext context, WidgetRef ref, List<DataSourceManagementRowData> sources) async {
    final installedSourceCount = sources.where((source) => !source.isDevelopment).length;
    final confirmed = await showSourceManagementDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => SourceManagementDialog(
        destructive: true,
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
                title: '数据源管理',
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
                  skipLoadingOnReload: true,
                  skipError: connection.hasValue,
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
