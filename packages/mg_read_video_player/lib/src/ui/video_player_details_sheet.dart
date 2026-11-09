/// Compact playback information and expandable session diagnostics.
///
/// Responsibilities:
/// - Present the current playback URL, request headers and session state.
/// - Keep copyable resources visible and technical identifiers behind disclosure.
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
import 'video_player_compact_panel.dart';

Future<void> showVideoDetailsSheet(
  BuildContext context, {
  required VideoPlayerController controller,
  required VideoEpisode? activeEpisode,
}) => showVideoPlayerModal<void>(
  context: context,
  maxWidth: 420,
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
    final episode = activeEpisode;
    final headers = episode == null || episode.httpHeaders.isEmpty
        ? '无'
        : const JsonEncoder.withIndent('  ').convert(episode.httpHeaders);
    return VideoPlayerCompactPanel(
      key: const Key('video-details-glass'),
      title: '视频详情',
      closeKey: const Key('video-details-close'),
      child: SingleChildScrollView(
        key: const Key('video-details-sheet'),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        snapshot.title.isEmpty ? '视频' : snapshot.title,
                        key: const Key('video-details-title'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: videoPlayerForeground,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _episodeLabel(snapshot),
                        key: const Key('video-details-episode'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: videoPlayerSecondary,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    _statusLabel(snapshot),
                    key: const Key('video-details-status'),
                    style: const TextStyle(
                      color: videoPlayerSecondary,
                      fontSize: 10,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            const _DetailsDivider(),
            const _SectionLabel('当前播放资源'),
            _DetailValueRow(
              key: const Key('video-details-url-row'),
              icon: Icons.link_rounded,
              label: '播放 URL',
              value: episode?.uri ?? '尚未解析到播放 URL',
              valueKey: const Key('video-details-url'),
              copyKey: const Key('video-details-url-copy'),
              copyLabel: '复制播放 URL',
            ),
            const SizedBox(height: 6),
            _DetailValueRow(
              key: const Key('video-details-headers-row'),
              icon: Icons.http_rounded,
              label: '请求头',
              value: headers,
              maxLines: 2,
              valueKey: const Key('video-details-headers'),
              copyKey: const Key('video-details-headers-copy'),
              copyLabel: '复制请求头',
            ),
            const _DetailsDivider(),
            _MetadataRow(
              label: '播放进度',
              value:
                  '${_formatDuration(snapshot.position)} / ${_formatDuration(snapshot.duration)}',
            ),
            _MetadataRow(
              label: '播放速度',
              value: '${snapshot.rate.toStringAsFixed(2)}×',
            ),
            _MetadataRow(label: '音量', value: '${snapshot.volume.round()}%'),
            _MetadataRow(label: '画面模式', value: _fitModeLabel(snapshot.fitMode)),
            if (snapshot.failure != null)
              _MetadataRow(
                label: '错误',
                value: _failureLabel(snapshot.failure!),
              ),
            const _DetailsDivider(),
            Theme(
              data: Theme.of(
                context,
              ).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: const Key('video-details-technical'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                dense: true,
                visualDensity: VisualDensity.compact,
                minTileHeight: videoPlayerUsesPointerControls(context)
                    ? 30
                    : 44,
                iconColor: videoPlayerSecondary,
                collapsedIconColor: videoPlayerSecondary,
                title: const Text(
                  '技术信息',
                  style: TextStyle(color: videoPlayerSecondary, fontSize: 11),
                ),
                children: [
                  _MetadataRow(label: '内容 ID', value: snapshot.contentId),
                  _MetadataRow(
                    label: '分组 ID',
                    value: snapshot.activeGroupId ?? '—',
                  ),
                  _MetadataRow(
                    label: '选集 ID',
                    value: snapshot.activeEpisodeId ?? '—',
                  ),
                  _MetadataRow(label: '选集标题', value: episode?.title ?? '—'),
                  _MetadataRow(
                    label: '已缓冲',
                    value: _formatDuration(snapshot.bufferedPosition),
                  ),
                  _MetadataRow(
                    label: '首帧',
                    value: snapshot.firstFrameReady ? '已显示' : '未显示',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      label,
      style: const TextStyle(
        color: videoPlayerSecondary,
        fontSize: 10,
        fontWeight: FontWeight.w500,
      ),
    ),
  );
}

final class _DetailValueRow extends StatelessWidget {
  const _DetailValueRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.valueKey,
    required this.copyKey,
    required this.copyLabel,
    this.maxLines = 1,
    super.key,
  });
  final IconData icon;
  final String label, value, copyLabel;
  final Key valueKey, copyKey;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final pointer = videoPlayerUsesPointerControls(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Icon(icon, size: 15, color: videoPlayerSecondary),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: videoPlayerSecondary,
                  fontSize: 10,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                key: valueKey,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: videoPlayerForeground,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          key: copyKey,
          tooltip: copyLabel,
          style: IconButton.styleFrom(
            foregroundColor: videoPlayerSecondary,
            minimumSize: Size.square(pointer ? 28 : 44),
            tapTargetSize: pointer
                ? MaterialTapTargetSize.shrinkWrap
                : MaterialTapTargetSize.padded,
            padding: const EdgeInsets.all(6),
          ),
          onPressed: value.startsWith('尚未')
              ? null
              : () => _copyValue(context, value, '$label已复制'),
          icon: const Icon(Icons.copy_outlined, size: 14),
        ),
      ],
    );
  }
}

final class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: const TextStyle(
              color: videoPlayerSecondary,
              fontSize: 11,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: videoPlayerForeground,
              fontSize: 11,
              height: 1.4,
              fontFeatures: [FontFeature.tabularFigures()],
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
    padding: EdgeInsets.symmetric(vertical: 10),
    child: Divider(height: 1, color: Color(0x14FFFFFF)),
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
