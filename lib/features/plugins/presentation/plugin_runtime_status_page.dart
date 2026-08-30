/// 数据源 Runtime 管理页面。
///
/// 职责：
/// - 展示 Runtime 数据源状态及受控管理操作。
/// - 保持主页只承载数据源添加、查找、筛选、查看与启停。
///
/// 注意：
/// - 页面只调用应用层窄端口，不接触 Runtime HTTP 或资源 token。
/// - 开发工具统一收纳到问号说明页，调试持久化仍归 Runtime 所有。
///
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
                title: '管理数据源',
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
                    label: '数据源说明',
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
  const _DataSourceContent({required this.sources, required this.onSourcePressed});

  final List<DataSourceManagementRowData> sources;
  final ValueChanged<String> onSourcePressed;

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
    try {
      final imported = await ref.read(pluginRuntimeSourceImportProvider.notifier).importLocalPlugin();
      if (!mounted || !imported) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源已添加。')));
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
    final String normalizedQuery = _query.trim().toLowerCase();
    final List<DataSourceManagementRowData> visibleSources = widget.sources
        .where((DataSourceManagementRowData source) {
          final bool matchesFilter = switch (_filter) {
            _DataSourceFilter.all => true,
            _DataSourceFilter.enabled => source.enabled,
            _DataSourceFilter.disabled => !source.enabled,
          };
          if (!matchesFilter) return false;
          if (normalizedQuery.isEmpty) return true;
          return '${source.name} ${source.description} ${source.kindLabel}'.toLowerCase().contains(normalizedQuery);
        })
        .toList(growable: false);
    return ListView(
      key: const Key('data-source-management-content'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.section,
      ),
      children: <Widget>[
        _DataSourceOverviewCard(
          enabledCount: enabledCount,
          sourceCount: widget.sources.length,
          importState: importState,
          onAddPressed: importState.isImporting ? null : _importDataSource,
        ),
        const SizedBox(height: AppSpacing.section),
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
        const SizedBox(height: AppSpacing.section),
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
          )
        else
          DecoratedBox(
            key: const Key('data-source-list-card'),
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: AppRadii.detailCard,
              border: Border.all(color: tokens.divider),
              boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.08), blurRadius: 14, offset: const Offset(0, 4))],
            ),
            child: ClipRRect(
              borderRadius: AppRadii.detailCard,
              child: Column(
                children: <Widget>[
                  for (int index = 0; index < visibleSources.length; index++) ...<Widget>[
                    DataSourceManagementRow(
                      source: visibleSources[index],
                      isPending: pendingSourceIds.contains(visibleSources[index].id),
                      onPressed: () => widget.onSourcePressed(visibleSources[index].id),
                      onChanged: (bool enabled) => _setSourceEnabled(visibleSources[index], enabled),
                    ),
                    if (index < visibleSources.length - 1)
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.dataSourceManagementMarkExtent + AppSpacing.comfortable * 2),
                        child: Divider(height: 1, color: tokens.divider),
                      ),
                  ],
                ],
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.comfortable),
        Text(
          '开发数据源会即时生效且不能在这里停用；点击任意数据源可查看详情。',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
        ),
      ],
    );
  }
}

enum _DataSourceFilter { all, enabled, disabled }

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
    required this.enabledCount,
    required this.sourceCount,
    required this.importState,
    required this.onAddPressed,
  });

  final int enabledCount;
  final int sourceCount;
  final PluginSourceImportState importState;
  final VoidCallback? onAddPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('data-source-management-card'),
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.dataSourceAccent.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                SizedBox.square(
                  dimension: 48,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: tokens.dataSourceAccent, borderRadius: AppRadii.detailControl),
                    child: Icon(Icons.hub_rounded, color: theme.colorScheme.onPrimary, size: 25),
                  ),
                ),
                const SizedBox(width: AppSpacing.regular),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('我的数据源', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        sourceCount == 0 ? '添加插件，扩展你的内容世界' : '集中管理已安装插件与启用范围',
                        style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                      ),
                    ],
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(color: tokens.surface, borderRadius: AppRadii.pill),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.compact),
                    child: Text(
                      '已启用 $enabledCount/$sourceCount',
                      key: const Key('data-source-enabled-count'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: enabledCount == 0 ? tokens.mutedText : tokens.dataSourceAccent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.comfortable),
            _AddDataSourceButton(isImporting: importState.isImporting, onPressed: onAddPressed),
            if (importState.isImporting) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              _DataSourceImportProgress(state: importState),
              if (importState.logs.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpacing.unit),
                _DataSourceImportLog(logs: importState.logs),
              ],
            ],
          ],
        ),
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
        hintText: '搜索名称、类型或描述',
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
        Expanded(child: Text('已安装数据源', style: theme.textTheme.titleMedium)),
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
    return SizedBox(
      height: AppSpacing.minimumTouchTarget,
      child: FilledButton.icon(
        key: const Key('data-source-add'),
        onPressed: onPressed,
        icon: isImporting
            ? SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onPrimary),
              )
            : const Icon(Icons.add_rounded, size: 21),
        label: Text(isImporting ? '正在添加数据源…' : '添加数据源'),
        style: FilledButton.styleFrom(
          backgroundColor: tokens.dataSourceAccent,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.detailControl),
        ),
      ),
    );
  }
}

String _filterLabel(_DataSourceFilter value) => switch (value) {
  _DataSourceFilter.all => '全部',
  _DataSourceFilter.enabled => '已启用',
  _DataSourceFilter.disabled => '已停用',
};
