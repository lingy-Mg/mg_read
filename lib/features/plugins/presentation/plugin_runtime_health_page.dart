import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// A small, expandable Flutter-native status page for the Node Runtime.
///
/// The page intentionally uses ordinary Flutter widgets rather than a web
/// template engine. New Runtime fields can be added as typed sections without
/// introducing a second UI stack.
class PluginRuntimeHealthPage extends ConsumerWidget {
  const PluginRuntimeHealthPage({required this.onBackRequested, super.key});

  final VoidCallback onBackRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pluginRuntimeStatusProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                headerKey: const Key('runtime-health-top-bar'),
                backButtonKey: const Key('runtime-health-back'),
                title: 'Node 状态',
                onBack: onBackRequested,
                actions: <Widget>[
                  AppSecondaryPageIconButton(
                    key: const Key('runtime-health-refresh'),
                    label: '刷新状态',
                    icon: Icons.refresh_rounded,
                    onPressed: () =>
                        ref.invalidate(pluginRuntimeStatusProvider),
                  ),
                ],
              ),
              Expanded(
                child: status.when(
                  loading: () => const AppLoadingState(
                    label: '正在读取 Node 状态',
                    message: '正在读取 Node 状态',
                    progressKey: Key('runtime-health-loading'),
                  ),
                  error: (Object _, StackTrace _) => _RuntimeHealthFailure(
                    onRetry: () => ref.invalidate(pluginRuntimeStatusProvider),
                  ),
                  data: (PluginRuntimeStatus value) =>
                      _RuntimeHealthContent(status: value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RuntimeHealthFailure extends StatelessWidget {
  const _RuntimeHealthFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton(
        key: const Key('runtime-health-retry'),
        onPressed: onRetry,
        child: const Text('Node 状态暂不可用，点击重试'),
      ),
    );
  }
}

class _RuntimeHealthContent extends StatelessWidget {
  const _RuntimeHealthContent({required this.status});

  final PluginRuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const Key('runtime-health-content'),
      padding: const EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        AppSpacing.comfortable,
      ),
      children: <Widget>[
        _RuntimeSummaryCard(status: status),
        const SizedBox(height: AppSpacing.regular),
        _RuntimeMemoryCard(
          memory: status.memory,
          runtimeKind: status.runtimeKind,
        ),
        const SizedBox(height: AppSpacing.regular),
        _RuntimePluginsCard(plugins: status.plugins),
      ],
    );
  }
}

class _RuntimeSummaryCard extends StatelessWidget {
  const _RuntimeSummaryCard({required this.status});

  final PluginRuntimeStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return _StatusCard(
      cardKey: const Key('runtime-health-summary-card'),
      title: status.runtimeKind == 'android-javet'
          ? 'Node/V8（Android 内嵌）'
          : 'Node.js Runtime',
      icon: Icons.memory_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                status.isHealthy
                    ? Icons.check_circle_rounded
                    : Icons.error_rounded,
                color: status.isHealthy ? tokens.success : tokens.warning,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.unit),
              Text(
                status.isHealthy ? '运行正常' : '运行异常',
                key: const Key('runtime-health-state'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.regular),
          _StatusValue(
            label: status.runtimeKind == 'android-javet'
                ? 'Node/V8'
                : 'Node.js',
            value: status.nodeVersion,
          ),
          _StatusValue(label: 'Runtime', value: status.runtimeVersion),
          _StatusValue(label: '运行时长', value: _formatDuration(status.uptime)),
          _StatusValue(
            label: '平台',
            value: '${status.platform} · ${status.arch}',
          ),
        ],
      ),
    );
  }
}

class _RuntimeMemoryCard extends StatelessWidget {
  const _RuntimeMemoryCard({required this.memory, required this.runtimeKind});

  final PluginRuntimeMemory memory;
  final String runtimeKind;

  @override
  Widget build(BuildContext context) {
    return _StatusCard(
      cardKey: const Key('runtime-health-memory-card'),
      title: '内存占用',
      icon: Icons.data_usage_rounded,
      child: Column(
        children: <Widget>[
          _StatusValue(
            label: runtimeKind == 'android-javet' ? '宿主进程 RSS' : '进程占用 RSS',
            value: _formatBytes(memory.rss),
          ),
          _StatusValue(
            label: 'V8 堆已用 / 总量',
            value:
                '${_formatBytes(memory.heapUsed)} / ${_formatBytes(memory.heapTotal)}',
          ),
          _StatusValue(label: '外部内存', value: _formatBytes(memory.external)),
          _StatusValue(
            label: 'ArrayBuffer',
            value: _formatBytes(memory.arrayBuffers),
          ),
        ],
      ),
    );
  }
}

class _RuntimePluginsCard extends StatelessWidget {
  const _RuntimePluginsCard({required this.plugins});

  final List<PluginRuntimePlugin> plugins;

  @override
  Widget build(BuildContext context) {
    final enabled = plugins
        .where((PluginRuntimePlugin plugin) => plugin.enabled)
        .length;
    return _StatusCard(
      cardKey: const Key('runtime-health-plugins-card'),
      title: '数据源插件',
      icon: Icons.extension_rounded,
      trailing: Text(
        '$enabled/${plugins.length} 已启用',
        key: const Key('runtime-health-plugin-count'),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppThemeTokens.of(context).mutedText,
        ),
      ),
      child: plugins.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.compact),
              child: Text('暂无数据源插件'),
            )
          : Column(
              children: List<Widget>.generate(plugins.length, (int index) {
                final plugin = plugins[index];
                return Column(
                  children: <Widget>[
                    _RuntimePluginRow(plugin: plugin),
                    if (index < plugins.length - 1)
                      Divider(color: AppThemeTokens.of(context).divider),
                  ],
                );
              }),
            ),
    );
  }
}

class _RuntimePluginRow extends StatelessWidget {
  const _RuntimePluginRow({required this.plugin});

  final PluginRuntimePlugin plugin;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      key: ValueKey<String>('runtime-health-plugin-${plugin.id}'),
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
      child: Row(
        children: <Widget>[
          Icon(
            plugin.enabled
                ? Icons.check_circle_outline_rounded
                : Icons.pause_circle_outline_rounded,
            color: plugin.enabled ? tokens.success : tokens.mutedText,
            size: 20,
          ),
          const SizedBox(width: AppSpacing.compact),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  plugin.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.unit / 2),
                Text(
                  '${plugin.status} · ${plugin.activeVersion ?? '未激活'}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.cardKey,
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final Key cardKey;
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: cardKey,
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.profileList,
        border: Border.all(color: tokens.divider),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: tokens.shadow.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, color: tokens.dataSourceAccent, size: 20),
                const SizedBox(width: AppSpacing.unit),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: AppSpacing.compact),
            child,
          ],
        ),
      ),
    );
  }
}

class _StatusValue extends StatelessWidget {
  const _StatusValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.unit),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label, style: TextStyle(color: tokens.mutedText)),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) return '$hours小时 $minutes分';
  if (minutes > 0) return '$minutes分 $seconds秒';
  return '$seconds秒';
}
