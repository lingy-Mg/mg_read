/// Presents app-scoped video downloads and forwards file export through a
/// manager lease. Player actions capture the selected episode by identity.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read_motion/mg_read_motion.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_video_cache.dart';
import 'package:mg_read/features/media/application/source_video_data_source.dart';
import 'package:mg_read/features/media/application/source_video_export.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

typedef SourceVideoDownloadPlay = Future<void> Function(BuildContext context, SourceVideoCacheEntry entry);

enum _CurrentVideoAction { download, downloads, export }

Future<void> showSourceVideoDownloadActions(
  BuildContext context, {
  required SourceVideoCache cache,
  required SourceVideoCacheKey key,
  required String title,
  required String episodeTitle,
  required Future<VideoEpisode> Function() resolve,
  SourceVideoDownloadPlay? onPlay,
}) async {
  try {
    await cache.ready;
  } on Object {
    if (context.mounted) _showMessage(context, '暂时无法读取视频缓存。');
    return;
  }
  if (!context.mounted) return;
  final action = await showDialog<_CurrentVideoAction>(
    context: context,
    animationStyle: AppMotion.overlayStyle(context),
    builder: _downloadDialogBuilder(
      context,
      (dialogContext) => ListenableBuilder(
        listenable: cache,
        builder: (_, _) {
          final entry = cache.entryOf(key);
          final completed = entry?.status == SourceVideoCacheStatus.completed;
          final canDownload = entry == null || entry.status == SourceVideoCacheStatus.failed;
          return MotionAlertDialog(
            scrollable: true,
            title: const Text('下载缓存'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(episodeTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                if (entry != null) ...[const SizedBox(height: AppSpacing.compact), _DownloadStatus(entry: entry)],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, _CurrentVideoAction.downloads), child: const Text('下载列表')),
              if (completed && canExportSourceVideo)
                FilledButton(onPressed: () => Navigator.pop(dialogContext, _CurrentVideoAction.export), child: const Text('导出视频')),
              if (canDownload)
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, _CurrentVideoAction.download),
                  child: Text(entry == null ? '下载此集' : '重试下载'),
                ),
            ],
          );
        },
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  switch (action) {
    case _CurrentVideoAction.download:
      unawaited(_startDownload(context, cache, key: key, title: title, episodeTitle: episodeTitle, resolve: resolve));
      _showMessage(context, '已加入视频下载。');
    case _CurrentVideoAction.downloads:
      await _openDownloads(context, onPlay);
    case _CurrentVideoAction.export:
      await _exportVideo(context, cache, key);
  }
}

Future<void> _openDownloads(BuildContext context, SourceVideoDownloadPlay? onPlay) =>
    Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => SourceVideoDownloadsPage(onPlay: onPlay)));

final class SourceVideoDownloadsPage extends ConsumerStatefulWidget {
  const SourceVideoDownloadsPage({super.key, this.onPlay});

  final SourceVideoDownloadPlay? onPlay;

  @override
  ConsumerState<SourceVideoDownloadsPage> createState() => _SourceVideoDownloadsPageState();
}

final class _SourceVideoDownloadsPageState extends ConsumerState<SourceVideoDownloadsPage> {
  SourceVideoCacheKey? _exporting;
  SourceVideoCacheKey? _openingPlayer;

