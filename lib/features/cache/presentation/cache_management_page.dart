/// 统一缓存管理页面。
///
/// 职责：
/// - 分别展示和清理 Runtime 数据源网页/文件缓存、封面缓存与漫画正文图片缓存。
/// - 为每类可再生缓存提供独立用量、失败重试和清理反馈。
///
/// 注意：
/// - 页面只组合独立状态，不读取任何缓存目录。
/// - 清理漫画正文图片只删除可重新下载的图片文件，不删除 manifest、进度或书签。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/cache/application/cover_cache_manager.dart';
import 'package:mg_read/features/plugins/application/plugin_cache_manager.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

class CacheManagementPage extends ConsumerWidget {
  const CacheManagementPage({required this.onBackRequested, required this.onDestinationRequested, super.key});

  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pluginState = ref.watch(pluginCacheManagementProvider);
    final coverState = ref.watch(coverCacheManagementProvider);
    final mangaImageState = ref.watch(mangaImageCacheManagementProvider);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: <Widget>[
              AppSecondaryPageTopBar(
                headerKey: const Key('cache-management-top-bar'),
                backButtonKey: const Key('cache-management-back'),
                title: '缓存管理',
                onBack: onBackRequested,
              ),
              Expanded(
                child: ListView(
                  key: const Key('cache-management-content'),
                  padding: const EdgeInsets.all(AppDetailMetrics.horizontalPadding),
                  children: <Widget>[
                    _SourceCacheSection(
                      state: pluginState,
                      onRetry: () => ref.read(pluginCacheManagementProvider.notifier).refresh(),
                      onClearAll: (state) => _confirmAndClearAllSources(context, ref, state),
                      onClearPlugin: (entry) => _confirmAndClearPlugin(context, ref, entry),
                    ),
                    const SizedBox(height: AppSpacing.regular),
                    _CoverCacheSection(
                      state: coverState,
                      onRetry: () => ref.read(coverCacheManagementProvider.notifier).refresh(),
                      onClear: () => _confirmAndClearCovers(context, ref),
                    ),
                    const SizedBox(height: AppSpacing.regular),
                    _MangaImageCacheSection(
                      state: mangaImageState,
                      onRetry: () => ref.read(mangaImageCacheManagementProvider.notifier).refresh(),
                      onClear: () => _confirmAndClearMangaImages(context, ref),
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

  Future<void> _confirmAndClearPlugin(BuildContext context, WidgetRef ref, PluginCacheEntry entry) async {
    final confirmed = await _confirm(
      context,
      title: '清理 ${entry.displayName} 的缓存？',
      content: '将删除该数据源的网页与临时文件缓存，书架和已保存正文不会受到影响。',
      action: '清理',
      confirmKey: const Key('plugin-cache-confirm'),
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ref.read(pluginCacheManagementProvider.notifier).clearPlugin(entry.pluginId);
    } on Object {
      // The controller retains a safe failure state for the page to render.
    }
  }

  Future<void> _confirmAndClearAllSources(BuildContext context, WidgetRef ref, PluginCacheManagementState state) async {
    final confirmed = await _confirm(
      context,
      title: '清理全部数据源缓存？',
      content: '将清理 ${state.entries.length} 个数据源的网页与临时文件缓存，书架和已保存正文不会受到影响。',
      action: '全部清理',
      confirmKey: const Key('plugin-cache-confirm'),
    );
    if (!confirmed || !context.mounted) return;
    try {
      await ref.read(pluginCacheManagementProvider.notifier).clearAll();
    } on Object {
      // The controller retains a safe failure state for the page to render.
    }
  }

  Future<void> _confirmAndClearCovers(BuildContext context, WidgetRef ref) async {
    final confirmed = await _confirm(
      context,
      title: '清理封面缓存？',
      content: '将删除可重新下载的封面图片，书架、阅读进度和正文不会受到影响。',
      action: '清理',
      confirmKey: const Key('cover-cache-confirm'),
    );
    if (!confirmed || !context.mounted) return;
    await ref.read(coverCacheManagementProvider.notifier).clear();
  }

  Future<void> _confirmAndClearMangaImages(BuildContext context, WidgetRef ref) async {
    final confirmed = await _confirm(
      context,
      title: '清理漫画正文图片缓存？',
      content: '只会删除可重新下载的漫画正文图片，不影响书架、章节清单（manifest）、阅读进度和书签。',
      action: '清理',
      confirmKey: const Key('manga-image-cache-confirm'),
    );
    if (!confirmed || !context.mounted) return;
    await ref.read(mangaImageCacheManagementProvider.notifier).clear();
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String content,
    required String action,
    required Key confirmKey,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: Text(content),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
            FilledButton(key: confirmKey, onPressed: () => Navigator.of(dialogContext).pop(true), child: Text(action)),
          ],
        ),
      ) ??
      false;
}

class _SourceCacheSection extends StatelessWidget {
  const _SourceCacheSection({required this.state, required this.onRetry, required this.onClearAll, required this.onClearPlugin});

  final AsyncValue<PluginCacheManagementState> state;
  final VoidCallback onRetry;
  final ValueChanged<PluginCacheManagementState> onClearAll;
  final ValueChanged<PluginCacheEntry> onClearPlugin;

  @override
  Widget build(BuildContext context) => state.when(
    loading: () => const _CacheSummaryCard(
      title: '数据源网页与文件缓存',
      description: '正在读取各数据源缓存用量…',
      trailing: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
    ),
    error: (Object _, StackTrace _) => _CacheSummaryCard(
      title: '数据源网页与文件缓存',
      description: '缓存信息暂不可用。',
      action: TextButton(key: const Key('plugin-cache-retry'), onPressed: onRetry, child: const Text('重试')),
    ),
    data: (value) {
      final isScanning = value.entries.any((entry) => entry.isScanning);
      return Column(
        children: <Widget>[
          _CacheSummaryCard(
            title: '数据源网页与文件缓存',
            description: isScanning
                ? '正在统计，当前已读取 ${_formatBytes(value.totalBytes)}。包含数据源保存的网页响应和临时文件。'
                : '共 ${_formatBytes(value.totalBytes)}。包含数据源保存的网页响应和临时文件。',
            trailing: value.isRefreshing || isScanning
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            action: FilledButton.tonalIcon(
              key: const Key('plugin-cache-clear-all'),
              onPressed: value.isClearing || value.entries.isEmpty ? null : () => onClearAll(value),
              icon: value.isClearing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.delete_outline_rounded),
              label: const Text('清理全部数据源缓存'),
            ),
          ),
          if (value.feedback != null) ...<Widget>[
            const SizedBox(height: AppSpacing.compact),
            _CacheFeedbackCard(text: _pluginFeedbackText(value.feedback!)),
          ],
          const SizedBox(height: AppSpacing.compact),
          if (value.entries.isEmpty)
            const _EmptyCacheCard(text: '暂无已安装数据源的缓存。')
          else
            ...value.entries.map(
              (entry) => _PluginCacheEntryCard(
                entry: entry,
                isClearing: value.clearingPluginIds.contains(entry.pluginId),
                onClear: () => onClearPlugin(entry),
              ),
            ),
        ],
      );
    },
  );
}

class _CoverCacheSection extends StatelessWidget {
  const _CoverCacheSection({required this.state, required this.onRetry, required this.onClear});

  final AsyncValue<CoverCacheManagementState> state;
  final VoidCallback onRetry;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => state.when(
    loading: () => const _CacheSummaryCard(
      title: '封面缓存',
      description: '正在读取封面缓存用量…',
      trailing: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
    ),
    error: (Object _, StackTrace _) => _CacheSummaryCard(
      title: '封面缓存',
      description: '封面缓存信息暂不可用。',
      action: TextButton(key: const Key('cover-cache-retry'), onPressed: onRetry, child: const Text('重试')),
    ),
    data: (value) => Column(
      children: <Widget>[
        _CacheSummaryCard(
          title: '封面缓存',
          description: '${_formatBytes(value.bytes)}。封面可按需重新下载，清理不会删除书架数据。',
          trailing: value.isRefreshing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          action: FilledButton.tonalIcon(
            key: const Key('cover-cache-clear'),
            onPressed: value.isClearing ? null : onClear,
            icon: value.isClearing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.delete_outline_rounded),
            label: Text(value.isClearing ? '正在清理' : '清理封面缓存'),
          ),
        ),
        if (value.feedback != null) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          _CacheFeedbackCard(text: _coverFeedbackText(value.feedback!)),
        ],
      ],
    ),
  );
}

