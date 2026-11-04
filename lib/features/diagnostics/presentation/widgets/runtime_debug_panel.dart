/// Runtime Debug inspector controls shared by the debug center and source help.
///
/// The Runtime owns listener state and returned endpoints. This widget only
/// renders that projection and provides explicit copy/open actions.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_debug_http.dart';

typedef RuntimeDebugEndpointLauncher = Future<bool> Function(Uri endpoint);

class RuntimeDebugPanel extends ConsumerWidget {
  const RuntimeDebugPanel({this.endpointLauncher, super.key});

  final RuntimeDebugEndpointLauncher? endpointLauncher;

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
        launched = await (endpointLauncher ?? _launchRuntimeDebugEndpoint)(uri);
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(color: tokens.divider),
        borderRadius: AppRadii.detailCard,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.bug_report_outlined, color: tokens.accent),
                const SizedBox(width: AppSpacing.compact),
                Expanded(child: Text('数据源 Runtime 调试', style: Theme.of(context).textTheme.titleMedium)),
                if (state.isLoading) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: AppSpacing.compact),
            Text(
              '打开 Runtime 检查页可查看数据源请求、URL、查询参数、运行日志和最近错误。仅在可信网络开启，排查完成后关闭。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
            ),
            const SizedBox(height: AppSpacing.compact),
            if (TvModeScope.isEnabled(context))
              TvFocusable(
                key: const Key('runtime-debug-http-toggle'),
                selected: value.configuredEnabled,
                onPressed: state.isLoading
                    ? null
                    : () => ref.read(pluginRuntimeDebugHttpProvider.notifier).setEnabled(!value.configuredEnabled),
                child: Text(value.configuredEnabled ? '关闭 Runtime 检查页' : '开启 Runtime 检查页'),
              )
            else
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile.adaptive(
                  key: const Key('runtime-debug-http-toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(value.configuredEnabled ? 'Runtime 检查页已开启' : '开启 Runtime 检查页'),
                  subtitle: Text(value.enabled ? '监听正常，可从下方地址打开。' : '保存设置后 Runtime 会启动本机调试 listener。'),
                  value: value.configuredEnabled,
                  onChanged: state.isLoading ? null : (enabled) => ref.read(pluginRuntimeDebugHttpProvider.notifier).setEnabled(enabled),
                ),
              ),
            if (state.hasError)
              Text('Runtime 调试状态读取失败，请确认 Runtime 已正常启动。', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.warning)),
            if (value.configuredEnabled && !value.enabled)
              Text(
                '调试 listener 暂不可用；保存状态不变，Runtime 下次启动会重试。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.warning),
              ),
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
      ),
    );
  }
}

Future<bool> _launchRuntimeDebugEndpoint(Uri endpoint) => launchUrl(endpoint, mode: LaunchMode.externalApplication);

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