  @override
  Widget build(BuildContext context) {
    final cache = ref.watch(sourceVideoCacheProvider);
    return MotionScaffold(
      body: SafeArea(
        bottom: false,
        child: AppSecondaryPageContent(
          child: Column(
            children: [
              AppSecondaryPageTopBar(title: '视频下载', onBack: () => Navigator.of(context).maybePop()),
              Expanded(
                child: FutureBuilder<void>(
                  future: cache.ready,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) return const Center(child: Text('暂时无法读取视频缓存。'));
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: MotionCircularProgressIndicator(semanticsLabel: '正在读取视频下载'));
                    }
                    return ListenableBuilder(listenable: cache, builder: (context, _) => _buildList(cache));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(SourceVideoCache cache) {
    final entries = cache.entries;
    if (entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.section),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_outlined, size: 40),
              SizedBox(height: AppSpacing.regular),
              Text('暂无下载的视频'),
              SizedBox(height: AppSpacing.compact),
              Text('在播放器内选择「下载缓存」即可下载当前选集。', textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        AppDetailMetrics.horizontalPadding,
        AppSpacing.regular,
        AppDetailMetrics.horizontalPadding,
        MediaQuery.paddingOf(context).bottom + AppSpacing.section,
      ),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: AppSpacing.section),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final completed = entry.status == SourceVideoCacheStatus.completed;
        final failed = entry.status == SourceVideoCacheStatus.failed;
        final play = widget.onPlay;
        final exporting = _exporting == entry.key;
        return Column(
          key: ValueKey(entry.key),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.title, style: Theme.of(context).textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (entry.episodeTitle.isNotEmpty && entry.episodeTitle != entry.title)
              Text(entry.episodeTitle, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: AppSpacing.compact),
            _DownloadStatus(entry: entry),
            Wrap(
              spacing: AppSpacing.compact,
              children: [
                if (completed && play != null)
                  TextButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text(_openingPlayer == entry.key ? '正在打开' : '离线播放'),
                    onPressed: _openingPlayer == null ? () => _play(play, entry) : null,
                  ),
                if (completed && canExportSourceVideo)
                  TextButton.icon(
                    icon: const Icon(Icons.file_upload_outlined),
                    label: Text(exporting ? '正在导出' : '导出视频'),
                    onPressed: _exporting == null ? () => _export(cache, entry.key) : null,
                  ),
                if (failed)
                  TextButton.icon(
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试下载'),
                    onPressed: () => _retry(cache, entry),
                  ),
                TextButton(
                  onPressed: exporting ? null : () => _remove(cache, entry),
                  child: Text(
                    completed
                        ? '删除缓存'
                        : failed
                        ? '移除任务'
                        : '取消下载',
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _retry(SourceVideoCache cache, SourceVideoCacheEntry entry) {
    final key = entry.key;
    final dataSource = SourceVideoDataSource(
      gateway: ref.read(sourceContentGatewayProvider),
      pluginId: key.pluginId,
      adFilterEnabled: ref.read(appSettingsProvider).get(AppSettingKeys.videoAdFilterEnabled),
    );
    return _startDownload(
      context,
      cache,
      key: key,
      title: entry.title,
      episodeTitle: entry.episodeTitle,
      resolve: () => dataSource.resolveDownloadEpisode(key.contentId, groupId: key.groupId, episodeId: key.episodeId),
    );
  }

  Future<void> _export(SourceVideoCache cache, SourceVideoCacheKey key) async {
    if (_exporting != null) return;
    setState(() => _exporting = key);
    try {
      await _exportVideo(context, cache, key);
    } finally {
      if (mounted) setState(() => _exporting = null);
    }
  }

  Future<void> _play(SourceVideoDownloadPlay play, SourceVideoCacheEntry entry) async {
    if (_openingPlayer != null) return;
    setState(() => _openingPlayer = entry.key);
    try {
      await play(context, entry);
    } on SourceVideoCacheException catch (error) {
      if (mounted) _showMessage(context, error.message);
    } on Object {
      if (mounted) _showMessage(context, '暂时无法打开离线视频，请重试。');
    } finally {
      if (mounted) setState(() => _openingPlayer = null);
    }
  }

  Future<void> _remove(SourceVideoCache cache, SourceVideoCacheEntry entry) async {
    if (entry.status == SourceVideoCacheStatus.completed) {
      final confirmed = await showDialog<bool>(
        context: context,
        animationStyle: AppMotion.overlayStyle(context),
        builder: _downloadDialogBuilder(
          context,
          (context) => MotionAlertDialog(
            title: const Text('删除此集缓存？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
            ],
          ),
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    try {
      await cache.remove(entry.key);
    } on SourceVideoCacheException catch (error) {
      if (mounted) _showMessage(context, error.message);
    } on Object {
      if (mounted) _showMessage(context, '视频缓存暂时无法移除，请重试。');
    }
  }
}

final class _DownloadStatus extends StatelessWidget {
  const _DownloadStatus({required this.entry});

  final SourceVideoCacheEntry entry;

  @override
  Widget build(BuildContext context) {
    final progress = entry.progress;
    final received = _formatBytes(entry.receivedBytes);
    final status = switch (entry.status) {
      SourceVideoCacheStatus.queued => '等待下载',
      SourceVideoCacheStatus.downloading => progress == null ? '下载中 · $received' : '下载中 · ${(progress * 100).floor()}% · $received',
      SourceVideoCacheStatus.completed => '已缓存 · $received',
      SourceVideoCacheStatus.failed => entry.error ?? '下载失败，请重试。',
    };
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          status,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: entry.status == SourceVideoCacheStatus.failed ? colors.error : colors.onSurfaceVariant),
        ),
        if (entry.status == SourceVideoCacheStatus.downloading) ...[
          const SizedBox(height: AppSpacing.compact),
          MotionLinearProgressIndicator(value: progress),
        ],
      ],
    );
  }
}

Future<void> _startDownload(
  BuildContext context,
  SourceVideoCache cache, {
  required SourceVideoCacheKey key,
  required String title,
  required String episodeTitle,
  required Future<VideoEpisode> Function() resolve,
}) async {
  try {
    await cache.download(key: key, title: title, episodeTitle: episodeTitle, resolve: resolve);
  } on SourceVideoCacheException catch (error) {
    if (context.mounted) _showMessage(context, error.message);
  } on Object {
    if (context.mounted) _showMessage(context, '暂时无法开始下载，请重试。');
  }
}

Future<void> _exportVideo(BuildContext context, SourceVideoCache cache, SourceVideoCacheKey key) async {
  try {
    final exported = await cache.withExportFile(key, exportSourceVideo);
    if (exported && context.mounted) _showMessage(context, '视频已导出。');
  } on SourceVideoCacheException catch (error) {
    if (context.mounted) _showMessage(context, error.message);
  } on Object {
    if (context.mounted) _showMessage(context, '视频导出失败，请检查保存位置后重试。');
  }
}

void _showMessage(BuildContext context, String message) =>
    ScaffoldMessenger.maybeOf(context)?.showMotionSnackBar(context, SnackBar(content: Text(message)));

WidgetBuilder _downloadDialogBuilder(BuildContext origin, WidgetBuilder builder) {
  final tvMode = TvModeScope.isEnabled(origin);
  return motionOverlayBuilder(
    origin,
    (context) => TvRemoteShortcuts(
      enabled: tvMode,
      child: Builder(builder: builder),
    ),
  );
}

String _formatBytes(int bytes) {
  const kib = 1024;
  const mib = kib * 1024;
  const gib = mib * 1024;
  if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GB';
  if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MB';
  if (bytes >= kib) return '${(bytes / kib).toStringAsFixed(1)} KB';
  return '$bytes B';
}
