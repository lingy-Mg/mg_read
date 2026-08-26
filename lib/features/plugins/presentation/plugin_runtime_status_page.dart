/// 数据源 Runtime 管理页面。
///
/// 职责：
/// - 展示 Runtime 数据源状态及受控管理操作。
/// - 保持主页只承载数据来源添加、查看与启停。
///
/// 注意：
/// - 页面只调用应用层窄端口，不接触 Runtime HTTP 或资源 token。
/// - 开发工具统一收纳到问号说明页，调试持久化仍归 Runtime 所有。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

import 'data_source_management_row.dart';
import 'plugin_runtime_help_page.dart';
import 'plugin_import_error_dialog.dart';
import 'plugin_runtime_source_projection.dart';

/// Runtime-backed data-source management presentation.
class PluginRuntimeStatusPage extends ConsumerWidget {
  const PluginRuntimeStatusPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    this.onSourcePressed = _ignoreSourcePressed,
    this.onRuntimeStatusRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String> onSourcePressed;
  final VoidCallback? onRuntimeStatusRequested;

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
                title: '管理数据来源',
                onBack: onBackRequested,
                actions: <Widget>[
                  if (onRuntimeStatusRequested != null)
                    AppSecondaryPageIconButton(
                      key: const Key('data-source-runtime-status'),
                      label: 'Node 状态',
                      icon: Icons.monitor_heart_outlined,
                      onPressed: onRuntimeStatusRequested!,
                    ),
                  AppSecondaryPageIconButton(
                    key: const Key('data-source-management-help'),
                    label: '数据来源说明',
                    icon: Icons.help_outline,
                    onPressed: () =>
                        Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const PluginRuntimeHelpPage())),
                  ),
                ],
              ),
              Expanded(
                child: connection.when(
                  loading: () => const _DataSourceLoading(),
                  error: (Object _, StackTrace _) => _DataSourceFailure(onRetry: () => ref.invalidate(pluginRuntimeConnectionProvider)),
                  data: (PluginRuntimeConnection value) =>
                      _DataSourceContent(sources: pluginManagementSourcesFromConnection(value), onSourcePressed: onSourcePressed),
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
    return const AppLoadingState(label: '正在加载数据来源', message: '正在加载数据来源', progressKey: Key('data-source-management-loading'));
  }
}

class _DataSourceFailure extends StatelessWidget {
  const _DataSourceFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(key: const Key('data-source-management-retry'), onPressed: onRetry, child: const Text('数据来源暂不可用，点击重试')),
    );
  }
}

class _DataSourceContent extends ConsumerStatefulWidget {
  const _DataSourceContent({required this.sources, required this.onSourcePressed});

  final List<DataSourceManagementRowData> sources;
  final ValueChanged<String> onSourcePressed;

  @override
  ConsumerState<_DataSourceContent> createState() => _DataSourceContentState();
}

class _DataSourceContentState extends ConsumerState<_DataSourceContent> {
  Future<void> _setSourceEnabled(DataSourceManagementRowData source, bool enabled) async {
    try {
      await ref.read(pluginRuntimeSourceActionProvider.notifier).setEnabled(pluginId: source.id, enabled: enabled);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据来源状态更新失败，请稍后重试。')));
    }
  }

  Future<void> _importDataSource() async {
    try {
      final imported = await ref.read(pluginRuntimeSourceImportProvider.notifier).importLocalPlugin();
      if (!mounted || !imported) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据来源已添加。')));
    } on Object catch (error) {
      if (!mounted) return;
      await showPluginImportErrorDialog(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Set<String> pendingSourceIds = ref.watch(pluginRuntimeSourceActionProvider);
    final PluginSourceImportState importState = ref.watch(pluginRuntimeSourceImportProvider);
    final int enabledCount = widget.sources.where((DataSourceManagementRowData source) => source.enabled).length;
    return ListView(
      key: const Key('data-source-management-content'),
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.comfortable,
      ),
      children: <Widget>[
        DecoratedBox(
          key: const Key('data-source-management-card'),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: AppRadii.profileList,
            border: Border.all(color: tokens.divider),
            boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.16), blurRadius: 14, offset: const Offset(0, 5))],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.comfortable,
              AppSpacing.comfortable + AppSpacing.compact,
              AppSpacing.comfortable,
              AppSpacing.regular,
            ),
            child: Column(
              children: <Widget>[
                _DataSourceSectionHeader(enabledCount: enabledCount, sourceCount: widget.sources.length),
                const SizedBox(height: AppSpacing.compact),
                if (widget.sources.isEmpty)
                  const _DataSourceEmptyState()
                else
                  ...List<Widget>.generate(widget.sources.length, (int index) {
                    final DataSourceManagementRowData source = widget.sources[index];
                    return Column(
                      children: <Widget>[
                        DataSourceManagementRow(
                          source: source,
                          isPending: pendingSourceIds.contains(source.id),
                          onPressed: () => widget.onSourcePressed(source.id),
                          onChanged: (bool enabled) => _setSourceEnabled(source, enabled),
                        ),
                        if (index < widget.sources.length - 1)
                          Padding(
                            padding: const EdgeInsets.only(left: AppSpacing.dataSourceMarkExtent + AppSpacing.regular),
                            child: Divider(height: 1, color: tokens.divider),
                          ),
                      ],
                    );
                  }),
                const SizedBox(height: AppSpacing.comfortable),
                if (importState.isImporting) ...<Widget>[
                  _DataSourceImportProgress(state: importState),
                  if (importState.logs.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpacing.unit),
                    _DataSourceImportLog(logs: importState.logs),
                  ],
                  const SizedBox(height: AppSpacing.compact),
                ],
                _AddDataSourceButton(isImporting: importState.isImporting, onPressed: importState.isImporting ? null : _importDataSource),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

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

class _DataSourceSectionHeader extends StatelessWidget {
  const _DataSourceSectionHeader({required this.enabledCount, required this.sourceCount});

  final int enabledCount;
  final int sourceCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text('我的数据来源', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.2, letterSpacing: -0.3)),
        ),
        Text(
          '已启用 $enabledCount/$sourceCount',
          key: const Key('data-source-enabled-count'),
          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
        ),
      ],
    );
  }
}

class _DataSourceEmptyState extends StatelessWidget {
  const _DataSourceEmptyState();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: AppSpacing.dataSourceRowHeight,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '暂无已安装的数据来源',
          key: const Key('data-source-management-empty'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
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
    return Semantics(
      button: true,
      label: '添加数据来源',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('data-source-add'),
          onTap: onPressed,
          borderRadius: AppRadii.discoveryTile,
          child: SizedBox(
            width: double.infinity,
            child: Ink(
              height: AppSpacing.dataSourceAddButtonHeight,
              decoration: BoxDecoration(
                borderRadius: AppRadii.discoveryTile,
                border: Border.all(color: tokens.accentSoft),
                color: tokens.pageBackground,
              ),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (isImporting)
                      SizedBox(
                        width: AppSpacing.dataSourceAddIconSize,
                        height: AppSpacing.dataSourceAddIconSize,
                        child: CircularProgressIndicator(strokeWidth: 2, color: tokens.dataSourceAccent),
                      )
                    else
                      Icon(Icons.add_rounded, color: tokens.dataSourceAccent, size: AppSpacing.dataSourceAddIconSize),
                    const SizedBox(width: AppSpacing.compact),
                    Text(
                      isImporting ? '正在添加数据来源…' : '添加数据来源',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tokens.dataSourceAccent, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
