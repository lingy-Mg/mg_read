/// 数据源说明与开发工具页面。
///
/// 职责：
/// - 集中展示数据源使用说明和受控的开发辅助入口。
/// - 通过应用层窄端口执行目录选择、私有目录和 Debug 检查页操作。
/// - 展示 Runtime 返回的实际 Debug 地址，并提供复制和外部浏览器打开操作。
///
/// 注意：
/// - 管理主页只保留数据源添加和启停，不承载开发操作。
/// - 不显示 Runtime 私有路径、内部端口或控制协议。
///
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/diagnostics/presentation/widgets/runtime_debug_panel.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// Dedicated page opened by the data-source management help button.
class PluginRuntimeHelpPage extends ConsumerStatefulWidget {
  const PluginRuntimeHelpPage({super.key, this.debugEndpointLauncher});

  final RuntimeDebugEndpointLauncher? debugEndpointLauncher;

  @override
  ConsumerState<PluginRuntimeHelpPage> createState() => _PluginRuntimeHelpPageState();
}

class _PluginRuntimeHelpPageState extends ConsumerState<PluginRuntimeHelpPage> {
  Future<void> _selectDevelopmentDirectory() async {
    try {
      final selected = await ref.read(pluginRuntimeDevelopmentDirectoryProvider.notifier).selectDirectory();
      if (!mounted || !selected) return;
      final connection = await ref.read(pluginRuntimeConnectionProvider.future);
      if (!mounted) return;
      final developmentCount = connection.plugins.where((PluginRuntimePlugin source) => source.status == 'development').length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(developmentCount > 0 ? '已识别 $developmentCount 个开发数据源插件，即时生效。' : '未识别开发数据源插件。请选择包含数据源插件子目录的集合目录。')),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('开发目录添加失败，请检查目录后重试。')));
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

  @override
  Widget build(BuildContext context) {
    final bool canSelectDevelopmentDirectory = Platform.isWindows || Platform.isMacOS;
    final bool canOpenPrivateDirectory = Platform.isWindows || Platform.isMacOS;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                headerKey: const Key('data-source-help-top-bar'),
                backButtonKey: const Key('data-source-help-back'),
                title: '使用帮助',
                onBack: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: ListView(
                  key: const Key('data-source-help-content'),
                  padding: const EdgeInsets.fromLTRB(
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.regular,
                    AppDetailMetrics.horizontalPadding,
                    AppSpacing.comfortable,
                  ),
                  children: <Widget>[
                    _HelpSection(
                      icon: Icons.auto_stories_outlined,
                      title: '管理数据源',
                      body: const bool.fromEnvironment('MGREAD_NATIVE_RUNTIME')
                          ? '点击“添加数据源”，选择原生 .mgplugin 文件导入；列表右侧开关控制启用状态。'
                          : Platform.isMacOS || const bool.fromEnvironment('MGREAD_NODE_ONLY')
                          ? '点击“添加数据源”，选择 Node 数据源并导入 .mgplugin.js 或 .mgplugin 文件；列表右侧开关控制启用状态。'
                          : '点击“添加数据源”，按提供方说明选择 Node 或原生类型，两类可以同时使用。Node 支持 .mgplugin.js 和 .mgplugin；原生支持 .mgplugin。列表右侧开关控制启用状态。',
                    ),
                    if (canSelectDevelopmentDirectory) ...<Widget>[
                      const SizedBox(height: AppSpacing.regular),
                      _DevelopmentDirectorySection(
                        isSelecting: ref.watch(pluginRuntimeDevelopmentDirectoryProvider),
                        onPressed: () => unawaited(_selectDevelopmentDirectory()),
                      ),
                    ],
                    if (canOpenPrivateDirectory) ...<Widget>[
                      const SizedBox(height: AppSpacing.regular),
                      _RuntimePrivateDirectorySection(
                        isOpening: ref.watch(pluginRuntimePrivateDirectoryProvider),
                        onPressed: () => unawaited(_openRuntimePrivateDirectory()),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.regular),
                    RuntimeDebugPanel(endpointLauncher: widget.debugEndpointLauncher),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HelpSection extends StatelessWidget {
  const _HelpSection({required this.icon, required this.title, required this.body, this.action});

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(color: tokens.divider),
        borderRadius: AppRadii.detailControl,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: AppSpacing.minimumTouchTarget,
              height: AppSpacing.minimumTouchTarget,
              decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: AppRadii.detailControl),
              child: Icon(icon, color: tokens.dataSourceAccent),
            ),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.unit),
                  Text(body, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                  if (action != null) ...<Widget>[const SizedBox(height: AppSpacing.compact), action!],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DevelopmentDirectorySection extends StatelessWidget {
  const _DevelopmentDirectorySection({required this.isSelecting, required this.onPressed});

  final bool isSelecting;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => _HelpSection(
    icon: Icons.code_rounded,
    title: '开发数据源插件',
    body: '请选择数据源插件集合目录，例如 …${Platform.pathSeparator}plugins${Platform.pathSeparator}sources。Runtime 只读取它的第一层子目录；不要选择单个数据源插件目录。',
    action: OutlinedButton.icon(
      key: const Key('data-source-add-development-directory'),
      onPressed: isSelecting ? null : onPressed,
      icon: isSelecting
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.folder_open_outlined),
      label: Text(isSelecting ? '正在识别开发数据源插件…' : '选择数据源插件集合目录'),
    ),
  );
}

class _RuntimePrivateDirectorySection extends StatelessWidget {
  const _RuntimePrivateDirectorySection({required this.isOpening, required this.onPressed});

  final bool isOpening;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => _HelpSection(
    icon: Icons.folder_outlined,
    title: 'Runtime 私有目录',
    body: '用于查看 Runtime 保存的插件安装版本、私有数据和缓存。应用不会显示或复制该目录路径。',
    action: OutlinedButton.icon(
      key: const Key('data-source-open-runtime-directory'),
      onPressed: isOpening ? null : onPressed,
      icon: isOpening
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.folder_open_outlined),
      label: Text(isOpening ? '正在打开…' : '打开 Runtime 私有目录'),
    ),
  );
}
