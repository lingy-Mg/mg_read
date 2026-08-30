/// Bottom-sheet surfaces for playback settings and long audio queues.
///
/// Responsibilities:
/// - Expose precise local playback controls without expanding the main page.
/// - Present a safe, scrollable chapter catalog and preserve locked entries.
///
/// Notes:
/// - Sheets issue commands through the public controller and own no media state.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/audio_controller.dart';
import '../api/audio_models.dart';
import 'audio_player_theme.dart';

Future<void> showAudioPlaybackSettingsSheet(
  BuildContext context, {
  required AudioPlayerSnapshot snapshot,
  required AudioPlayerController controller,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: AudioPlayerColors.scrim,
  builder: (sheetContext) =>
      _AudioPlaybackSettingsSheet(snapshot: snapshot, controller: controller),
);

Future<void> showAudioQueueSheet(
  BuildContext context, {
  required AudioPlayerSnapshot snapshot,
  required AudioPlayerController controller,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: AudioPlayerColors.scrim,
  builder: (sheetContext) =>
      _AudioQueueSheet(snapshot: snapshot, controller: controller),
);

class _AudioPlaybackSettingsSheet extends StatefulWidget {
  const _AudioPlaybackSettingsSheet({
    required this.snapshot,
    required this.controller,
  });

  final AudioPlayerSnapshot snapshot;
  final AudioPlayerController controller;

  @override
  State<_AudioPlaybackSettingsSheet> createState() =>
      _AudioPlaybackSettingsSheetState();
}

class _AudioPlaybackSettingsSheetState
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

  @override
  void initState() {
    super.initState();
    _rate = widget.snapshot.rate;
    _volume = widget.snapshot.volume.clamp(0, 1);
    _lastAudibleVolume = _volume > 0 ? _volume : 1;
    _timer = widget.snapshot.sleepTimerDuration;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.82,
        alignment: Alignment.bottomCenter,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: AudioPlayerColors.surface,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(AudioPlayerMetrics.sheetRadius),
            ),
          ),
          child: Column(
            children: <Widget>[
              const _SheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 16, 14),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '播放设置',
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: AudioPlayerColors.ink,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '调整只作用于当前播放会话',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AudioPlayerColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('audio-settings-close'),
                      tooltip: '完成',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AudioPlayerColors.divider),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _SettingsSection(
                        key: const Key('audio-rate'),
                        icon: Icons.speed_rounded,
                        title: '播放速度',
                        value: '${formatAudioRate(_rate)}x',
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 9,
                          children: <Widget>[
                            for (final rate in _rates)
                              ChoiceChip(
                                key: Key('audio-rate-${(rate * 100).round()}'),
                                label: Text('${formatAudioRate(rate)}x'),
                                selected: (_rate - rate).abs() < 0.01,
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() => _rate = rate);
                                  unawaited(widget.controller.setRate(rate));
                                },
                                selectedColor: AudioPlayerColors.accentSoft,
                                side: BorderSide(
                                  color: (_rate - rate).abs() < 0.01
                                      ? AudioPlayerColors.accent
                                      : AudioPlayerColors.divider,
                                ),
                                labelStyle: theme.textTheme.labelLarge
                                    ?.copyWith(
                                      color: (_rate - rate).abs() < 0.01
                                          ? AudioPlayerColors.accentPressed
                                          : AudioPlayerColors.ink,
                                    ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                      _SettingsSection(
                        key: const Key('audio-volume'),
                        icon: _volumeIcon,
                        title: '播放音量',
                        value: formatAudioVolume(_volume),
                        child: Row(
                          children: <Widget>[
                            IconButton(
                              key: const Key('audio-volume-mute'),
                              tooltip: _volume > 0 ? '静音' : '恢复音量',
                              onPressed: _toggleMute,
                              icon: Icon(
                                _volume > 0
                                    ? Icons.volume_up_rounded
                                    : Icons.volume_off_rounded,
                              ),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  activeTrackColor: AudioPlayerColors.accent,
                                  inactiveTrackColor: AudioPlayerColors.track,
                                  thumbColor: AudioPlayerColors.accent,
                                  overlayColor: AudioPlayerColors.accentSoft,
                                  trackHeight: 5,
                                ),
                                child: Slider(
                                  key: const Key('audio-volume-slider'),
                                  value: _volume,
                                  onChanged: (value) {
                                    setState(() {
                                      _volume = value;
                                      if (value > 0) {
                                        _lastAudibleVolume = value;
                                      }
                                    });
                                    unawaited(
                                      widget.controller.setVolume(value),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 26),
                      _SettingsSection(
                        key: const Key('audio-timer'),
                        icon: _timer == null
                            ? Icons.timer_outlined
                            : Icons.timer_rounded,
                        title: '定时停止',
                        value: _timer == null
                            ? '未开启'
                            : '${_timer!.inMinutes} 分钟',
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 9,
                          children: <Widget>[
                            for (final timer in _timers)
                              ChoiceChip(
                                key: Key(
                                  timer == null
                                      ? 'audio-timer-off'
                                      : 'audio-timer-${timer.inMinutes}',
                                ),
                                label: Text(
                                  timer == null
                                      ? '关闭'
                                      : '${timer.inMinutes} 分钟',
                                ),
                                selected: _timer == timer,
                                showCheckmark: false,
                                onSelected: (_) {
                                  setState(() => _timer = timer);
                                  unawaited(
                                    widget.controller.setSleepTimer(timer),
                                  );
                                },
                                selectedColor: AudioPlayerColors.accentSoft,
                                side: BorderSide(
                                  color: _timer == timer
                                      ? AudioPlayerColors.accent
                                      : AudioPlayerColors.divider,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData get _volumeIcon {
    if (_volume <= 0) return Icons.volume_off_rounded;
    if (_volume < 0.5) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  void _toggleMute() {
    final next = _volume > 0 ? 0.0 : math.max(0.1, _lastAudibleVolume);
    if (_volume > 0) _lastAudibleVolume = _volume;
    setState(() => _volume = next);
    unawaited(widget.controller.setVolume(next));
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.value,
    required this.child,
    super.key,
  });

  final IconData icon;
  final String title;
  final String value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 21, color: AudioPlayerColors.accent),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AudioPlayerColors.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              value,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: AudioPlayerColors.accentPressed,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    );
  }
}

class _AudioQueueSheet extends StatefulWidget {
  const _AudioQueueSheet({required this.snapshot, required this.controller});

  final AudioPlayerSnapshot snapshot;
  final AudioPlayerController controller;

  @override
  State<_AudioQueueSheet> createState() => _AudioQueueSheetState();
}

class _AudioQueueSheetState extends State<_AudioQueueSheet> {
  static const _itemExtent = 76.0;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    final currentIndex = widget.snapshot.queueEntries.indexWhere(
      (entry) => entry.id == widget.snapshot.currentTrack?.id,
    );
    _scrollController = ScrollController(
      initialScrollOffset: currentIndex <= 1
          ? 0
          : math.max(0, currentIndex * _itemExtent - _itemExtent),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.92,
        alignment: Alignment.bottomCenter,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: AudioPlayerColors.surface,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(AudioPlayerMetrics.sheetRadius),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _SheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 16, 14),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '章节列表',
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  color: AudioPlayerColors.ink,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '共 ${snapshot.queueEntries.length} 集',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: AudioPlayerColors.muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('audio-queue-close'),
                      tooltip: '关闭章节列表',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AudioPlayerColors.divider),
              Expanded(
                child: snapshot.queueEntries.isEmpty
                    ? const Center(child: Text('暂无可播放章节'))
                    : ListView.builder(
                        key: const Key('audio-queue-list'),
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemExtent: _itemExtent,
                        itemCount: snapshot.queueEntries.length,
                        itemBuilder: (context, index) {
                          final entry = snapshot.queueEntries[index];
                          final selected =
                              entry.id == snapshot.currentTrack?.id;
                          return _AudioQueueTile(
                            key: Key('audio-queue-track-${entry.id}'),
                            entry: entry,
                            index: index,
                            selected: selected,
                            onTap: entry.isLocked
                                ? null
                                : () async {
                                    if (!selected) {
                                      await widget.controller.selectQueueEntry(
                                        entry.id,
                                      );
                                    }
                                    if (context.mounted) {
                                      Navigator.of(context).pop();
                                    }
                                  },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioQueueTile extends StatelessWidget {
  const _AudioQueueTile({
    required this.entry,
    required this.index,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final AudioQueueEntry entry;
  final int index;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: selected ? AudioPlayerColors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            child: Row(
              children: <Widget>[
                SizedBox.square(
                  dimension: 38,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: selected
                          ? AudioPlayerColors.accent
                          : AudioPlayerColors.control,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: selected
                          ? const Icon(
                              Icons.graphic_eq_rounded,
                              color: Colors.white,
                              size: 20,
                            )
                          : Text(
                              '${index + 1}',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: entry.isLocked
                                        ? AudioPlayerColors.subtle
                                        : AudioPlayerColors.ink,
                                  ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: entry.isLocked
                              ? AudioPlayerColors.subtle
                              : AudioPlayerColors.ink,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.isLocked
                            ? '需解锁后播放'
                            : selected
                            ? '正在播放'
                            : entry.creator ?? '可播放',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: selected
                              ? AudioPlayerColors.accentPressed
                              : AudioPlayerColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  entry.isLocked
                      ? Icons.lock_outline_rounded
                      : Icons.play_arrow_rounded,
                  size: 20,
                  color: selected
                      ? AudioPlayerColors.accent
                      : AudioPlayerColors.subtle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 38,
        height: 4,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AudioPlayerColors.track,
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    );
  }
}
