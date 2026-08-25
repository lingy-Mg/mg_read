/// 数据源 Runtime 管理页面。
///
/// 职责：
/// - 展示 Runtime 数据源状态及受控管理操作。
/// - 在 Debug 构建中提供临时检查页开关和地址复制。
///
/// 注意：
/// - 页面只调用应用层窄端口，不接触 Runtime HTTP 或资源 token。
/// - Debug listener 的生命周期归 Runtime 所有，页面不持久化开关。
///
/// TODO:
/// - 无。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

import 'data_source_management_row.dart';

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
                    onPressed: () => _showHelp(context, ref),
                  ),
                ],
              ),
              Expanded(
                child: connection.when(
                  loading: () => const _DataSourceLoading(),
                  error: (Object _, StackTrace _) => _DataSourceFailure(onRetry: () => ref.invalidate(pluginRuntimeConnectionProvider)),
                  data: (PluginRuntimeConnection value) =>
                      _DataSourceContent(sources: _sourcesFromConnection(value), onSourcePressed: onSourcePressed),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showHelp(BuildContext context, WidgetRef ref) {
    final bool isWindows = kDebugMode && Platform.isWindows;
    showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('数据来源说明'),
        content: Text(
          isWindows
              ? '在这里查看已添加的数据来源，并直接启用或停用它们。\n\n开发目录必须选择“书源集合目录”，Runtime 只读取它的第一层子目录。请选 …\\plugins\\sources；不要选单个书源目录，例如 …\\plugins\\sources\\shudugu。'
              : '在这里查看已添加的数据来源，并直接启用或停用它们。',
        ),
        actions: <Widget>[
          if (isWindows)
            TextButton(
              key: const Key('data-source-add-development-directory'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_selectDevelopmentDirectory(context, ref));
              },
              child: const Text('选择书源集合目录'),
            ),
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('知道了')),
        ],
      ),
    );
  }
}

void _ignoreSourcePressed(String _) {}

