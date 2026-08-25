import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// Runtime-backed details for one data source, without exposing Runtime paths.
class PluginRuntimeSourceDetailPage extends ConsumerWidget {
  const PluginRuntimeSourceDetailPage({
    required this.pluginId,
    required this.onBackRequested,
    super.key,
  });

  final String pluginId;
  final VoidCallback onBackRequested;

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
                  loading: () => const AppLoadingState(
                    label: '正在加载数据源详情',
                    message: '正在读取数据源信息。',
                  ),
                  error: (Object _, StackTrace _) => _DetailFailure(
                    onRetry: () =>
                        ref.invalidate(pluginRuntimeConnectionProvider),
                  ),
                  data: (PluginRuntimeConnection value) {
                    final source = value.plugins
                        .where((plugin) => plugin.id == pluginId)
                        .firstOrNull;
                    if (source == null) {
                      return _DetailFailure(
                        onRetry: () =>
                            ref.invalidate(pluginRuntimeConnectionProvider),
                        message: '该数据源已不存在或暂时不可用。',
                      );
                    }
                    return _DetailContent(source: source);
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
  const _DetailContent({required this.source});

  final PluginRuntimePlugin source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = AppThemeTokens.of(context);
    final isDevelopment = source.status == 'development';
    final isWindows = Platform.isWindows;
    final dataUsage = isDevelopment
        ? null
        : ref.watch(pluginRuntimeSourceDataSizeProvider(source.id));
    final archiveUsage = isDevelopment
        ? null
        : ref.watch(pluginRuntimeSourceArchiveSizeProvider(source.id));
    final npmUsage = isDevelopment
        ? null
        : ref.watch(pluginRuntimeSourceNpmSizeProvider(source.id));
    final opening = ref
        .watch(pluginRuntimeSourceDirectoryProvider)
        .contains(source.id);
    return ListView(
      key: const Key('data-source-detail-content'),
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        0,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.comfortable,
      ),
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
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: tokens.accentSoft,
                        borderRadius: AppRadii.discoveryTile,
                      ),
                      child: SizedBox(
                        width: AppSpacing.dataSourceMarkExtent,
                        height: AppSpacing.dataSourceMarkExtent,
                        child: Icon(
                          Icons.extension_rounded,
                          color: tokens.dataSourceAccent,
                        ),
                      ),
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
                            isDevelopment ? '开源开发源（即时生效）' : '已安装数据源',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: tokens.mutedText),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.comfortable),
                _DetailField(label: '名称', value: source.displayName),
                _DetailField(
                  label: '来源方式',
                  value: isDevelopment ? '工作区开源书源' : 'Runtime 已安装版本',
                ),
                _DetailField(label: '类型', value: _contentKinds(source)),
                _DetailField(
                  label: '版本',
                  value: source.activeVersion ?? '等待激活',
                ),
                _DetailField(label: '状态', value: _statusLabel(source)),
                _DetailField(label: '标识', value: source.id, isLast: true),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.comfortable),
        if (!isDevelopment)
          _InstallationSizeCard(
            archiveUsage: archiveUsage!,
            dataUsage: dataUsage!,
            npmUsage: npmUsage!,
          ),
        if (!isDevelopment) const SizedBox(height: AppSpacing.comfortable),
        if (isWindows)
          _OpenDirectoryButton(
            isDevelopment: isDevelopment,
            isOpening: opening,
            onPressed: opening
                ? null
                : () => _openDirectory(context, ref, source, isDevelopment),
          )
        else
          Text(
            '仅 Windows 桌面端可打开数据源代码文件夹。',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
          ),
      ],
    );
  }

  Future<void> _openDirectory(
    BuildContext context,
    WidgetRef ref,
    PluginRuntimePlugin source,
    bool isDevelopment,
  ) async {
    try {
      final kind = await ref
          .read(pluginRuntimeSourceDirectoryProvider.notifier)
          .open(pluginId: source.id);
      if (!context.mounted) return;
      final message = switch (kind) {
        PluginCodeDirectoryKind.development => '已打开开发项目文件夹。代码变更会在下一次来源调用时生效。',
        PluginCodeDirectoryKind.installed => '已打开已安装版本文件夹。该副本不会作为开发源即时生效。',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      if (!context.mounted) return;
      final message = isDevelopment ? '开发项目文件夹打开失败。' : '已安装版本文件夹打开失败。';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _InstallationSizeCard extends StatelessWidget {
  const _InstallationSizeCard({
    required this.archiveUsage,
    required this.dataUsage,
    required this.npmUsage,
  });

  final AsyncValue<PluginInstallationSize> archiveUsage;
  final AsyncValue<PluginInstallationSize> dataUsage;
  final AsyncValue<PluginInstallationSize> npmUsage;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final archiveResult = archiveUsage is AsyncData<PluginInstallationSize>
        ? (archiveUsage as AsyncData<PluginInstallationSize>).value
        : null;
    final dataResult = dataUsage is AsyncData<PluginInstallationSize>
        ? (dataUsage as AsyncData<PluginInstallationSize>).value
        : null;
    final npmResult = npmUsage is AsyncData<PluginInstallationSize>
        ? (npmUsage as AsyncData<PluginInstallationSize>).value
        : null;
    final total =
        archiveResult == null || dataResult == null || npmResult == null
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
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.comfortable,
          vertical: AppSpacing.compact,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('安装后大小', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.unit),
            Text(
              '整个书源：${total == null ? '统计中…' : _formatInstallationBytes(total)}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: tokens.dataSourceAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
            _InstallationSizeRow(label: '原始安装包', usage: archiveUsage),
            _InstallationSizeRow(label: '数据文件', usage: dataUsage),
            _InstallationSizeRow(
              label: 'npm 包',
              usage: npmUsage,
              slowHint: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _InstallationSizeRow extends StatelessWidget {
  const _InstallationSizeRow({
    required this.label,
    required this.usage,
    this.slowHint = false,
  });

  final String label;
  final AsyncValue<PluginInstallationSize> usage;
  final bool slowHint;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final value = usage.when(
      data: (PluginInstallationSize result) =>
          '${_formatInstallationBytes(result.bytes)}（${result.fileCount} 个文件）',
      error: (Object _, StackTrace _) => '统计失败',
      loading: () => slowHint ? '统计中（文件较多）…' : '统计中…',
    );
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.regular),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          Text(
            value,
            textAlign: TextAlign.right,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
          ),
        ],
      ),
    );
  }
}

class _DetailField extends StatelessWidget {
  const _DetailField({
    required this.label,
    required this.value,
    this.isLast = false,
  });

  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: tokens.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label)),
          const SizedBox(width: AppSpacing.regular),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
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
  const _OpenDirectoryButton({
    required this.isDevelopment,
    required this.isOpening,
    required this.onPressed,
  });

  final bool isDevelopment;
  final bool isOpening;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    key: const Key('data-source-detail-open-directory'),
    onPressed: onPressed,
    icon: isOpening
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
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

String _contentKinds(PluginRuntimePlugin source) => <String>[
  if (source.contentKinds.contains('novel')) '小说',
  if (source.contentKinds.contains('manga')) '漫画',
].join(' · ');

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
