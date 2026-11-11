/// Source details keep Runtime IO in application ports. TV metadata and commands
/// are separate remote stops; overlays restore focus to their originating page.
/// Standard-mode metadata uses aligned label/value rows without nested cards.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'source_management_tv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';

import 'plugin_content_kind_labels.dart';

part 'plugin_runtime_source_detail_tv.dart';
part 'plugin_runtime_source_detail_actions.dart';

/// 单个数据源的 Runtime 详情页面。
///
/// 职责：
/// - 展示 Runtime 数据源投影及安装大小。
/// - 为 desktop 数据源插件提供目录打开，Windows 额外提供开发目录打包。
///
/// 注意：
/// - 页面不读取项目路径、制品字节或 Runtime 内部协议。
/// - 打包和目录选择均经 application port 与 Runtime Facade 完成。
///
class PluginRuntimeSourceDetailPage extends ConsumerWidget {
  const PluginRuntimeSourceDetailPage({required this.pluginId, required this.onBackRequested, this.onVerificationRequested, super.key});

  final String pluginId;
  final VoidCallback onBackRequested;
  final ValueChanged<String>? onVerificationRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(pluginRuntimeConnectionProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                key: const Key('data-source-detail-top-bar'),
                backButtonKey: const Key('data-source-detail-back'),
                title: '数据源详情',
                onBack: onBackRequested,
              ),
              Expanded(
                child: connection.when(
                  skipLoadingOnReload: true,
                  skipError: connection.hasValue,
                  loading: () => const AppLoadingState(label: '正在加载数据源详情', message: '正在读取数据源信息。'),
                  error: (Object _, StackTrace _) => _DetailFailure(onRetry: () => ref.invalidate(pluginRuntimeConnectionProvider)),
                  data: (PluginRuntimeConnection value) {
                    final source = value.plugins.where((plugin) => plugin.id == pluginId).firstOrNull;
                    if (source == null) {
                      return _DetailFailure(onRetry: () => ref.invalidate(pluginRuntimeConnectionProvider), message: '该数据源已不存在或暂时不可用。');
                    }
                    return _DetailContent(
                      source: source,
                      onVerificationRequested: onVerificationRequested,
                      onRemoved: () {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已卸载“${source.displayName}”。')));
                        onBackRequested();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailContent extends ConsumerWidget {
  const _DetailContent({required this.source, required this.onVerificationRequested, required this.onRemoved});

  final PluginRuntimePlugin source;
  final VoidCallback onRemoved;
  final ValueChanged<String>? onVerificationRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppThemeTokens.of(context);
    final isDevelopment = source.status == 'development';
    final isWindows = Platform.isWindows;
    final isDesktop = isWindows || Platform.isMacOS;
    final dataUsage = isDevelopment ? null : ref.watch(pluginRuntimeSourceDataSizeProvider(source.id));
    final archiveUsage = isDevelopment ? null : ref.watch(pluginRuntimeSourceArchiveSizeProvider(source.id));
    final opensArchive =
        dataUsage is AsyncData<PluginInstallationSize> &&
        archiveUsage is AsyncData<PluginInstallationSize> &&
        dataUsage.value.fileCount == 0 &&
        archiveUsage.value.fileCount > 0;
    final opening = ref.watch(pluginRuntimeSourceDirectoryProvider).contains(source.id);
    final packaging = ref.watch(pluginRuntimeDevelopmentPackageProvider).contains(source.id);
    final removing = ref.watch(pluginRuntimeSourceActionProvider).isNotEmpty;
    final busy = ref.watch(pluginRuntimeSourceManagementBusyProvider) || opening || packaging;
    final enabledControl = _SourceEnabledControl(source: source, busy: busy);
    final actions = _DetailActions(
      busy: busy,
      enabledControl: enabledControl,
      isDesktop: isDesktop,
      isDevelopment: isDevelopment,
      isWindows: isWindows,
      opensArchive: opensArchive,
      opening: opening,
      packaging: packaging,
      removing: removing,
      canVerify:
          !busy &&
          isDesktop &&
          source.canDiscoverAndSearch &&
          source.enabled &&
          source.activeVersion != null &&
          onVerificationRequested != null,
      onVerify: onVerificationRequested == null
          ? null
          : () {
              if (!ref.read(pluginRuntimeSourceManagementBusyProvider)) onVerificationRequested!(source.id);
            },
      onOpenDirectory: () => _openDirectory(context, ref, source, isDevelopment),
      onPackage: () => _packageDevelopmentSource(context, ref, source),
      onRemove: () => _uninstall(context, ref, source),
    );
    if (TvModeScope.isEnabled(context)) {
      return _TvSourceDetail(source: source, dataUsage: dataUsage, archiveUsage: archiveUsage, actions: actions);
    }
    return ListView(
      key: const Key('data-source-detail-content'),
      padding: const EdgeInsets.fromLTRB(AppDetailMetrics.horizontalPadding, 0, AppDetailMetrics.horizontalPadding, AppSpacing.comfortable),
      children: <Widget>[
        DecoratedBox(
          key: const Key('data-source-detail-card'),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: AppRadii.profileList,
            border: Border.all(color: tokens.divider),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.comfortable),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    SourceIcon(
                      key: const Key('data-source-detail-icon'),
                      sourceId: source.id,
                      displayName: source.displayName,
                      iconUrl: source.iconUrl,
                      size: AppSpacing.dataSourceManagementMarkExtent,
                      borderRadius: 14,
                    ),
                    const SizedBox(width: AppSpacing.comfortable),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            source.displayName,
                            key: const Key('data-source-detail-name'),
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: AppSpacing.unit),
                          Text(
                            isDevelopment ? '开发数据源插件（即时生效）' : '已安装数据源插件',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.regular),
                enabledControl,
                const SizedBox(height: AppSpacing.regular),
                DecoratedBox(
                  key: const Key('data-source-detail-description'),
                  decoration: BoxDecoration(color: tokens.featureSurface, borderRadius: AppRadii.discoveryTile),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.regular),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('数据源简介', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: AppSpacing.unit),
                        Text(
                          SourceBranding.description(sourceId: source.id, displayName: source.displayName, value: source.description),
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText, height: 1.45),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.comfortable),
                Text('数据源信息', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.regular),
                _DetailMetadataGrid(
                  fields: <_DetailFieldData>[
                    _DetailFieldData(label: '来源网址', value: source.sourceUrl ?? '缺少', wide: true),
                    _DetailFieldData(label: '来源方式', value: isDevelopment ? '工作区开发数据源插件' : 'Runtime 已安装数据源插件'),
                    _DetailFieldData(label: '类型', value: pluginContentKindsLabel(source.contentKinds)),
                    if (source.r18) const _DetailFieldData(label: '分级', value: 'R18'),
                    _DetailFieldData(label: '版本', value: source.activeVersion ?? '等待激活', wide: true, expandable: true),
                    if (source.pendingVersion != null)
                      _DetailFieldData(label: '待生效版本', value: '${source.pendingVersion}（下次启动生效）', wide: true),
                    _DetailFieldData(label: '状态', value: source.canDiscoverAndSearch ? _statusLabel(source) : source.sourceStateLabel),
                    if (!source.canDiscoverAndSearch)
                      _DetailFieldData(label: '不可用说明', value: '${source.sourceStateReason ?? '发现和搜索不可用。'} 已缓存内容仍可查看。', wide: true),
                    _DetailFieldData(label: '标识', value: source.id, wide: true),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.comfortable),
        if (!isDevelopment) _InstallationSizeCard(archiveUsage: archiveUsage!, dataUsage: dataUsage!),
        if (!isDevelopment) const SizedBox(height: AppSpacing.comfortable),
        actions,
      ],
    );
  }

  Future<void> _packageDevelopmentSource(BuildContext context, WidgetRef ref, PluginRuntimePlugin source) async {
    if (ref.read(pluginRuntimeSourceManagementBusyProvider)) return;
    try {
      final fileName = await ref.read(pluginRuntimeDevelopmentPackageProvider.notifier).package(pluginId: source.id);
      if (!context.mounted || fileName == null) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已打包 $fileName。')));
    } on AppError catch (error) {
      if (!context.mounted) return;
      final message = error.code == AppErrorCode.conflict ? '目标目录已有相同版本的数据源插件包，请更换目录或先处理旧文件。' : '数据源插件打包失败，请检查开发项目和目标目录。';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源插件打包失败，请检查开发项目和目标目录。')));
    }
  }

  Future<void> _openDirectory(BuildContext context, WidgetRef ref, PluginRuntimePlugin source, bool isDevelopment) async {
    if (ref.read(pluginRuntimeSourceManagementBusyProvider)) return;
    try {
      final kind = await ref.read(pluginRuntimeSourceDirectoryProvider.notifier).open(pluginId: source.id);
      if (!context.mounted) return;
      final message = switch (kind) {
        PluginCodeDirectoryKind.development => '已打开开发项目文件夹。代码变更会在下一次数据源调用时生效。',
        PluginCodeDirectoryKind.installed => '已打开已安装版本文件夹。该副本不会作为开发数据源插件即时生效。',
        PluginCodeDirectoryKind.archive => '已打开原始安装包文件夹。已安装源码目录不存在，需重新安装才能恢复使用。',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      if (!context.mounted) return;
      final message = isDevelopment ? '开发项目文件夹打开失败。' : '已安装版本文件夹打开失败。';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _uninstall(BuildContext context, WidgetRef ref, PluginRuntimePlugin source) async {
    if (source.status == 'development' || ref.read(pluginRuntimeSourceManagementBusyProvider)) return;
    final confirmed = await showSourceManagementDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => SourceManagementDialog(
        destructive: true,
        title: const Text('卸载数据源？'),
        content: Text('将卸载“${source.displayName}”并删除它的运行数据、缓存和安装包。书架内容会保留。此操作无法撤销。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(
            key: const Key('data-source-detail-remove-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('确认卸载'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted || ref.read(pluginRuntimeSourceManagementBusyProvider)) return;
    try {
      await ref.read(pluginRuntimeSourceActionProvider.notifier).uninstall(pluginId: source.id);
      onRemoved();
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源卸载失败，请稍后重试。')));
    }
  }
}

class _InstallationSizeCard extends StatelessWidget {
  const _InstallationSizeCard({required this.archiveUsage, required this.dataUsage});

  final AsyncValue<PluginInstallationSize> archiveUsage;
  final AsyncValue<PluginInstallationSize> dataUsage;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final archiveResult = archiveUsage is AsyncData<PluginInstallationSize>
        ? (archiveUsage as AsyncData<PluginInstallationSize>).value
        : null;
    final dataResult = dataUsage is AsyncData<PluginInstallationSize> ? (dataUsage as AsyncData<PluginInstallationSize>).value : null;
    final total = archiveResult == null || dataResult == null ? null : archiveResult.bytes + dataResult.bytes;
    return DecoratedBox(
      key: const Key('data-source-installation-size-card'),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.profileList,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.compact),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('安装后大小', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.unit),
            Text(
              '整个数据源插件：${total == null ? '统计中…' : _formatInstallationBytes(total)}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.dataSourceAccent, fontWeight: FontWeight.w600),
            ),
            _InstallationSizeRow(label: '原始安装包', usage: archiveUsage),
            _InstallationSizeRow(label: '数据文件', usage: dataUsage),
          ],
        ),
      ),
    );
  }
}

class _InstallationSizeRow extends StatelessWidget {
  const _InstallationSizeRow({required this.label, required this.usage});

  final String label;
  final AsyncValue<PluginInstallationSize> usage;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final value = usage.when(
      data: (PluginInstallationSize result) => '${_formatInstallationBytes(result.bytes)}（${result.fileCount} 个文件）',
      error: (Object _, StackTrace _) => '统计失败',
      loading: () => '统计中…',
    );
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.regular),
      child: Row(
        children: <Widget>[
          Expanded(flex: 2, child: Text(label)),
          const SizedBox(width: AppSpacing.regular),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailField extends StatelessWidget {
  const _DetailField({required this.field, required this.width});

  final _DetailFieldData field;
  final double width;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    if (TvModeScope.isEnabled(context)) {
      return SizedBox(
        width: width,
        child: TvFocusable(
          key: field.expandable ? const Key('data-source-detail-version') : null,
          onPressed: () => _showFullValue(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(field.label, style: Theme.of(context).textTheme.titleMedium),
              Text(field.value, maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
        ),
      );
    }
    final label = Text(field.label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText));
    final value = Text(
      field.value,
      maxLines: field.expandable ? 1 : null,
      softWrap: !field.expandable,
      overflow: field.expandable ? TextOverflow.ellipsis : TextOverflow.clip,
      style: Theme.of(context).textTheme.bodyMedium,
    );
    final stacked = width < 280 || MediaQuery.textScalerOf(context).scale(1) > 1.3;
    return Material(
      color: Colors.transparent,
      child: Semantics(
        button: field.expandable,
        label: field.expandable ? '${field.label}，点击查看完整内容' : null,
        child: InkWell(
          key: field.expandable ? const Key('data-source-detail-version') : null,
          onTap: field.expandable ? () => _showFullValue(context) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!stacked) ...[SizedBox(width: 80, child: label), const SizedBox(width: AppSpacing.regular)],
                Expanded(
                  child: stacked
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            label,
                            const SizedBox(height: AppSpacing.unit),
                            value,
                          ],
                        )
                      : value,
                ),
                if (field.expandable) ...[
                  const SizedBox(width: AppSpacing.unit),
                  Icon(Icons.open_in_full, size: 14, color: tokens.mutedText),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showFullValue(BuildContext context) => showSourceManagementDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => SourceManagementDialog(
      title: Text(field.label),
      content: TvModeScope.isEnabled(context)
          ? SingleChildScrollView(child: Text(field.value, key: const Key('data-source-detail-full-version')))
          : SizedBox(
              height: 48,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    field.value,
                    key: const Key('data-source-detail-full-version'),
                    maxLines: 1,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            ),
      actions: <Widget>[TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('关闭'))],
    ),
  );
}

class _DetailFieldData {
  const _DetailFieldData({required this.label, required this.value, this.wide = false, this.expandable = false});

  final String label;
  final String value;
  final bool wide;
  final bool expandable;
}

class _DetailMetadataGrid extends StatelessWidget {
  const _DetailMetadataGrid({required this.fields});

  final List<_DetailFieldData> fields;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      if (!TvModeScope.isEnabled(context)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < fields.length; i++) ...[
              if (i > 0) Divider(height: 1, color: AppThemeTokens.of(context).divider),
              _DetailField(field: fields[i], width: constraints.maxWidth),
            ],
          ],
        );
      }
      final double gap = AppSpacing.regular;
      final double halfWidth = (constraints.maxWidth - gap) / 2;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: fields.map((_DetailFieldData field) {
          return _DetailField(field: field, width: field.wide ? constraints.maxWidth : halfWidth);
        }).toList(),
      );
    },
  );
}

String _formatInstallationBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class _DetailFailure extends StatelessWidget {
  const _DetailFailure({required this.onRetry, this.message = '数据源详情暂不可用。'});

  final VoidCallback onRetry;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(message),
        const SizedBox(height: AppSpacing.regular),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

String _statusLabel(PluginRuntimePlugin source) => switch (source.status) {
  'development' => '开发中（即时生效）',
  'active' => '已启用',
  'disabled' => '已停用',
  'pending' => '等待冷激活',
  'damaged' => '数据源不可用',
  'quarantined' => '已隔离（加载失败）',
  _ => '状态未知',
};

extension on Iterable<PluginRuntimePlugin> {
  PluginRuntimePlugin? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
