/// Loading, empty and blocking-error surfaces for the audio player.
///
/// Responsibilities:
/// - Keep non-ready states visually consistent with the immersive player.
/// - Provide clear recovery and exit actions with diagnostic details.
///
library;

import 'package:flutter/material.dart';

import 'audio_player_artwork_stage.dart';
import 'audio_player_theme.dart';

final class AudioLoadingView extends StatelessWidget {
  const AudioLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const AudioPlayerAmbientBackground(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            child: Column(
              children: <Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const <Widget>[
                    _SkeletonCircle(size: 44),
                    _SkeletonBar(width: 132, height: 16),
                    _SkeletonCircle(size: 44),
                  ],
                ),
                const Spacer(),
                const _SkeletonCover(),
                const SizedBox(height: 28),
                const _SkeletonBar(width: 220, height: 18),
                const SizedBox(height: 12),
                const _SkeletonBar(width: 132, height: 13),
                const Spacer(),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: AudioPlayerColors.surface.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(
                      AudioPlayerMetrics.cardRadius,
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: AudioPlayerColors.accent,
                        ),
                      ),
                      SizedBox(width: 11),
                      Text('正在准备音频…'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final class AudioErrorView extends StatelessWidget {
  const AudioErrorView({
    required this.message,
    this.title = '暂时无法播放',
    this.location,
    this.diagnosticCode,
    required this.onBack,
    required this.onRetry,
    super.key,
  });

  final String title;
  final String message;
  final String? location;
  final String? diagnosticCode;
  final VoidCallback onBack;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const AudioPlayerAmbientBackground(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    key: const Key('audio-back'),
                    tooltip: '返回',
                    onPressed: onBack,
                    style: IconButton.styleFrom(
                      fixedSize: const Size.square(44),
                      backgroundColor: AudioPlayerColors.surface,
                      foregroundColor: AudioPlayerColors.ink,
                      side: const BorderSide(color: AudioPlayerColors.divider),
                    ),
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 20,
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
                        decoration: BoxDecoration(
                          color: AudioPlayerColors.surface,
                          borderRadius: BorderRadius.circular(
                            AudioPlayerMetrics.cardRadius,
                          ),
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: AudioPlayerColors.shadow,
                              blurRadius: 30,
                              offset: Offset(0, 14),
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Container(
                              width: 72,
                              height: 72,
                              decoration: const BoxDecoration(
                                color: AudioPlayerColors.warningSoft,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.headset_off_rounded,
                                size: 34,
                                color: AudioPlayerColors.warning,
                              ),
                            ),
                            const SizedBox(height: 20),
                            Text(
                              title,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: AudioPlayerColors.ink,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 9),
                            Text(
                              message,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: AudioPlayerColors.muted,
                                height: 1.55,
                              ),
                            ),
                            if (location != null || diagnosticCode != null) ...[
                              const SizedBox(height: 18),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(13),
                                decoration: BoxDecoration(
                                  color: AudioPlayerColors.control,
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    if (location != null)
                                      Text(
                                        '发生位置：$location',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: AudioPlayerColors.muted,
                                            ),
                                      ),
                                    if (location != null &&
                                        diagnosticCode != null)
                                      const SizedBox(height: 5),
                                    if (diagnosticCode != null)
                                      Text(
                                        '诊断编号：$diagnosticCode',
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: AudioPlayerColors.muted,
                                            ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 22),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                key: const Key('audio-retry'),
                                onPressed: onRetry,
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size.fromHeight(50),
                                  backgroundColor: AudioPlayerColors.accent,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(17),
                                  ),
                                ),
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('重新加载'),
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: onBack,
                              child: const Text('返回上一页'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SkeletonCover extends StatelessWidget {
  const _SkeletonCover();

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).height < 700;
    final size = compact ? 208.0 : 274.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AudioPlayerColors.control,
        borderRadius: BorderRadius.circular(32),
      ),
      child: const Icon(
        Icons.graphic_eq_rounded,
        size: 52,
        color: AudioPlayerColors.track,
      ),
    );
  }
}

class _SkeletonCircle extends StatelessWidget {
  const _SkeletonCircle({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: const BoxDecoration(
      color: AudioPlayerColors.control,
      shape: BoxShape.circle,
    ),
  );
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: AudioPlayerColors.control,
      borderRadius: BorderRadius.circular(99),
    ),
  );
}
