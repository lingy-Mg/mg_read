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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_debug_http.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

typedef RuntimeDebugEndpointLauncher = Future<bool> Function(Uri endpoint);

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
    final bool canSelectDevelopmentDirectory = Platform.isWindows;
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
                title: '数据源说明',
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
                      title: '管理数据源',
                      body: '在管理页查看已添加的数据源，并直接启用或停用它们。添加数据源会从本地选择标准 MgRead .mgplugin 文件。',
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
                    if (kDebugMode) ...<Widget>[
                      const SizedBox(height: AppSpacing.regular),
                      _RuntimeDebugHttpSection(endpointLauncher: widget.debugEndpointLauncher ?? _launchRuntimeDebugEndpoint),
                    ],
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

Future<bool> _launchRuntimeDebugEndpoint(Uri endpoint) => launchUrl(endpoint, mode: LaunchMode.externalApplication);

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
    body: '请选择数据源插件集合目录，例如 …\\plugins\\sources。Runtime 只读取它的第一层子目录；不要选择单个数据源插件目录。',
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

class _RuntimeDebugHttpSection extends ConsumerWidget {
  const _RuntimeDebugHttpSection({required this.endpointLauncher});

  final RuntimeDebugEndpointLauncher endpointLauncher;

  Future<void> _copyEndpoint(BuildContext context, String endpoint) async {
    await Clipboard.setData(ClipboardData(text: endpoint));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('调试地址已复制。')));
  }

  Future<void> _openEndpoint(BuildContext context, String endpoint) async {
    final uri = Uri.tryParse(endpoint);
    var launched = false;
    if (uri != null && uri.scheme == 'http' && uri.path == '/__debug') {
      try {
        launched = await endpointLauncher(uri);
      } on Object {
        launched = false;
      }
    }
    if (!context.mounted || launched) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法调用系统浏览器打开调试页面。')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pluginRuntimeDebugHttpProvider);
    final value = switch (state) {
      AsyncData<PluginRuntimeDebugHttp>(:final value) => value,
      _ => const PluginRuntimeDebugHttp.disabled(),
    };
    final temporaryPort = value.endpoints.isEmpty ? null : Uri.tryParse(value.endpoints.first)?.port;
    final tokens = AppThemeTokens.of(context);
    return _HelpSection(
      icon: Icons.bug_report_outlined,
      title: 'Runtime 调试页面',
      body: '仅 Debug：开关会保存到 Runtime 私有运行状态，并优先使用端口 52173；端口不可用时自动临时选择可用端口。同一网络设备可无认证访问，请只在可信网络开启。',
      action: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile.adaptive(
              key: const Key('runtime-debug-http-toggle'),
              contentPadding: EdgeInsets.zero,
              title: Text(value.configuredEnabled ? '已保存为开启' : '已保存为关闭'),
              subtitle: Text(value.enabled ? '调试页面正在监听。' : 'Runtime 重启后会按保存设置恢复。'),
              value: value.configuredEnabled,
              onChanged: state.isLoading ? null : (enabled) => ref.read(pluginRuntimeDebugHttpProvider.notifier).setEnabled(enabled),
            ),
          ),
          if (state.hasError)
            Text('设置读取或保存失败，请检查 Runtime 状态后重试。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.warning)),
          if (value.configuredEnabled && !value.enabled)
            Text('调试 listener 暂不可用；保存状态不变，Runtime 下次启动会重试。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.warning)),
          if (value.usingTemporaryPort)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.unit),
              child: Text(
                '固定端口 52173 当前不可用，已临时使用端口 ${temporaryPort ?? '--'}；下次 Runtime 启动仍会优先尝试 52173。',
                key: const Key('runtime-debug-http-temporary-port'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.warning),
              ),
            ),
          if (value.endpoints.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.compact),
            Text('可访问 IP 地址（${value.endpoints.length}）', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.unit),
            for (final endpoint in value.endpoints)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.unit),
                child: _RuntimeDebugEndpointCard(
                  endpoint: endpoint,
                  onCopy: () => unawaited(_copyEndpoint(context, endpoint)),
                  onOpen: () => unawaited(_openEndpoint(context, endpoint)),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _RuntimeDebugEndpointCard extends StatelessWidget {
  const _RuntimeDebugEndpointCard({required this.endpoint, required this.onCopy, required this.onOpen});

  final String endpoint;
  final VoidCallback onCopy;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final uri = Uri.tryParse(endpoint);
    final host = uri?.host ?? '--';
    final port = uri?.port.toString() ?? '--';
    final scope = host == '127.0.0.1' ? '本机 IP' : '局域网 IP';
    return Container(
      key: Key('runtime-debug-http-endpoint-$endpoint'),
      padding: const EdgeInsets.all(AppSpacing.compact),
      decoration: BoxDecoration(
        color: tokens.mutedSurface,
        border: Border.all(color: tokens.divider),
        borderRadius: AppRadii.surface,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text('$scope：$host', style: Theme.of(context).textTheme.labelMedium)),
              Text('端口：$port', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tokens.mutedText)),
            ],
          ),
          const SizedBox(height: AppSpacing.unit),
          SelectableText(endpoint, key: Key('runtime-debug-http-url-$endpoint'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppSpacing.compact),
          Wrap(
            spacing: AppSpacing.unit,
            runSpacing: AppSpacing.unit,
            children: <Widget>[
              OutlinedButton.icon(
                key: Key('runtime-debug-http-copy-$endpoint'),
                onPressed: onCopy,
                icon: const Icon(Icons.copy_outlined),
                label: const Text('复制'),
              ),
              FilledButton.tonalIcon(
                key: Key('runtime-debug-http-open-$endpoint'),
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('打开'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
