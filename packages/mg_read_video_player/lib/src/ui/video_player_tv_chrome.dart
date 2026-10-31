/// Remote-first video controls; receives callbacks and owns no playback state.
/// Large buttons keep a visible focus ring; select maps to normal activation.
library;

// Internal package composition, not part of the public import surface.
// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api/models.dart';

class VideoPlayerTvChrome extends StatelessWidget {
  const VideoPlayerTvChrome({
    required this.snapshot,
    required this.playFocus,
    required this.onPlay,
    required this.onSeek,
    required this.onEpisodes,
    required this.onNext,
    required this.onPrevious,
    required this.onRate,
    required this.onFit,
    required this.onExit,
    required this.onReveal,
    super.key,
  });
  final VideoPlayerSnapshot snapshot;
  final FocusNode playFocus;
  final Future<void> Function() onPlay;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function() onEpisodes;
  final Future<void> Function() onNext;
  final Future<void> Function() onPrevious;
  final Future<void> Function(double) onRate;
  final Future<void> Function() onFit;
  final Future<void> Function() onExit;
  final Future<void> Function() onReveal;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
    },
    child: Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () => unawaited(onReveal()),
            behavior: HitTestBehavior.translucent,
          ),
        ),
        if (snapshot.controlsVisible)
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              color: const Color(0xE6101620),
              padding: const EdgeInsets.all(24),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      snapshot.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 26, color: Colors.white),
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: snapshot.duration.inMilliseconds > 0
                          ? (snapshot.position.inMilliseconds /
                                    snapshot.duration.inMilliseconds)
                                .clamp(0, 1)
                          : 0,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${_time(snapshot.position)} / ${_time(snapshot.duration)}',
                      style: const TextStyle(
                        fontSize: 20,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _button(
                          'tv-video-play',
                          snapshot.playing ? '暂停' : '播放',
                          onPlay,
                          focus: playFocus,
                        ),
                        _button(
                          'tv-video-backward',
                          '后退 10 秒',
                          () => onSeek(
                            snapshot.position - const Duration(seconds: 10),
                          ),
                        ),
                        _button(
                          'tv-video-forward',
                          '前进 10 秒',
                          () => onSeek(
                            snapshot.position + const Duration(seconds: 10),
                          ),
                        ),
                        _button('tv-video-episodes', '选集 / 线路', onEpisodes),
                        if (snapshot.hasPreviousEpisode)
                          _button('tv-video-previous', '上一集', onPrevious),
                        if (snapshot.hasNextEpisode)
                          _button('tv-video-next', '下一集', onNext),
                        _button(
                          'tv-video-rate',
                          '${snapshot.rate}× 倍速',
                          () => _chooseRate(context),
                        ),
                        _button('tv-video-fit', '画面比例', onFit),
                        _button('tv-video-exit', '退出播放', onExit),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '方向键 选择操作    OK 确认    返回 隐藏控制栏',
                      style: TextStyle(fontSize: 18, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _button(
    String key,
    String label,
    Future<void> Function() action, {
    FocusNode? focus,
  }) => FilledButton(
    key: Key(key),
    focusNode: focus,
    onPressed: () => unawaited(action()),
    style: ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(90, 56)),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 20)),
      side: WidgetStateProperty.resolveWith(
        (states) => BorderSide(
          color: states.contains(WidgetState.focused)
              ? Colors.white
              : Colors.transparent,
          width: 3,
        ),
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? const Color(0xFF316DCD)
            : const Color(0xFF263446),
      ),
      foregroundColor: const WidgetStatePropertyAll(Colors.white),
    ),
    child: Text(label),
  );

  Future<void> _chooseRate(BuildContext context) async {
    final rate = await showDialog<double>(
      context: context,
      builder: (context) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        },
        child: AlertDialog(
          title: const Text('播放速度'),
          content: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final value in [.5, 1.0, 1.25, 1.5, 2.0])
                TextButton(
                  autofocus: value == snapshot.rate,
                  onPressed: () => Navigator.pop(context, value),
                  child: Text('$value×', style: const TextStyle(fontSize: 24)),
                ),
            ],
          ),
        ),
      ),
    );
    if (rate != null && context.mounted) await onRate(rate);
  }

  String _time(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 999999);
    return '${seconds ~/ 3600}:${((seconds ~/ 60) % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
