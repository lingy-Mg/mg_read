/// Debug details for the active video session.
///
/// Responsibilities:
/// - Present the current playback URL, request headers and session state.
/// - Keep long values on one line with an explicit copy action.
///
/// Notes:
/// - This sheet performs no network or playback work.
/// - The URL is intentionally shown verbatim for local debugging.
library;

// The sheet is package-private and intentionally not exported by the public
// package entry point.
// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/controller.dart';
import '../api/models.dart';
import 'video_player_visuals.dart';
import 'video_player_modal.dart';

Future<void> showVideoDetailsSheet(
  BuildContext context, {
  required VideoPlayerController controller,
  required VideoEpisode? activeEpisode,
}) => showVideoPlayerModal<void>(
  context: context,
  builder: (sheetContext) => ListenableBuilder(
    listenable: controller,
    builder: (context, child) => _VideoDetailsSheet(
      snapshot: controller.snapshot,
      activeEpisode: activeEpisode,
    ),
  ),
);

final class _VideoDetailsSheet extends StatelessWidget {
  const _VideoDetailsSheet({
    required this.snapshot,
    required this.activeEpisode,
  });

  final VideoPlayerSnapshot snapshot;
  final VideoEpisode? activeEpisode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final episode = activeEpisode;
    final headers = episode == null || episode.httpHeaders.isEmpty
        ? '无'
        : const JsonEncoder.withIndent('  ').convert(episode.httpHeaders);
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.86,
        alignment: Alignment.bottomCenter,
        child: VideoPlayerGlassPanel(
          key: const Key('video-details-glass'),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),

