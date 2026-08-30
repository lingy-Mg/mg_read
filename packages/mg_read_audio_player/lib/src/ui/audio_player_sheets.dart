/// Bottom-sheet surface for long audio queues.
///
/// Responsibilities:
/// - Present a safe, scrollable chapter catalog and preserve locked entries.
///
/// Notes:
/// - Sheets issue commands through the public controller and own no media state.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/audio_controller.dart';
import '../api/audio_models.dart';
import 'audio_player_theme.dart';

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
    widget.controller.addListener(_handlePlayerChanged);
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
    widget.controller.removeListener(_handlePlayerChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _handlePlayerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final liveSnapshot = widget.controller.snapshot;
    final snapshot = liveSnapshot.status == AudioPlayerStatus.ready
        ? liveSnapshot
        : widget.snapshot;
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
                            playing: selected && snapshot.playing,
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
    required this.playing,
    required this.onTap,
    super.key,
  });

  final AudioQueueEntry entry;
  final int index;
  final bool selected;
  final bool playing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final titleStyle =
        (Theme.of(context).textTheme.bodyMedium ??
                DefaultTextStyle.of(context).style)
            .copyWith(
              color: entry.isLocked
                  ? AudioPlayerColors.subtle
                  : AudioPlayerColors.ink,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            );
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
                          ? _AudioPlayingIndicator(playing: playing)
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
                      selected
                          ? _OverflowingQueueTitle(
                              text: entry.title,
                              style: titleStyle,
                            )
                          : Text(
                              entry.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: titleStyle,
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

class _OverflowingQueueTitle extends StatelessWidget {
  const _OverflowingQueueTitle({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textPainter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final overflow = textPainter.width - constraints.maxWidth;
        if (overflow <= 0.5 || MediaQuery.disableAnimationsOf(context)) {
          return Text(
            text,
            key: const Key('audio-queue-current-title-static'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
        final duration = Duration(
          milliseconds: ((overflow / 24) * 1000).round().clamp(2400, 9000),
        );
        return SizedBox(
          key: const Key('audio-queue-current-title'),
          height: textPainter.height,
          child: ClipRect(
            child: _QueueTitleMarquee(
              distance: overflow,
              duration: duration,
              text: text,
              textWidth: textPainter.width,
              style: style,
            ),
          ),
        );
      },
    );
  }
}

class _QueueTitleMarquee extends StatefulWidget {
  const _QueueTitleMarquee({
    required this.distance,
    required this.duration,
    required this.text,
    required this.textWidth,
    required this.style,
  });

  final double distance;
  final Duration duration;
  final String text;
  final double textWidth;
  final TextStyle style;

  @override
  State<_QueueTitleMarquee> createState() => _QueueTitleMarqueeState();
}

class _QueueTitleMarqueeState extends State<_QueueTitleMarquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(vsync: this, duration: widget.duration)
      ..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _QueueTitleMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _animation.duration = widget.duration;
      _animation.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: widget.textWidth,
        maxWidth: widget.textWidth,
        child: Text(
          widget.text,
          key: const Key('audio-queue-current-title-marquee'),
          maxLines: 1,
          softWrap: false,
          style: widget.style,
        ),
      ),
      builder: (context, child) => Transform.translate(
        offset: Offset(-widget.distance * _animation.value, 0),
        child: child,
      ),
    );
  }
}

class _AudioPlayingIndicator extends StatefulWidget {
  const _AudioPlayingIndicator({required this.playing});

  final bool playing;

  @override
  State<_AudioPlayingIndicator> createState() => _AudioPlayingIndicatorState();
}

class _AudioPlayingIndicatorState extends State<_AudioPlayingIndicator>
    with SingleTickerProviderStateMixin {
  static const _barCount = 5;
  late final AnimationController _animation;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 820),
      value: 0.08,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _AudioPlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) _syncAnimation();
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  void _syncAnimation() {
    if (widget.playing && !_disableAnimations) {
      _animation.repeat();
      return;
    }
    _animation.stop();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.playing ? '正在播放' : '当前章节',
      child: SizedBox(
        key: const Key('audio-queue-playing-indicator'),
        width: 22,
        height: 20,
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List<Widget>.generate(_barCount, (index) {
                final phase = (_animation.value * math.pi * 2) + index * 1.14;
                final height = 5.0 + ((math.sin(phase) + 1) * 6.5);
                return SizedBox(
                  key: Key('audio-queue-playing-bar-$index'),
                  width: 2.4,
                  height: height,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                );
              }),
            );
          },
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