class _MangaImageCacheSection extends StatelessWidget {
  const _MangaImageCacheSection({required this.state, required this.onRetry, required this.onClear});

  final AsyncValue<MangaImageCacheManagementState> state;
  final VoidCallback onRetry;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => state.when(
    loading: () => const _CacheSummaryCard(
      title: '漫画正文图片缓存',
      description: '正在读取漫画正文图片缓存用量…',
      trailing: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
    ),
    error: (Object _, StackTrace _) => _CacheSummaryCard(
      title: '漫画正文图片缓存',
      description: '漫画正文图片缓存信息暂不可用。',
      action: TextButton(key: const Key('manga-image-cache-retry'), onPressed: onRetry, child: const Text('重试')),
    ),
    data: (value) => Column(
      children: <Widget>[
        _CacheSummaryCard(
          title: '漫画正文图片缓存',
          description: '${_formatBytes(value.bytes)}。图片可按需重新下载，清理不影响书架、章节清单（manifest）、阅读进度和书签。',
          trailing: value.isRefreshing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
          action: FilledButton.tonalIcon(
            key: const Key('manga-image-cache-clear'),
            onPressed: value.isClearing ? null : onClear,
            icon: value.isClearing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.delete_outline_rounded),
            label: Text(value.isClearing ? '正在清理' : '清理漫画正文图片缓存'),
          ),
        ),
        if (value.feedback != null) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          _CacheFeedbackCard(text: _mangaImageFeedbackText(value.feedback!)),
        ],
      ],
    ),
  );
}

