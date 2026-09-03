import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';
import 'package:mg_read/shared/presentation/source_branding.dart';

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
                title: '查看数据源',
                onBack: onBackRequested,
              ),
              Expanded(
                child: connection.when(
                  loading: () => const AppLoadingState(label: '正在加载数据源详情', message: '正在读取数据源信息。'),
                  error: (Object _, StackTrace _) => _DetailFailure(onRetry: () => ref.invalidate(pluginRuntimeConnectionProvider)),
                  data: (PluginRuntimeConnection value) {
                    final source = value.plugins.where((plugin) => plugin.id == pluginId).firstOrNull;
                    if (source == null) {
                      return _DetailFailure(onRetry: () => ref.invalidate(pluginRuntimeConnectionProvider), message: '该数据源已不存在或暂时不可用。');
                    }
                    return _DetailContent(source: source, onVerificationRequested: onVerificationRequested);
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
  const _DetailContent({required this.source, required this.onVerificationRequested});

  final PluginRuntimePlugin source;
  final ValueChanged<String>? onVerificationRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppThemeTokens.of(context);
    final isDevelopment = source.status == 'development';
    final isWindows = Platform.isWindows;
    final isDesktop = isWindows || Platform.isMacOS;
    final dataUsage = isDevelopment ? null : ref.watch(pluginRuntimeSourceDataSizeProvider(source.id));
    final archiveUsage = isDevelopment ? null : ref.watch(pluginRuntimeSourceArchiveSizeProvider(source.id));
    final npmUsage = isDevelopment ? null : ref.watch(pluginRuntimeSourceNpmSizeProvider(source.id));
    final opening = ref.watch(pluginRuntimeSourceDirectoryProvider).contains(source.id);
    final packaging = ref.watch(pluginRuntimeDevelopmentPackageProvider).contains(source.id);
    final removing = ref.watch(pluginRuntimeSourceActionProvider).contains(source.id);
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
                      sourceId: source.id,
                      displayName: source.displayName,
                      iconUrl: source.iconUrl,
                      size: AppSpacing.dataSourceMarkExtent,
                      borderRadius: 12,
                    ),
                    const SizedBox(width: AppSpacing.regular),
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
                const SizedBox(height: AppSpacing.comfortable),
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
                const SizedBox(height: AppSpacing.compact),
                _DetailField(label: '名称', value: source.displayName),
                _DetailField(label: '来源方式', value: isDevelopment ? '工作区开发数据源插件' : 'Runtime 已安装数据源插件'),
                _DetailField(label: '类型', value: _contentKinds(source)),
                _DetailField(label: '版本', value: source.activeVersion ?? '等待激活'),
                _DetailField(label: '状态', value: _statusLabel(source)),
                _DetailField(label: '标识', value: source.id, isLast: true),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.comfortable),
        if (!isDevelopment) _InstallationSizeCard(archiveUsage: archiveUsage!, dataUsage: dataUsage!, npmUsage: npmUsage!),
        if (!isDevelopment) const SizedBox(height: AppSpacing.comfortable),
        _VerifySourceButton(
          onPressed: source.enabled && source.activeVersion != null && onVerificationRequested != null
              ? () => onVerificationRequested!(source.id)
              : null,
        ),
        const SizedBox(height: AppSpacing.regular),
        if (isDevelopment && isWindows) ...<Widget>[
          _PackageDevelopmentButton(
            isPackaging: packaging,
            onPressed: packaging ? null : () => _packageDevelopmentSource(context, ref, source),
          ),
          const SizedBox(height: AppSpacing.regular),
        ],
        if (isDesktop)
          _OpenDirectoryButton(
            isDevelopment: isDevelopment,
            isOpening: opening,
            onPressed: opening ? null : () => _openDirectory(context, ref, source, isDevelopment),
          )
        else
          Text('仅桌面端可打开数据源插件代码文件夹。', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
        if (!isDevelopment) ...<Widget>[
          const SizedBox(height: AppSpacing.comfortable),
          _RemoveSourceButton(isRemoving: removing, onPressed: removing ? null : () => _scheduleUninstall(context, ref, source)),
        ],
      ],
    );
  }

  Future<void> _packageDevelopmentSource(BuildContext context, WidgetRef ref, PluginRuntimePlugin source) async {
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
    try {
      final kind = await ref.read(pluginRuntimeSourceDirectoryProvider.notifier).open(pluginId: source.id);
      if (!context.mounted) return;
      final message = switch (kind) {
        PluginCodeDirectoryKind.development => '已打开开发项目文件夹。代码变更会在下一次数据源调用时生效。',
        PluginCodeDirectoryKind.installed => '已打开已安装版本文件夹。该副本不会作为开发数据源插件即时生效。',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      if (!context.mounted) return;
      final message = isDevelopment ? '开发项目文件夹打开失败。' : '已安装版本文件夹打开失败。';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _scheduleUninstall(BuildContext context, WidgetRef ref, PluginRuntimePlugin source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除数据源？'),
        content: Text('将删除“${source.displayName}”及其 Runtime 私有数据。为保证当前运行环境稳定，完全退出并重新打开应用后才会生效。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(
            key: const Key('data-source-detail-remove-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(pluginRuntimeSourceActionProvider.notifier).scheduleUninstall(pluginId: source.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源已安排删除，完全退出并重新打开应用后生效。')));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源删除安排失败，请稍后重试。')));
    }
  }
}

