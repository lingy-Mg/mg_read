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