          child: Material(
            color: Colors.transparent,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const _DetailsHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 12, 10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '视频详情',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: videoPlayerForeground,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('video-details-close'),
                        tooltip: '关闭视频详情',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    key: const Key('video-details-sheet'),
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                    children: <Widget>[
                      _DetailsHeading(
                        title: snapshot.title.isEmpty ? '视频' : snapshot.title,
                        subtitle: _episodeLabel(snapshot),
                        status: _statusLabel(snapshot),
                      ),
                      const SizedBox(height: 18),
                      _DetailsCard(
                        title: '当前播放资源',
                        children: <Widget>[
                          _DetailValueRow(
                            key: const Key('video-details-url-row'),
                            icon: Icons.link_rounded,
                            label: '播放 URL',
                            value: episode?.uri ?? '尚未解析到播放 URL',
                            valueKey: const Key('video-details-url'),
                            copyKey: const Key('video-details-url-copy'),
                            copyLabel: '复制播放 URL',
                          ),
                          const _DetailsDivider(),
                          _DetailValueRow(
                            key: const Key('video-details-headers-row'),
                            icon: Icons.http_rounded,
                            label: '请求头',
                            value: headers,
                            valueKey: const Key('video-details-headers'),
                            copyKey: const Key('video-details-headers-copy'),
                            copyLabel: '复制请求头',
                            maxLines: 3,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _DetailsCard(
                        title: '内容与选集',
                        children: <Widget>[
                          _MetadataRow(
                            label: '内容 ID',
                            value: snapshot.contentId,
                          ),
                          _MetadataRow(
                            label: '分组 ID',
                            value: snapshot.activeGroupId ?? '—',
                          ),
                          _MetadataRow(
                            label: '选集 ID',
                            value: snapshot.activeEpisodeId ?? '—',
                          ),
                          _MetadataRow(
                            label: '选集标题',
                            value: episode?.title ?? '—',
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _DetailsCard(
                        title: '播放状态',
                        children: <Widget>[
                          _MetadataRow(
                            label: '状态',
                            value: _statusLabel(snapshot),
                          ),
                          _MetadataRow(
                            label: '进度',
                            value:
                                '${_formatDuration(snapshot.position)} / ${_formatDuration(snapshot.duration)}',
                          ),
                          _MetadataRow(
                            label: '已缓冲',
                            value: _formatDuration(snapshot.bufferedPosition),
                          ),
                          _MetadataRow(
                            label: '播放速度',
                            value: '${snapshot.rate.toStringAsFixed(2)}x',
                          ),
                          _MetadataRow(
                            label: '音量',
                            value: '${snapshot.volume.round()}%',
                          ),
                          _MetadataRow(
                            label: '画面模式',
                            value: _fitModeLabel(snapshot.fitMode),
                          ),
                          _MetadataRow(
                            label: '首帧',
                            value: snapshot.firstFrameReady ? '已显示' : '未显示',
                          ),
                          if (snapshot.failure != null)
                            _MetadataRow(
                              label: '错误',
                              value: _failureLabel(snapshot.failure!),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _DetailsHandle extends StatelessWidget {
  const _DetailsHandle();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10, bottom: 2),
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: videoPlayerSecondary.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(99),
        ),
        child: const SizedBox(width: 36, height: 4),
      ),
    ),
  );
}

final class _DetailsHeading extends StatelessWidget {
  const _DetailsHeading({
    required this.title,
    required this.subtitle,
    required this.status,
  });

  final String title;
  final String subtitle;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                key: const Key('video-details-title'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: videoPlayerForeground,
                  fontWeight: FontWeight.w600,
                  height: 1.18,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                subtitle,
                key: const Key('video-details-episode'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: videoPlayerSecondary,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        DecoratedBox(
          decoration: BoxDecoration(
            color: videoPlayerSelectedSurface,
            borderRadius: BorderRadius.circular(99),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            child: Text(
              status,
              key: const Key('video-details-status'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: videoPlayerAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => VideoPlayerGlassPanel(
    borderRadius: BorderRadius.circular(16),

    showShadow: false,
    padding: const EdgeInsets.fromLTRB(15, 13, 15, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: videoPlayerForeground,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        ...children,
      ],
    ),
  );
}

final class _DetailValueRow extends StatelessWidget {
  const _DetailValueRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.valueKey,
    required this.copyKey,
    required this.copyLabel,
    this.maxLines = 1,
  });

  final IconData icon;
  final String label;
  final String value;
  final Key valueKey;
  final Key copyKey;
  final String copyLabel;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Icon(icon, size: 20, color: videoPlayerAccent),
      const SizedBox(width: 9),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: videoPlayerSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  key: copyKey,
                  tooltip: copyLabel,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  onPressed: value.startsWith('尚未')
                      ? null
                      : () => _copyValue(context, value, '$label已复制'),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              value,
              key: valueKey,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: videoPlayerForeground,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

final class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: videoPlayerSecondary),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: videoPlayerForeground,
              height: 1.35,
            ),
          ),
        ),
      ],
    ),
  );
}

final class _DetailsDivider extends StatelessWidget {
  const _DetailsDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 11),
    child: Divider(height: 1),
  );
}

void _copyValue(BuildContext context, String value, String message) {
  Clipboard.setData(ClipboardData(text: value));
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
  );
}

String _episodeLabel(VideoPlayerSnapshot snapshot) {
  for (final group in snapshot.groups) {
    if (group.id != snapshot.activeGroupId) continue;
    for (final episode in group.episodes) {
      if (episode.id == snapshot.activeEpisodeId) {
        return '${group.title} · ${episode.title}';
      }
    }
  }
  return '尚未选择选集';
}

String _statusLabel(VideoPlayerSnapshot snapshot) {
  if (snapshot.failure != null) return '播放失败';
  if (snapshot.status == VideoPlayerStatus.loading) return '加载中';
  if (snapshot.status == VideoPlayerStatus.empty) return '无可播放内容';
  if (snapshot.buffering) return '缓冲中';
  if (snapshot.completed) return '已结束';
  return snapshot.playing ? '正在播放' : '已暂停';
}

String _failureLabel(VideoPlayerFailure failure) => [
  if (failure.code?.isNotEmpty == true) failure.code!,
  failure.message,
].join('：');

String _fitModeLabel(VideoFitMode mode) {
  switch (mode) {
    case VideoFitMode.contain:
      return '适应';
    case VideoFitMode.cover:
      return '填充';
    case VideoFitMode.stretch:
      return '拉伸';
  }
}

String _formatDuration(Duration duration) {
  final int total = duration.inSeconds.clamp(0, 359999);
  final int hours = total ~/ 3600;
  final int minutes = total.remainder(3600) ~/ 60;
  final int seconds = total.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
