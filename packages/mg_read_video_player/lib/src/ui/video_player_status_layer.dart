/// Package-private loading, empty and failure presentation for video sessions.
///
/// Responsibilities:
/// - Keep the first-frame placeholder visible until real video content arrives.
/// - Provide bounded retry and exit actions for terminal session states.
///
/// Notes:
/// - This layer contains no backend, persistence or host navigation logic.
library;

// Cross-file UI helpers are intentionally package-private despite Dart's
// library-level public naming rules.
// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import 'video_player_visuals.dart';

/// First-frame, empty and failure carrier shown above the video surface.
final class VideoSessionStatusLayer extends StatelessWidget {
  const VideoSessionStatusLayer({
    required this.snapshot,
    required this.onRetry,
    required this.onExit,
    required this.onEpisodes,
    super.key,
  });

  final VideoPlayerSnapshot snapshot;
  final Future<void> Function() onRetry;
  final Future<void> Function() onExit;
  final Future<void> Function() onEpisodes;

  @override
  Widget build(BuildContext context) {
    final bool failure = snapshot.status == VideoPlayerStatus.failure;
    final bool empty = snapshot.status == VideoPlayerStatus.empty;
    final String? failureLocation = snapshot.failure?.location;
    final String? failureCode = snapshot.failure?.code;
    return ColoredBox(
      color: videoPlayerBackground,
      child: Stack(
        children: <Widget>[
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: VideoPlayerGlassPanel(
              borderRadius: BorderRadius.zero,
              showBorder: false,
              showShadow: false,
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              child: Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  key: const Key('video-player-status-back'),
                  tooltip: '返回',
                  style: IconButton.styleFrom(
                    foregroundColor: videoPlayerForeground,
                  ),
                  onPressed: () => unawaited(onExit()),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
            ),
          ),
          Center(
            child: VideoPlayerGlassPanel(
              borderRadius: BorderRadius.circular(10),
              showShadow: false,
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    failure
                        ? Icons.error_outline_rounded
                        : empty
                        ? Icons.video_library_outlined
                        : Icons.movie_creation_outlined,
                    size: 38,
                    color: videoPlayerSecondary,
                  ),
                  const SizedBox(height: 10),
                  if (!failure && !empty)
                    const CircularProgressIndicator(
                      key: Key('video-player-loading'),
                      color: videoPlayerAccent,
                    ),
                  if (!failure && !empty) const SizedBox(height: 14),
                  Text(
                    failure
                        ? snapshot.failure?.message ?? '视频播放失败'
                        : empty
                        ? '暂无可播放选集'
                        : '正在准备视频',
                    key: const Key('video-player-status-message'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: videoPlayerForeground),
                  ),
                  if (failure && failureLocation != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      '发生位置：$failureLocation',
                      key: const Key('video-player-status-location'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: videoPlayerSecondary,
                      ),
                    ),
                  ],
                  if (failure && failureCode != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      '诊断编号：$failureCode',
                      key: const Key('video-player-status-code'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: videoPlayerSecondary,
                      ),
                    ),
                  ],
                  if (failure) ...<Widget>[
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: <Widget>[
                        if (snapshot.groups.any(
                          (group) => group.episodes.isNotEmpty,
                        ))
                          OutlinedButton.icon(
                            key: const Key('video-player-failure-episodes'),
                            onPressed: () => unawaited(onEpisodes()),
                            icon: const Icon(Icons.video_library_rounded),
                            label: const Text('切换选集'),
                          ),
                        FilledButton.icon(
                          key: const Key('video-player-retry'),
                          style: FilledButton.styleFrom(
                            backgroundColor: videoPlayerAccent,
                            foregroundColor: const Color(0xFF111214),
                          ),
                          onPressed: () => unawaited(onRetry()),
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('重试'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Maps public video fit semantics to Flutter surface layout.
BoxFit videoBoxFit(VideoFitMode mode) => switch (mode) {
  VideoFitMode.contain => BoxFit.contain,
  VideoFitMode.cover => BoxFit.cover,
  VideoFitMode.stretch => BoxFit.fill,
};