Future<void> _selectDevelopmentDirectory(BuildContext context, WidgetRef ref) async {
  try {
    final selected = await ref.read(pluginRuntimeDevelopmentDirectoryProvider.notifier).selectDirectory();
    if (!context.mounted || !selected) return;
    final connection = await ref.read(pluginRuntimeConnectionProvider.future);
    if (!context.mounted) return;
    final developmentCount = connection.plugins.where((plugin) => plugin.status == 'development').length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(developmentCount > 0 ? '已识别 $developmentCount 个开发数据源，即时生效。' : '未识别开发数据源。请选择包含书源子目录的集合目录，不要选择单个书源目录。')),
    );
  } on Object {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('开发目录添加失败，请检查目录后重试。')));
  }
}

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
      await _showImportError(context, AppError.fromUnknown(error));
    }
  }

  Future<void> _openRuntimePrivateDirectory() async {
    try {
      await ref.read(pluginRuntimePrivateDirectoryProvider.notifier).open();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已打开 Runtime 私有目录。')));
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Runtime 私有目录打开失败，请稍后重试。')));
    }
  }

  Future<void> _showImportError(BuildContext context, AppError error) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('数据来源导入失败'),
        content: SelectableText('${_importErrorMessage(error.code)}\n\n错误码：${error.code.wireValue}'),
        actions: <Widget>[TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('知道了'))],
      ),
    );
  }

  String _importErrorMessage(AppErrorCode code) {
    return switch (code) {
      AppErrorCode.invalidRequest || AppErrorCode.invalidFormat => '选择的文件不是有效的 MgRead 数据来源包，请确认文件后缀为 .mgplugin，且文件没有损坏。',
      AppErrorCode.fileNameInvalid => '选择的文件名称不是 .mgplugin。请重新选择 MgRead 数据来源包。',
      AppErrorCode.fileUnavailable => '手机找不到选择的文件。请把文件复制到手机本地存储后重新选择。',
      AppErrorCode.fileUnreadable || AppErrorCode.fileReadFailed => '手机无法读取选择的文件。请检查文件权限，并把文件复制到手机本地存储后重试。',
      AppErrorCode.fileTooLarge => '数据来源包超过 32 MB，无法导入。',
      AppErrorCode.pluginInstallFailed => '文件已经读取，但数据来源安装失败。请确认这是标准 MgRead .mgplugin 包，并重新导出后再试。',
      AppErrorCode.diskFull => '手机存储空间不足，清理空间后再试。',
      AppErrorCode.runtimeStartFailed ||
      AppErrorCode.runtimeUnavailable ||
      AppErrorCode.runtimeNotReady => '数据来源运行环境启动失败。请完全退出应用后重试；如果仍失败，请提供这个错误码。',
      _ => '导入过程遇到未分类错误，请提供这个错误码以便继续定位。',
    };
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
                if (kDebugMode && Platform.isWindows) ...<Widget>[
                  const SizedBox(height: AppSpacing.regular),
                  _DevelopmentSourceDirectoryPanel(
                    isSelecting: ref.watch(pluginRuntimeDevelopmentDirectoryProvider),
                    onPressed: () => unawaited(_selectDevelopmentDirectory(context, ref)),
                  ),
                ],
                if (Platform.isWindows) ...<Widget>[
                  const SizedBox(height: AppSpacing.regular),
                  _RuntimePrivateDirectoryButton(
                    isOpening: ref.watch(pluginRuntimePrivateDirectoryProvider),
                    onPressed: _openRuntimePrivateDirectory,
                  ),
                ],
                if (kDebugMode) ...<Widget>[const SizedBox(height: AppSpacing.regular), const _RuntimeDebugHttpPanel()],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Transient Debug-only control for the Runtime-owned LAN inspector.
class _RuntimeDebugHttpPanel extends ConsumerWidget {
  const _RuntimeDebugHttpPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<PluginRuntimeDebugHttp> state = ref.watch(pluginRuntimeDebugHttpProvider);
    final PluginRuntimeDebugHttp value = switch (state) {
      AsyncData<PluginRuntimeDebugHttp>(:final value) => value,
      _ => const PluginRuntimeDebugHttp.disabled(),
    };
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('runtime-debug-http-panel'),
      decoration: BoxDecoration(
        color: tokens.mutedSurface,
        borderRadius: AppRadii.detailControl,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Material(
              color: Colors.transparent,
              child: SwitchListTile.adaptive(
                key: const Key('runtime-debug-http-toggle'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Runtime 调试页面'),
                subtitle: const Text('仅 Debug：开启后同一网络设备可无认证访问。'),
                value: value.enabled,
                onChanged: state.isLoading ? null : (bool enabled) => ref.read(pluginRuntimeDebugHttpProvider.notifier).setEnabled(enabled),
              ),
            ),
            if (state.hasError)
              Text('启动失败，请检查 Runtime 状态后重试。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.warning)),
            for (final String endpoint in value.endpoints)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.unit),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: SelectableText(
                        endpoint,
                        key: Key('runtime-debug-http-url-$endpoint'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    IconButton(
                      key: Key('runtime-debug-http-copy-$endpoint'),
                      tooltip: '复制调试地址',
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: endpoint));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('调试地址已复制。')));
                      },
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
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

class _RuntimePrivateDirectoryButton extends StatelessWidget {
  const _RuntimePrivateDirectoryButton({required this.isOpening, required this.onPressed});

  final bool isOpening;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const Key('data-source-open-runtime-directory'),
    onPressed: isOpening ? null : onPressed,
    icon: isOpening
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.folder_open_outlined),
    label: Text(isOpening ? '正在打开…' : '打开 Runtime 私有目录'),
  );
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

class _DevelopmentSourceDirectoryPanel extends StatelessWidget {
  const _DevelopmentSourceDirectoryPanel({required this.isSelecting, required this.onPressed});

  final bool isSelecting;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('data-source-development-directory-panel'),
      decoration: BoxDecoration(
        color: tokens.mutedSurface,
        borderRadius: AppRadii.detailControl,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('开发数据源', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.unit),
            Text(
              '请选择书源集合目录（例如 …\\plugins\\sources）。Runtime 只读取第一层子目录；不要选择单个书源目录。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
            ),
            const SizedBox(height: AppSpacing.compact),
            OutlinedButton.icon(
              key: const Key('data-source-add-development-directory'),
              onPressed: isSelecting ? null : onPressed,
              icon: isSelecting
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.code_rounded),
              label: Text(isSelecting ? '正在识别开发数据源…' : '选择书源集合目录'),
            ),
          ],
        ),
      ),
    );
  }
}

List<DataSourceManagementRowData> _sourcesFromConnection(PluginRuntimeConnection connection) {
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
        ),
      )
      .toList(growable: false);
}

String _contentKindLabel(List<String> contentKinds) {
  final List<String> labels = <String>[if (contentKinds.contains('novel')) '小说', if (contentKinds.contains('manga')) '漫画'];
  return labels.isEmpty ? '数据源' : labels.join(' · ');
}

String _sourceMetadataLabel(PluginRuntimePlugin plugin) {
  final String kindLabel = _contentKindLabel(plugin.contentKinds);
  if (plugin.status == 'development') return '$kindLabel · 开发源（即时生效）';
  final String? origin = switch (plugin.displayName) {
    '起点中文网' || '番茄小说' || '七猫中文网' || '纵横中文网' => '官方源',
    '晋江文学城' || '17K小说网' || '17K 小说网' => '社区源',
    _ => null,
  };
  return origin == null ? kindLabel : '$kindLabel · $origin';
}
