import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_cache_manager.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_loading_state.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// User-facing maintenance page for Runtime-owned data-source caches.
class PluginCacheManagementPage extends ConsumerStatefulWidget {
  const PluginCacheManagementPage({
    required this.onBackRequested,
    required this.onDestinationRequested,
    super.key,
  });

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  ConsumerState<PluginCacheManagementPage> createState() =>
      _PluginCacheManagementPageState();
}

class _PluginCacheManagementPageState
    extends ConsumerState<PluginCacheManagementPage> {
  static const Duration _refreshInterval = Duration(seconds: 2);
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      unawaited(ref.read(pluginCacheManagementProvider.notifier).refresh());
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(pluginCacheManagementProvider);
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
                AppSecondaryPageTopBar(
                  headerKey: const Key('plugin-cache-top-bar'),
                  backButtonKey: const Key('plugin-cache-back'),
                  title: '数据源缓存',
                  onBack: widget.onBackRequested,
                ),
                Expanded(
                  child: state.when(
                    loading: () => const AppLoadingState(
                      label: '正在读取缓存用量',
                      message: '正在读取缓存用量',
                      progressKey: Key('plugin-cache-loading'),
                    ),
                    error: (Object _, StackTrace _) => Center(
                      child: TextButton(
                        key: const Key('plugin-cache-retry'),
                        onPressed: () => ref
                            .read(pluginCacheManagementProvider.notifier)
                            .refresh(),
                        child: const Text('缓存信息暂不可用，点击重试'),
                      ),
                    ),
                    data: (value) => _CacheContent(
                      state: value,
                      onClearAll: () =>
                          _confirmAndClearAll(context, ref, value),
                      onClearPlugin: (entry) =>
                          _confirmAndClearPlugin(context, ref, entry),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmAndClearPlugin(
    BuildContext context,
    WidgetRef ref,
    PluginCacheEntry entry,
  ) async {
    final confirmed = await _confirm(
      context,
      title: '清理 ${entry.displayName} 的缓存？',
      content: '将删除该数据源的临时缓存，已保存到书架的内容不会受到影响。',
      action: '清理',
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ref
          .read(pluginCacheManagementProvider.notifier)
          .clearPlugin(entry.pluginId);
    } on Object {
      // The controller retains a safe failure state for the page to render.
    }
  }

  Future<void> _confirmAndClearAll(
    BuildContext context,
    WidgetRef ref,
    PluginCacheManagementState state,
  ) async {
    final confirmed = await _confirm(
      context,
      title: '清理全部数据源缓存？',
      content: '将清理 ${state.entries.length} 个数据源的临时缓存，已保存到书架的内容不会受到影响。',
      action: '全部清理',
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ref.read(pluginCacheManagementProvider.notifier).clearAll();
    } on Object {
      // The controller retains a safe failure state for the page to render.
    }
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String content,
    required String action,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('plugin-cache-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
}

class _CacheContent extends StatelessWidget {
  const _CacheContent({
    required this.state,
    required this.onClearAll,
    required this.onClearPlugin,
  });

  final PluginCacheManagementState state;
  final VoidCallback onClearAll;
  final ValueChanged<PluginCacheEntry> onClearPlugin;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return ListView(
      key: const Key('plugin-cache-content'),
      padding: const EdgeInsets.all(AppDetailMetrics.horizontalPadding),
      children: <Widget>[
        DecoratedBox(
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
                    Expanded(
                      child: Text(
                        '数据源缓存',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (state.isRefreshing) ...<Widget>[
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: AppSpacing.unit),
                      Text(
                        '正在刷新',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.mutedText,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.compact),
                Text(
                  '共 ${_formatBytes(state.totalBytes)}。缓存由数据源运行环境单独管理，清理不会删除书架内容。',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                ),
                const SizedBox(height: AppSpacing.regular),
                FilledButton.tonalIcon(
                  key: const Key('plugin-cache-clear-all'),
                  onPressed: state.isClearing || state.entries.isEmpty
                      ? null
                      : onClearAll,
                  icon: state.isClearing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline_rounded),
                  label: const Text('清理全部缓存'),
                ),
              ],
            ),
          ),
        ),
        if (state.feedback != null) ...<Widget>[
          const SizedBox(height: AppSpacing.regular),
          _FeedbackCard(feedback: state.feedback!),
        ],
        const SizedBox(height: AppSpacing.regular),
        if (state.entries.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.comfortable),
              child: Text('暂无已安装数据源的缓存。'),
            ),
          )
        else
          ...state.entries.map(
            (entry) => _CacheEntryCard(
              entry: entry,
              isClearing: state.clearingPluginIds.contains(entry.pluginId),
              onClear: () => onClearPlugin(entry),
            ),
          ),
      ],
    );
  }
}

class _CacheEntryCard extends StatelessWidget {
  const _CacheEntryCard({
    required this.entry,
    required this.isClearing,
    required this.onClear,
  });
  final PluginCacheEntry entry;
  final bool isClearing;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.compact),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: AppRadii.profileList,
          border: Border.all(color: tokens.divider),
        ),
        child: ListTile(
          key: ValueKey<String>('plugin-cache-${entry.pluginId}'),
          title: Text(
            entry.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(_formatBytes(entry.bytes)),
          trailing: TextButton(
            key: ValueKey<String>('plugin-cache-clear-${entry.pluginId}'),
            onPressed: isClearing ? null : onClear,
            child: Text(isClearing ? '正在清理' : '清理'),
          ),
        ),
      ),
    );
  }
}

class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({required this.feedback});
  final PluginCacheFeedback feedback;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final text = switch (feedback.kind) {
      PluginCacheFeedbackKind.success => '缓存已清理完成。',
      PluginCacheFeedbackKind.partialFailure => '部分数据源缓存未能清理，请稍后重试。',
      PluginCacheFeedbackKind.requestFailure => '缓存清理失败，请检查运行环境后重试。',
    };
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          borderRadius: AppRadii.control,
          border: Border.all(color: tokens.divider),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.regular),
          child: Text(text),
        ),
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
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
