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
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'source_management_tv.dart';

part 'plugin_runtime_help_tv.dart';

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
                child: TvModeScope.isEnabled(context)
                    ? _buildTvHelp(canSelectDevelopmentDirectory, canOpenPrivateDirectory)
                    : ListView(
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
                            body: '列表右侧开关控制启停；点击数据源查看详情、检测或卸载。按内容类型和状态筛选，或搜索名称、标识和网址。停用保留数据，卸载会删除运行数据与安装包，书架内容会保留。',
                          ),
                          const SizedBox(height: AppSpacing.regular),
                          const _HelpSection(
                            icon: Icons.add_to_queue_rounded,
                            title: '添加与更新',
                            body:
                                '在“添加数据源”中选择在线仓库、本地安装包或合集。在线仓库与合集先勾选，再确认安装；更新覆盖会显示版本差异。手动更新在“更多管理”中检查，自动更新在“数据与存储 → 数据源更新”中设置。已下载但未激活的版本会标明下次启动生效。',
                          ),
                          const SizedBox(height: AppSpacing.regular),
                          const _HelpSection(
                            icon: Icons.help_outline_rounded,
                            title: '异常与存储',
                            body: '“待处理”筛选可定位不可用或待生效的数据源。单源详情显示具体原因；更多管理中的运行诊断用于排查服务故障。缓存清理统一在“数据与存储 → 缓存管理”中操作。',
                          ),
                          const SizedBox(height: AppSpacing.regular),
                          ExpansionTile(
                            key: const Key('data-source-development-tools'),
                            title: const Text('开发与调试'),
                            subtitle: const Text('开发目录、运行目录与 Debug 检查页'),
                            children: [
                              if (canSelectDevelopmentDirectory)
                                _DevelopmentDirectorySection(
                                  isSelecting: ref.watch(pluginRuntimeDevelopmentDirectoryProvider),
                                  onPressed: () => unawaited(_selectDevelopmentDirectory()),
                                ),
                              if (canOpenPrivateDirectory)
                                _RuntimePrivateDirectorySection(
                                  isOpening: ref.watch(pluginRuntimePrivateDirectoryProvider),
                                  onPressed: () => unawaited(_openRuntimePrivateDirectory()),
                                ),
                              RuntimeDebugPanel(endpointLauncher: widget.debugEndpointLauncher),
                            ],
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTvHelp(bool canDevelop, bool canOpenDirectory) => TvSourceSections(
    sections: [
      const TvSourceSection(
        id: 'guide',
        title: '遥控器操作',
        icon: Icons.settings_remote_outlined,
        children: [
          _TvHelpCard(title: '添加与安装', icon: Icons.add_to_queue_rounded, body: '在数据源页选择「添加数据源」。打开在线仓库或选择本地安装包，按确认勾选数据源，再选择底部的「导入」。'),
          _TvHelpCard(title: '浏览与管理', icon: Icons.movie_outlined, body: '左侧选择内容分类，向右进入列表。按确认查看详情并启停或卸载；菜单键打开浏览、搜索和来源网站。左侧还可按启用状态筛选。'),
          _TvHelpCard(title: '返回与阅读', icon: Icons.keyboard_return_rounded, body: '返回键先关闭弹窗，焦点回到原操作。长文字可按确认展开，再用上下键逐屏阅读。'),
        ],
      ),
      const TvSourceSection(
        id: 'questions',
        title: '常见问题',
        icon: Icons.help_outline,
        children: [
          _TvHelpCard(title: '没有内容或加载失败', icon: Icons.wifi_off_outlined, body: '检查数据源是否启用，再通过数据源工具打开运行诊断。网络异常时先检查连接；单个来源不可用时，可尝试其他数据源。'),
          _TvHelpCard(title: '安装与更新', icon: Icons.system_update_alt, body: '安装前核对来源和版本。更新确认会列出本地与新版本；覆盖安装需要明确确认。部分更新保存后需要重启才能生效。'),
          _TvHelpCard(title: '删除与缓存', icon: Icons.delete_outline, body: '卸载数据源会移除它的运行数据、缓存和安装包。书架内容会保留；若只是暂时不用，可以先停用。'),
        ],
      ),
      TvSourceSection(
        id: 'advanced',
        title: '开发与调试',
        icon: Icons.code_rounded,
        children: [
          if (canDevelop)
            _DevelopmentDirectorySection(
              isSelecting: ref.watch(pluginRuntimeDevelopmentDirectoryProvider),
              onPressed: () => unawaited(_selectDevelopmentDirectory()),
            ),
          if (canOpenDirectory)
            _RuntimePrivateDirectorySection(
              isOpening: ref.watch(pluginRuntimePrivateDirectoryProvider),
              onPressed: () => unawaited(_openRuntimePrivateDirectory()),
            ),
          RuntimeDebugPanel(endpointLauncher: widget.debugEndpointLauncher),
        ],
      ),
    ],
  );
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
                  SourceManagementInfo(
                    child: Text(
                      body,
                      style:
                          (TvModeScope.isEnabled(context) ? Theme.of(context).textTheme.bodyLarge : Theme.of(context).textTheme.bodySmall)
                              ?.copyWith(color: tokens.mutedText),
                    ),
                  ),
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
    action: TvModeScope.isEnabled(context)
        ? TvFocusable(
            key: const Key('data-source-add-development-directory'),
            onPressed: isSelecting ? null : onPressed,
            child: Text(isSelecting ? '正在识别…' : '选择数据源插件集合目录'),
          )
        : OutlinedButton.icon(
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
    action: TvModeScope.isEnabled(context)
        ? TvFocusable(
            key: const Key('data-source-open-runtime-directory'),
            onPressed: isOpening ? null : onPressed,
            child: Text(isOpening ? '正在打开…' : '打开 Runtime 私有目录'),
          )
        : OutlinedButton.icon(
            key: const Key('data-source-open-runtime-directory'),
            onPressed: isOpening ? null : onPressed,
            icon: isOpening
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.folder_open_outlined),
            label: Text(isOpening ? '正在打开…' : '打开 Runtime 私有目录'),
          ),
  );
}