class _VerifySourceButton extends StatelessWidget {
  const _VerifySourceButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    key: const Key('data-source-detail-verify'),
    onPressed: onPressed,
    icon: const Icon(Icons.fact_check_outlined),
    label: const Text('检测搜索、发现与阅读链路'),
  );
}

class _RemoveSourceButton extends StatelessWidget {
  const _RemoveSourceButton({required this.isRemoving, required this.onPressed});

  final bool isRemoving;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: const Key('data-source-detail-remove'),
        onPressed: onPressed,
        icon: isRemoving
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.delete_outline),
        label: Text(isRemoving ? '正在安排删除' : '删除数据源'),
        style: OutlinedButton.styleFrom(foregroundColor: tokens.notification),
      ),
    );
  }
}

class _InstallationSizeCard extends StatelessWidget {
  const _InstallationSizeCard({required this.archiveUsage, required this.dataUsage, required this.npmUsage});

  final AsyncValue<PluginInstallationSize> archiveUsage;
  final AsyncValue<PluginInstallationSize> dataUsage;
  final AsyncValue<PluginInstallationSize> npmUsage;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final archiveResult = archiveUsage is AsyncData<PluginInstallationSize>
        ? (archiveUsage as AsyncData<PluginInstallationSize>).value
        : null;
    final dataResult = dataUsage is AsyncData<PluginInstallationSize> ? (dataUsage as AsyncData<PluginInstallationSize>).value : null;
    final npmResult = npmUsage is AsyncData<PluginInstallationSize> ? (npmUsage as AsyncData<PluginInstallationSize>).value : null;
    final total = archiveResult == null || dataResult == null || npmResult == null
        ? null
        : archiveResult.bytes + dataResult.bytes + npmResult.bytes;
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
            _InstallationSizeRow(label: 'npm 包', usage: npmUsage, slowHint: true),
          ],
        ),
      ),
    );
  }
}

class _InstallationSizeRow extends StatelessWidget {
  const _InstallationSizeRow({required this.label, required this.usage, this.slowHint = false});

  final String label;
  final AsyncValue<PluginInstallationSize> usage;
  final bool slowHint;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final value = usage.when(
      data: (PluginInstallationSize result) => '${_formatInstallationBytes(result.bytes)}（${result.fileCount} 个文件）',
      error: (Object _, StackTrace _) => '统计失败',
      loading: () => slowHint ? '统计中（文件较多）…' : '统计中…',
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
  const _DetailField({required this.label, required this.value, this.isLast = false});

  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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

String _formatInstallationBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class _OpenDirectoryButton extends StatelessWidget {
  const _OpenDirectoryButton({required this.isDevelopment, required this.isOpening, required this.onPressed});

  final bool isDevelopment;
  final bool isOpening;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    key: const Key('data-source-detail-open-directory'),
    onPressed: onPressed,
    icon: isOpening
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.folder_open_outlined),
    label: Text(
      isOpening
          ? '正在打开…'
          : isDevelopment
          ? '打开开发项目文件夹'
          : '打开已安装源码文件夹',
    ),
  );
}

class _PackageDevelopmentButton extends StatelessWidget {
  const _PackageDevelopmentButton({required this.isPackaging, required this.onPressed});

  final bool isPackaging;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const Key('data-source-detail-package-development'),
    onPressed: onPressed,
    icon: isPackaging
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.inventory_2_outlined),
    label: Text(isPackaging ? '正在打包…' : '打包数据源插件'),
  );
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

String _contentKinds(PluginRuntimePlugin source) =>
    <String>[if (source.contentKinds.contains('novel')) '小说', if (source.contentKinds.contains('manga')) '漫画'].join(' · ');

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
