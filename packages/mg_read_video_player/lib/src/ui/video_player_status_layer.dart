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

/// First-frame, empty and failure carrier shown above the video surface.
final class VideoSessionStatusLayer extends StatelessWidget {
  const VideoSessionStatusLayer({
    required this.snapshot,
    required this.onRetry,
    required this.onExit,
    super.key,
  });

  final VideoPlayerSnapshot snapshot;
  final Future<void> Function() onRetry;
  final Future<void> Function() onExit;

  @override
  Widget build(BuildContext context) {
    final bool failure = snapshot.status == VideoPlayerStatus.failure;
    final bool empty = snapshot.status == VideoPlayerStatus.empty;
    return ColoredBox(
      color: const Color(0xFF090A0C),
      child: SafeArea(
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 8,
              top: 8,
              child: IconButton(
                key: const Key('video-player-status-back'),
                tooltip: '返回',
                onPressed: () => unawaited(onExit()),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      failure
                          ? Icons.error_outline_rounded
                          : empty
                          ? Icons.video_library_outlined
                          : Icons.movie_creation_outlined,
                      size: 52,
                      color: const Color(0xFFBEC1C7),
                    ),
                    const SizedBox(height: 16),
                    if (!failure && !empty)
                      const CircularProgressIndicator(
                        key: Key('video-player-loading'),
                        color: Color(0xFFFFA43A),
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
                    ),
                    if (failure && snapshot.failure?.location case final String location) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        '发生位置：$location',
                        key: const Key('video-player-status-location'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: Color(0xFFBEC1C7)),
                      ),
                    ],
                    if (failure && snapshot.failure?.code case final String code) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '诊断编号：$code',
                        key: const Key('video-player-status-code'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: Color(0xFFBEC1C7)),
                      ),
                    ],
                    if (failure) ...<Widget>[
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        key: const Key('video-player-retry'),
                        onPressed: () => unawaited(onRetry()),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重试'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Creates the isolated dark visual environment for video chrome.
ThemeData videoPlayerTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorSchemeSeed: const Color(0xFFFFA43A),
  );
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF050607),
    sliderTheme: base.sliderTheme.copyWith(
      activeTrackColor: const Color(0xFFFFA43A),
      thumbColor: const Color(0xFFFFA43A),
    ),
  );
}

/// Maps public video fit semantics to Flutter surface layout.
BoxFit videoBoxFit(VideoFitMode mode) => switch (mode) {
  VideoFitMode.contain => BoxFit.contain,
  VideoFitMode.cover => BoxFit.cover,
  VideoFitMode.stretch => BoxFit.fill,
};
