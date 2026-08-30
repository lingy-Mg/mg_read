/// Bottom-sheet details for the audio collection and active chapter.
///
/// Responsibilities:
/// - Present only metadata already available in the live player snapshot.
/// - Show the active chapter resource and a clearly unavailable comment area.
///
/// Notes:
/// - The sheet owns no media state and performs no host or network I/O.
library;

import 'package:flutter/material.dart';

import '../api/audio_artwork.dart';
import '../api/audio_controller.dart';
import '../api/audio_models.dart';
import 'audio_player_artwork_stage.dart';
import 'audio_player_theme.dart';

Future<void> showAudioDetailsSheet(
  BuildContext context, {
  required AudioPlayerSnapshot snapshot,
  required AudioPlayerController controller,
  required AudioArtworkBuilder? artworkBuilder,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  barrierColor: AudioPlayerColors.scrim,
  builder: (sheetContext) => ListenableBuilder(
    listenable: controller,
    builder: (context, child) {
      final liveSnapshot = controller.snapshot;
      return _AudioDetailsSheet(
        snapshot: liveSnapshot.status == AudioPlayerStatus.ready
            ? liveSnapshot
            : snapshot,
        artworkBuilder: artworkBuilder,
      );
    },
  ),
);

class _AudioDetailsSheet extends StatelessWidget {
  const _AudioDetailsSheet({
    required this.snapshot,
    required this.artworkBuilder,
  });

  final AudioPlayerSnapshot snapshot;
  final AudioArtworkBuilder? artworkBuilder;

  @override
  Widget build(BuildContext context) {
    final track = snapshot.currentTrack;
    if (track == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final collectionTitle = _firstVisibleText(<String?>[
      track.collectionTitle,
      snapshot.collectionTitle,
      track.title,
    ]);
    final creator = _firstVisibleText(<String?>[
      track.creator,
      snapshot.creator,
    ]);
    final catalogIndex = snapshot.queueEntries.indexWhere(
      (entry) => entry.id == track.id,
    );
    final displayedIndex = catalogIndex >= 0
        ? catalogIndex
        : snapshot.currentIndex;
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _DetailsHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 12, 10),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '音频详情',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: AudioPlayerColors.ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('audio-details-close'),
                      tooltip: '关闭音频详情',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AudioPlayerColors.divider),
              Expanded(
                child: ListView(
                  key: const Key('audio-details-sheet'),
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ClipRRect(
                          key: const Key('audio-details-artwork'),
                          borderRadius: BorderRadius.circular(18),
                          child: SizedBox.square(
                            dimension: 104,
                            child:
                                artworkBuilder?.call(context, track) ??
                                const AudioPlayerCoverPlaceholder(),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                collectionTitle,
                                key: const Key('audio-details-title'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: AudioPlayerColors.ink,
                                  fontWeight: FontWeight.w800,
                                  height: 1.18,
                                ),
                              ),
                              if (creator.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 9),
                                Text(
                                  '作者 / 播讲：$creator',
                                  key: const Key('audio-details-creator'),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: AudioPlayerColors.muted,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: AudioPlayerColors.accentSoft,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 11,
                                    vertical: 5,
                                  ),
                                  child: Text(
                                    snapshot.playing ? '正在播放' : '已暂停',
                                    key: const Key('audio-details-status'),
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(
                                          color:
                                              AudioPlayerColors.accentPressed,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: AudioPlayerColors.control.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Row(
                          children: <Widget>[
                            _DetailStat(
                              label: '当前',
                              value: '第 ${displayedIndex + 1} 集',
                            ),
                            const _DetailStatDivider(),
                            _DetailStat(
                              label: '总集数',
                              value: '${snapshot.queueEntries.length} 集',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      '当前章节',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: AudioPlayerColors.ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: AudioPlayerColors.accentSoft.withValues(
                          alpha: 0.58,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(15),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text(
                              track.title,
                              key: const Key('audio-details-current-track'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: AudioPlayerColors.ink,
                                fontWeight: FontWeight.w700,
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              '第 ${displayedIndex + 1} 集',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AudioPlayerColors.accentPressed,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 14),
                            const Divider(
                              height: 1,
                              color: AudioPlayerColors.divider,
                            ),
                            const SizedBox(height: 13),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const Icon(
                                  Icons.link_rounded,
                                  size: 20,
                                  color: AudioPlayerColors.accent,
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        '章节地址',
                                        style: theme.textTheme.labelMedium
                                            ?.copyWith(
                                              color: AudioPlayerColors.muted,
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                      const SizedBox(height: 5),
                                      SelectableText(
                                        track.resource.toString(),
                                        key: const Key(
                                          'audio-details-resource',
                                        ),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: AudioPlayerColors.ink,
                                              height: 1.45,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            '评论',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: AudioPlayerColors.ink,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: AudioPlayerColors.control,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            child: Text(
                              '即将开放',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: AudioPlayerColors.muted,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    DecoratedBox(
                      key: const Key('audio-details-comment-composer'),
                      decoration: BoxDecoration(
                        color: AudioPlayerColors.control.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(13),
                        child: Row(
                          children: <Widget>[
                            const CircleAvatar(
                              radius: 18,
                              backgroundColor: AudioPlayerColors.accentSoft,
                              foregroundColor: AudioPlayerColors.accent,
                              child: Icon(
                                Icons.person_outline_rounded,
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Text(
                                '说说你对本集的看法…',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: AudioPlayerColors.subtle,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: null,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(58, 38),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                              ),
                              child: const Text('发布'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DecoratedBox(
                      key: const Key('audio-details-comments-placeholder'),
                      decoration: BoxDecoration(
                        color: AudioPlayerColors.surfaceStrong,
                        border: Border.all(color: AudioPlayerColors.divider),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 18,
                        ),
                        child: Row(
                          children: <Widget>[
                            const Icon(
                              Icons.chat_bubble_outline_rounded,
                              color: AudioPlayerColors.subtle,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '评论功能正在准备中',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: AudioPlayerColors.ink,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '后续可在这里查看并发表本集评论',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: AudioPlayerColors.muted,
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
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailStat extends StatelessWidget {
  const _DetailStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: <Widget>[
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge?.copyWith(
              color: AudioPlayerColors.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AudioPlayerColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailStatDivider extends StatelessWidget {
  const _DetailStatDivider();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 34,
      child: VerticalDivider(width: 1, color: AudioPlayerColors.divider),
    );
  }
}

class _DetailsHandle extends StatelessWidget {
  const _DetailsHandle();

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

String _firstVisibleText(Iterable<String?> candidates) {
  for (final candidate in candidates) {
    final value = candidate?.trim();
    if (value?.isNotEmpty == true) return value!;
  }
  return '';
}
