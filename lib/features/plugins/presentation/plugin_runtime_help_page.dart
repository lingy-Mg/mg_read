/// 数据来源说明与开发工具页面。
///
/// 职责：
/// - 集中展示数据来源使用说明和受控的开发辅助入口。
/// - 通过应用层窄端口执行目录选择、私有目录和 Debug 检查页操作。
///
/// 注意：
/// - 管理主页只保留数据来源添加和启停，不承载开发操作。
/// - 不显示 Runtime 私有路径、内部端口或控制协议。
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
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_debug_http.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// Dedicated page opened by the data-source management help button.
class PluginRuntimeHelpPage extends ConsumerStatefulWidget {
  const PluginRuntimeHelpPage({super.key});

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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(developmentCount > 0 ? '已识别 $developmentCount 个开发数据来源，即时生效。' : '未识别开发数据来源。请选择包含书源子目录的集合目录。')));
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
    final bool canSelectDevelopmentDirectory = kDebugMode && Platform.isWindows;
    final bool canOpenPrivateDirectory = Platform.isWindows;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                headerKey: const Key('data-source-help-top-bar'),
                backButtonKey: const Key('data-source-help-back'),
                title: '数据来源说明',
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
                    const _HelpSection(
                      icon: Icons.auto_stories_outlined,
                      title: '管理数据来源',
                      body: '在管理页查看已添加的数据来源，并直接启用或停用它们。添加数据来源会从本地选择标准 MgRead .mgplugin 文件。',
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
                    if (kDebugMode) ...<Widget>[const SizedBox(height: AppSpacing.regular), const _RuntimeDebugHttpSection()],
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
    title: '开发数据来源',
    body: '请选择书源集合目录，例如 …\\plugins\\sources。Runtime 只读取它的第一层子目录；不要选择单个书源目录。',
    action: OutlinedButton.icon(
      key: const Key('data-source-add-development-directory'),
      onPressed: isSelecting ? null : onPressed,
      icon: isSelecting
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.folder_open_outlined),
      label: Text(isSelecting ? '正在识别开发数据来源…' : '选择书源集合目录'),
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

class _RuntimeDebugHttpSection extends ConsumerWidget {
  const _RuntimeDebugHttpSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pluginRuntimeDebugHttpProvider);
    final value = switch (state) {
      AsyncData<PluginRuntimeDebugHttp>(:final value) => value,
      _ => const PluginRuntimeDebugHttp.disabled(),
    };
    final tokens = AppThemeTokens.of(context);
    return _HelpSection(
      icon: Icons.bug_report_outlined,
      title: 'Runtime 调试页面',
      body: '仅 Debug：开关会保存到 Runtime 私有运行状态，并固定使用端口 52173。同一网络设备可无认证访问，请只在可信网络开启。',
      action: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SwitchListTile.adaptive(
            key: const Key('runtime-debug-http-toggle'),
            contentPadding: EdgeInsets.zero,
            title: Text(value.configuredEnabled ? '已保存为开启' : '已保存为关闭'),
            subtitle: Text(value.enabled ? '调试页面正在监听。' : 'Runtime 重启后会按保存设置恢复。'),
            value: value.configuredEnabled,
            onChanged: state.isLoading ? null : (enabled) => ref.read(pluginRuntimeDebugHttpProvider.notifier).setEnabled(enabled),
          ),
          if (state.hasError)
            Text('设置读取或保存失败，请检查 Runtime 状态后重试。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.warning)),
          if (value.configuredEnabled && !value.enabled)
            Text('固定端口暂不可用；保存状态不变，Runtime 下次启动会重试。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.warning)),
          for (final endpoint in value.endpoints)
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
    );
  }
}
