/// Cohesive playback-adjustment sheet for a single audio session.
///
/// Responsibilities:
/// - Present rate, volume and sleep-timer state as one compact control surface.
/// - Keep controls visually distinct while preserving stable automation keys.
/// - Forward changes immediately through the public player controller.
///
/// Notes:
/// - This package-private surface owns only optimistic sheet-local presentation.
/// - Compact phones may scroll the cards, while completion remains reachable.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/audio_controller.dart';
import '../api/audio_models.dart';
import 'audio_player_glass.dart';
import 'audio_player_theme.dart';

part 'audio_playback_settings_components.dart';

Future<void> showAudioPlaybackSettingsSheet(
  BuildContext context, {
  required AudioPlayerSnapshot snapshot,
  required AudioPlayerController controller,
  required bool keepScreenOn,
  Future<void> Function(bool enabled)? onKeepScreenOnChanged,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: AudioPlayerColors.scrim,
  builder: (sheetContext) => _AudioPlaybackSettingsSheet(
    snapshot: snapshot,
    controller: controller,
    keepScreenOn: keepScreenOn,
    onKeepScreenOnChanged: onKeepScreenOnChanged,
  ),
);

final class _AudioPlaybackSettingsSheet extends StatefulWidget {
  const _AudioPlaybackSettingsSheet({
    required this.snapshot,
    required this.controller,
    required this.keepScreenOn,
    this.onKeepScreenOnChanged,
  });

  final AudioPlayerSnapshot snapshot;
  final AudioPlayerController controller;
  final bool keepScreenOn;
  final Future<void> Function(bool enabled)? onKeepScreenOnChanged;

  @override
  State<_AudioPlaybackSettingsSheet> createState() =>
      _AudioPlaybackSettingsSheetState();
}

final class _AudioPlaybackSettingsSheetState
    extends State<_AudioPlaybackSettingsSheet> {
  static const _rates = <double>[0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3];
  static const _timers = <Duration?>[
    null,
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(minutes: 60),
    Duration(minutes: 90),
  ];

  late double _rate;
  late double _volume;
  late double _lastAudibleVolume;
  Duration? _timer;
  late bool _keepScreenOn;

  @override
  void initState() {
    super.initState();
    _rate = widget.snapshot.rate;
    _volume = widget.snapshot.volume.clamp(0, 1);
    _lastAudibleVolume = _volume > 0 ? _volume : 1;
    _timer = widget.snapshot.sleepTimerDuration;
    _keepScreenOn = widget.keepScreenOn;
  }

  @override
  Widget build(BuildContext context) {
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final heightFactor = viewportHeight < 660
        ? 0.96
        : viewportHeight < 780
        ? 0.90
        : 0.86;
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: heightFactor,
        alignment: Alignment.bottomCenter,
        child: AudioGlassPanel(
          key: const Key('audio-settings-sheet'),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AudioPlayerMetrics.sheetRadius),
          ),
          tone: AudioGlassTone.strong,
          blur: 28,
          child: Material(
            color: Colors.transparent,
            child: Column(
              children: <Widget>[
                const _SettingsHandle(),
                _SettingsHeader(onClose: _close),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
                  child: _SessionSummary(
                    rate: _rate,
                    volume: _volume,
                    timer: _timer,
                    disableAnimations: disableAnimations,
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('audio-settings-scroll'),
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Column(
                      children: <Widget>[
                        _SettingsCard(
                          key: const Key('audio-keep-screen-on'),
                          icon: Icons.light_mode_rounded,
                          title: '播放时防止自动锁屏',
                          value: _keepScreenOn ? '已开启' : '已关闭',
                          child: _KeepScreenOnControl(
                            enabled: _keepScreenOn,
                            onChanged: _setKeepScreenOn,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _SettingsCard(
                          key: const Key('audio-rate'),
                          icon: Icons.speed_rounded,
                          title: '播放速度',
                          value: '${formatAudioRate(_rate)}x',
                          child: _RateTrack(
                            rates: _rates,
                            selectedRate: _rate,
                            disableAnimations: disableAnimations,
                            onSelected: _setRate,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _SettingsCard(
                          key: const Key('audio-volume'),
                          icon: _volumeIcon,
                          title: '播放音量',
                          value: formatAudioVolume(_volume),
                          child: _VolumeControl(
                            volume: _volume,
                            onToggleMute: _toggleMute,
                            onChanged: _setVolume,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _SettingsCard(
                          key: const Key('audio-timer'),
                          icon: _timer == null
                              ? Icons.timer_outlined
                              : Icons.timer_rounded,
                          title: '定时停止',
                          value: _timerLabel,
                          child: _TimerSelector(
                            timers: _timers,
                            selectedTimer: _timer,
                            disableAnimations: disableAnimations,
                            onSelected: _setTimer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _SettingsFooter(onDone: _close),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _timerLabel => _timer == null ? '未开启' : '${_timer!.inMinutes} 分钟';

  IconData get _volumeIcon {
    if (_volume <= 0) return Icons.volume_off_rounded;
    if (_volume < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  void _setRate(double value) {
    setState(() => _rate = value);
    unawaited(widget.controller.setRate(value));
  }

  void _setVolume(double value) {
    setState(() {
      _volume = value;
      if (value > 0) _lastAudibleVolume = value;
    });
    unawaited(widget.controller.setVolume(value));
  }

  void _toggleMute() {
    final next = _volume > 0 ? 0.0 : math.max(0.1, _lastAudibleVolume);
    if (_volume > 0) _lastAudibleVolume = _volume;
    _setVolume(next);
  }

  void _setTimer(Duration? value) {
    setState(() => _timer = value);
    unawaited(widget.controller.setSleepTimer(value));
  }

  void _setKeepScreenOn(bool value) {
    final previous = _keepScreenOn;
    setState(() => _keepScreenOn = value);
    final callback = widget.onKeepScreenOnChanged;
    if (callback == null) return;
    unawaited(() async {
      try {
        await callback(value);
      } on Object {
        if (mounted) setState(() => _keepScreenOn = previous);
      }
    }());
  }

  void _close() => Navigator.of(context).pop();
}
