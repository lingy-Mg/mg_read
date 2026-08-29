/// Small audio-only controls and visual tokens shared within the player UI.
///
/// Responsibilities:
/// - Keep utility controls, loading/error states and formatting out of the page.
/// - Preserve the package's light cover-led visual language.
///
/// Notes:
/// - This internal library is not exported from the package public entrypoint.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/audio_models.dart';

final class AudioUtilityControls extends StatelessWidget {
  const AudioUtilityControls({
    required this.snapshot,
    required this.onRate,
    required this.onTimer,
    required this.onQueue,
    super.key,
  });

  final AudioPlayerSnapshot snapshot;
  final VoidCallback onRate;
  final VoidCallback onTimer;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceEvenly,
      spacing: 12,
      runSpacing: 10,
      children: <Widget>[
        _UtilityButton(
          key: const Key('audio-rate'),
          icon: Icons.speed_rounded,
          label: '${_formatRate(snapshot.rate)}x',
          onPressed: onRate,
        ),
        _UtilityButton(
          key: const Key('audio-timer'),
          icon: snapshot.sleepTimerDuration == null
              ? Icons.timer_outlined
              : Icons.timer_rounded,
          label: snapshot.sleepTimerDuration == null
              ? '定时'
              : '${snapshot.sleepTimerDuration!.inMinutes} 分钟',
          onPressed: onTimer,
        ),
        _UtilityButton(
          key: const Key('audio-queue'),
          icon: Icons.queue_music_rounded,
          label: '队列 ${snapshot.queue.length}',
          onPressed: onQueue,
        ),
      ],
    );
  }
}

class _UtilityButton extends StatelessWidget {
  const _UtilityButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: AudioPlayerColors.ink,
        backgroundColor: AudioPlayerColors.control,
        minimumSize: const Size(96, 46),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}

final class AudioLoadingView extends StatelessWidget {
  const AudioLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(color: AudioPlayerColors.accent),
          SizedBox(height: 16),
          Text('正在准备音频…'),
        ],
      ),
    );
  }
}

final class AudioErrorView extends StatelessWidget {
  const AudioErrorView({
    required this.message,
    required this.onBack,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onBack;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: '返回',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
            ),
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.music_off_rounded,
                    size: 58,
                    color: AudioPlayerColors.muted,
                  ),
                  const SizedBox(height: 16),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    key: const Key('audio-retry'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

abstract final class AudioPlayerColors {
  static const background = Color(0xFFFFFBF5);
  static const sheet = Color(0xFFFFFCF8);
  static const ink = Color(0xFF2B2118);
  static const muted = Color(0xFF8A7C70);
  static const accent = Color(0xFFC9792B);
  static const warning = Color(0xFFB65332);
  static const track = Color(0xFFE9DED1);
  static const control = Color(0xFFF6EDE2);
  static const coverStart = Color(0xFFE69B49);
  static const coverEnd = Color(0xFF7B4934);
}

String formatAudioDuration(Duration value) {
  final totalSeconds = math.max(0, value.inSeconds);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _formatRate(double rate) {
  final rounded = rate.toStringAsFixed(2);
  return rounded
      .replaceFirst(RegExp(r'\.0+$'), '')
      .replaceFirst(RegExp(r'(\.\d*[1-9])0+$'), r'$1');
}
