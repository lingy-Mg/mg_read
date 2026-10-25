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

import 'plugin_content_kind_labels.dart';

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
    final opensArchive =
        dataUsage is AsyncData<PluginInstallationSize> &&
        archiveUsage is AsyncData<PluginInstallationSize> &&
        dataUsage.value.fileCount == 0 &&
        archiveUsage.value.fileCount > 0;
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
                const SizedBox(height: AppSpacing.comfortable),
                Text('数据源信息', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.regular),
                _DetailMetadataGrid(
                  fields: <_DetailFieldData>[
                    _DetailFieldData(label: '名称', value: source.displayName),
                    _DetailFieldData(label: '来源网址', value: source.sourceUrl ?? '缺少', wide: true),
                    _DetailFieldData(label: '来源方式', value: isDevelopment ? '工作区开发数据源插件' : 'Runtime 已安装数据源插件'),
                    _DetailFieldData(label: '类型', value: pluginContentKindsLabel(source.contentKinds)),
                    if (source.r18) const _DetailFieldData(label: '分级', value: 'R18'),
                    _DetailFieldData(label: '版本', value: source.activeVersion ?? '等待激活', wide: true, expandable: true),
                    _DetailFieldData(label: '状态', value: _statusLabel(source)),
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
        _DetailActions(
          isDesktop: isDesktop,
          isDevelopment: isDevelopment,
          isWindows: isWindows,
          opensArchive: opensArchive,
          opening: opening,
          packaging: packaging,
          removing: removing,
          canVerify: source.enabled && source.activeVersion != null && onVerificationRequested != null,
          onVerify: onVerificationRequested == null ? null : () => onVerificationRequested!(source.id),
          onOpenDirectory: () => _openDirectory(context, ref, source, isDevelopment),
          onPackage: () => _packageDevelopmentSource(context, ref, source),
          onRemove: () => _uninstall(context, ref, source),
        ),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除数据源？'),
        content: Text('将立即删除“${source.displayName}”及其 Runtime 私有数据。已保存到书架的内容不会受到影响。'),
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
      await ref.read(pluginRuntimeSourceActionProvider.notifier).uninstall(pluginId: source.id);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源已即时删除。')));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据源删除失败，请稍后重试。')));
    }
  }
}

class _VerifySourceButton extends StatelessWidget {
  const _VerifySourceButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool compact = _useCompactDetailActionLayout(context);
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        key: const Key('data-source-detail-verify'),
        onPressed: onPressed,
        icon: const Icon(Icons.fact_check_outlined),
        label: _detailActionLabel('检测搜索、发现与阅读链路', compact),
      ),
    );
  }
}

class _RemoveSourceButton extends StatelessWidget {
  const _RemoveSourceButton({required this.isRemoving, required this.onPressed});

  final bool isRemoving;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final bool compact = _useCompactDetailActionLayout(context);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: const Key('data-source-detail-remove'),
        onPressed: onPressed,
        icon: isRemoving
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.delete_outline),
        label: _detailActionLabel(isRemoving ? '正在删除' : '删除数据源', compact),
        style: OutlinedButton.styleFrom(foregroundColor: tokens.notification),
      ),
    );
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
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(color: tokens.featureSurface, borderRadius: AppRadii.discoveryTile),
        child: Material(
          color: Colors.transparent,
          child: Semantics(
            button: field.expandable,
            label: field.expandable ? '${field.label}，点击查看完整内容' : null,
            child: InkWell(
              key: field.expandable ? const Key('data-source-detail-version') : null,
              borderRadius: AppRadii.discoveryTile,
              onTap: field.expandable ? () => _showFullValue(context) : null,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.regular),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(field.label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tokens.mutedText)),
                        ),
                        if (field.expandable) Icon(Icons.open_in_full, size: 14, color: tokens.mutedText),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.unit),
                    Text(
                      field.value,
                      maxLines: field.expandable ? 1 : null,
                      overflow: field.expandable ? TextOverflow.ellipsis : TextOverflow.clip,
                      softWrap: !field.expandable,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface, fontWeight: FontWeight.w500),
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

  Future<void> _showFullValue(BuildContext context) => showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(field.label),
      content: SizedBox(
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

class _DetailActions extends StatelessWidget {
  const _DetailActions({
    required this.isDesktop,
    required this.isDevelopment,
    required this.isWindows,
    required this.opensArchive,
    required this.opening,
    required this.packaging,
    required this.removing,
    required this.canVerify,
    required this.onVerify,
    required this.onOpenDirectory,
    required this.onPackage,
    required this.onRemove,
  });

  final bool isDesktop;
  final bool isDevelopment;
  final bool isWindows;
  final bool opensArchive;
  final bool opening;
  final bool packaging;
  final bool removing;
  final bool canVerify;
  final VoidCallback? onVerify;
  final VoidCallback onOpenDirectory;
  final VoidCallback onPackage;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
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
            Text('数据源操作', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.regular),
            _VerifySourceButton(onPressed: canVerify ? onVerify : null),
            if (isDevelopment && isWindows) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              _PackageDevelopmentButton(isPackaging: packaging, onPressed: packaging ? null : onPackage),
            ],
            if (isDesktop) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              _OpenDirectoryButton(
                isDevelopment: isDevelopment,
                opensArchive: opensArchive,
                isOpening: opening,
                onPressed: opening ? null : onOpenDirectory,
              ),
            ] else ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.info_outline, size: 18, color: tokens.mutedText),
                  const SizedBox(width: AppSpacing.unit),
                  Expanded(
                    child: Text('代码文件夹可在桌面端打开。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                  ),
                ],
              ),
            ],
            if (!isDevelopment) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              Divider(height: 1, color: tokens.divider),
              const SizedBox(height: AppSpacing.regular),
              _RemoveSourceButton(isRemoving: removing, onPressed: removing ? null : onRemove),
            ],
          ],
        ),
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
  const _OpenDirectoryButton({required this.isDevelopment, required this.opensArchive, required this.isOpening, required this.onPressed});

  final bool isDevelopment;
  final bool opensArchive;
  final bool isOpening;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool compact = _useCompactDetailActionLayout(context);
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        key: const Key('data-source-detail-open-directory'),
        onPressed: onPressed,
        icon: isOpening
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.folder_open_outlined),
        label: _detailActionLabel(
          isOpening
              ? '正在打开…'
              : isDevelopment
              ? '打开开发项目文件夹'
              : opensArchive
              ? '打开原始安装包文件夹'
              : '打开已安装源码文件夹',
          compact,
        ),
      ),
    );
  }
}

class _PackageDevelopmentButton extends StatelessWidget {
  const _PackageDevelopmentButton({required this.isPackaging, required this.onPressed});

  final bool isPackaging;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool compact = _useCompactDetailActionLayout(context);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: const Key('data-source-detail-package-development'),
        onPressed: onPressed,
        icon: isPackaging
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.inventory_2_outlined),
        label: _detailActionLabel(isPackaging ? '正在打包…' : '打包数据源插件', compact),
      ),
    );
  }
}

bool _useCompactDetailActionLayout(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 360 || MediaQuery.textScalerOf(context).scale(1) > 1;

Widget _detailActionLabel(String label, bool compact) => compact ? Text(label, textAlign: TextAlign.center, softWrap: true) : Text(label);

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