class _CacheSummaryCard extends StatelessWidget {
  const _CacheSummaryCard({required this.title, required this.description, this.trailing, this.action});

  final String title;
  final String description;
  final Widget? trailing;
  final Widget? action;

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
            Row(
              children: <Widget>[
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
                ...switch (trailing) {
                  final Widget widget => <Widget>[widget],
                  null => const <Widget>[],
                },
              ],
            ),
            const SizedBox(height: AppSpacing.compact),
            Text(description, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
            if (action != null) ...<Widget>[const SizedBox(height: AppSpacing.regular), action!],
          ],
        ),
      ),
    );
  }
}

class _PluginCacheEntryCard extends StatelessWidget {
  const _PluginCacheEntryCard({required this.entry, required this.isClearing, required this.onClear});

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
          title: Text(entry.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(switch (entry.status) {
            PluginCacheEntryStatus.scanning => '正在读取缓存用量…',
            PluginCacheEntryStatus.failed => '暂时无法读取缓存用量',
            PluginCacheEntryStatus.loaded => _formatBytes(entry.bytes),
          }),
          trailing: TextButton(
            key: ValueKey<String>('plugin-cache-clear-${entry.pluginId}'),
            onPressed: isClearing || entry.isScanning ? null : onClear,
            child: Text(
              isClearing
                  ? '正在清理'
                  : entry.isScanning
                  ? '读取中'
                  : '清理',
            ),
          ),
        ),
      ),
    );
  }
}

class _CacheFeedbackCard extends StatelessWidget {
  const _CacheFeedbackCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          borderRadius: AppRadii.control,
          border: Border.all(color: tokens.divider),
        ),
        child: Padding(padding: const EdgeInsets.all(AppSpacing.regular), child: Text(text)),
      ),
    );
  }
}

class _EmptyCacheCard extends StatelessWidget {
  const _EmptyCacheCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.comfortable),
    child: Center(child: Text(text)),
  );
}

String _pluginFeedbackText(PluginCacheFeedback feedback) => switch (feedback.kind) {
  PluginCacheFeedbackKind.success => '数据源缓存已清理完成。',
  PluginCacheFeedbackKind.partialFailure => '部分数据源缓存未能清理，请稍后重试。',
  PluginCacheFeedbackKind.requestFailure => '数据源缓存清理失败，请检查运行环境后重试。',
};

String _coverFeedbackText(CoverCacheFeedback feedback) => switch (feedback) {
  CoverCacheFeedback.cleared => '封面缓存已清理完成。',
  CoverCacheFeedback.alreadyEmpty => '磁盘封面缓存已经为空，进程内封面已释放。',
  CoverCacheFeedback.failure => '封面缓存清理失败，请稍后重试。',
};

String _mangaImageFeedbackText(MangaImageCacheFeedback feedback) => switch (feedback) {
  MangaImageCacheFeedback.cleared => '漫画正文图片缓存已清理完成。',
  MangaImageCacheFeedback.alreadyEmpty => '漫画正文图片缓存已经为空。',
  MangaImageCacheFeedback.failure => '漫画正文图片缓存清理失败，请稍后重试。',
};

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
