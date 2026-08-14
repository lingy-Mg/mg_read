import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_detail_chrome.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// Main-app UI over the Runtime Facade; it contains no launcher or wire code.
class PluginRuntimeStatusPage extends ConsumerWidget {
  const PluginRuntimeStatusPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pluginRuntimeConnectionProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppDetailMetrics.viewportWidth,
            ),
            child: Column(
              children: <Widget>[
                ProfileDetailTopBar(title: '插件运行时', onBack: onBackRequested),
                Expanded(
                  child: state.when(
                    loading: () => const Center(
                      child: CircularProgressIndicator(
                        key: Key('plugin-runtime-loading'),
                      ),
                    ),
                    error: (Object error, StackTrace _) => _RuntimeFailure(
                      error: AppError.fromUnknown(error),
                      onRetry: () {
                        ref.invalidate(pluginRuntimeConnectionProvider);
                      },
                    ),
                    data: (PluginRuntimeConnection connection) =>
                        _RuntimeContent(connection: connection),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: ProfileDetailBottomBar(
        onSelected: onDestinationRequested,
      ),
    );
  }
}

class _RuntimeContent extends StatelessWidget {
  const _RuntimeContent({required this.connection});

  final PluginRuntimeConnection connection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return ListView(
      key: const Key('plugin-runtime-content'),
      padding: const EdgeInsets.all(AppSpacing.page),
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: AppRadii.detailCard,
            border: Border.all(color: tokens.mutedText.withValues(alpha: 0.2)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.regular),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  connection.isHealthy ? '运行时已就绪' : '运行时状态异常',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.compact),
                Text(
                  'Runtime ${connection.runtimeVersion} · Node ${connection.nodeVersion}',
                  key: const Key('plugin-runtime-version'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: tokens.mutedText,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.regular),
        Text('已安装插件', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSpacing.compact),
        if (connection.plugins.isEmpty)
          Text(
            '尚未安装插件。Runtime 已连接，导入与仓库界面将在对应能力发布后接入。',
            key: const Key('plugin-runtime-empty'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tokens.mutedText,
            ),
          )
        else
          ...connection.plugins.map(
            (plugin) => Card(
              key: ValueKey<String>('plugin-${plugin.id}'),
              margin: const EdgeInsets.only(bottom: AppSpacing.compact),
              child: ListTile(
                title: Text(plugin.name),
                subtitle: Text('${plugin.id}\n${_pluginVersionLabel(plugin)}'),
                isThreeLine: true,
                trailing: Text(_pluginStatusLabel(plugin.status)),
              ),
            ),
          ),
      ],
    );
  }
}

class _RuntimeFailure extends StatelessWidget {
  const _RuntimeFailure({required this.error, required this.onRetry});

  final AppError error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.extension_off_outlined, size: 42),
            const SizedBox(height: AppSpacing.regular),
            Text(
              '插件运行时暂不可用（${error.code.wireValue}）',
              key: const Key('plugin-runtime-error'),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.regular),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

String _pluginVersionLabel(PluginRuntimePlugin plugin) {
  final active = plugin.activeVersion ?? '未激活';
  final pending = plugin.pendingVersion;
  return pending == null ? '当前版本 $active' : '当前 $active · 待激活 $pending';
}

String _pluginStatusLabel(String status) => switch (status) {
  'active' => '已启用',
  'disabled' => '已停用',
  'pending' => '待激活',
  'damaged' => '已损坏',
  _ => '未知',
};
