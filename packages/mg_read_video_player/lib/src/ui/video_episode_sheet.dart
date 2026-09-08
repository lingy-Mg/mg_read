/// Group-first episode selector for package-owned video chrome.
///
/// Responsibilities:
/// - Select a generic host-defined group before listing its episodes.
/// - Return both identifiers so duplicate episode IDs across groups stay safe.
///
/// Notes:
/// - Group titles scroll horizontally and are never interpreted as seasons/lines.
/// - Episode rows bound long labels for narrow windows and large system text.
library;

// Cross-file UI helpers are intentionally package-private despite Dart naming.
// ignore_for_file: public_member_api_docs

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import 'video_player_visuals.dart';

typedef VideoEpisodeChoice = ({String groupId, String episodeId});

Future<VideoEpisodeChoice?> showVideoEpisodeSheet({
  required BuildContext context,
  required List<VideoEpisodeGroup> groups,
  required String? activeGroupId,
  required String? activeEpisodeId,
  required ValueListenable<VideoPlaybackBackendState> playbackState,
}) => showModalBottomSheet<VideoEpisodeChoice>(
  context: context,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0xA6000000),
  elevation: 0,
  useSafeArea: true,
  showDragHandle: false,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: double.infinity),
  builder: (_) => Theme(
    data: videoPlayerTheme(),
    child: _VideoEpisodeSheet(
      groups: groups,
      activeGroupId: activeGroupId,
      activeEpisodeId: activeEpisodeId,
      playbackState: playbackState,
    ),
  ),
);

final class _VideoEpisodeSheet extends StatefulWidget {
  const _VideoEpisodeSheet({
    required this.groups,
    required this.activeGroupId,
    required this.activeEpisodeId,
    required this.playbackState,
  });

  final List<VideoEpisodeGroup> groups;
  final String? activeGroupId;
  final String? activeEpisodeId;
  final ValueListenable<VideoPlaybackBackendState> playbackState;

  @override
  State<_VideoEpisodeSheet> createState() => _VideoEpisodeSheetState();
}

final class _VideoEpisodeSheetState extends State<_VideoEpisodeSheet> {
  late String? _groupId = _initialGroupId();

  String? _initialGroupId() {
    for (final group in widget.groups) {
      if (group.id == widget.activeGroupId) return group.id;
    }
    return widget.groups.isEmpty ? null : widget.groups.first.id;
  }

  VideoEpisodeGroup? get _group {
    for (final group in widget.groups) {
      if (group.id == _groupId) return group;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final media = MediaQuery.of(context);
    final bool landscape = media.orientation == Orientation.landscape;
    return VideoPlayerGlassPanel(
      key: const Key('video-player-episode-sheet'),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      showBorder: false,
      blurSigma: 22,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: media.size.height * (landscape ? .86 : .7),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Align(
                child: SizedBox(
                  width: 30,
                  height: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0x8CFFFFFF),
                      borderRadius: BorderRadius.all(Radius.circular(99)),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.queue_play_next_rounded,
                    color: videoPlayerAccent,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '选集',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: videoPlayerForeground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${group?.episodes.length ?? 0} 集',
                    style: const TextStyle(
                      color: videoPlayerSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            if (widget.groups.isNotEmpty)
              SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: <Widget>[
                    for (final item in widget.groups)
                      _GroupChip(
                        group: item,
                        selected: item.id == _groupId,
                        onSelected: () => setState(() => _groupId = item.id),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            const Divider(height: 1),
            Expanded(
              child: group == null || group.episodes.isEmpty
                  ? const Center(
                      child: Text(
                        '该分组暂无可播放选集',
                        style: TextStyle(color: videoPlayerSecondary),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final int columns = constraints.maxWidth >= 720 ? 2 : 1;
                        if (columns == 1) {
                          return ListView.separated(
                            padding: EdgeInsets.only(
                              bottom: 8 + media.padding.bottom,
                            ),
                            itemCount: group.episodes.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1, indent: 46),
                            itemBuilder: (context, index) => _EpisodeTile(
                              group: group,
                              episode: group.episodes[index],
                              selected:
                                  group.id == widget.activeGroupId &&
                                  group.episodes[index].id ==
                                      widget.activeEpisodeId,
                              playbackState: widget.playbackState,
                            ),
                          );
                        }
                        return GridView.builder(
                          padding: EdgeInsets.only(
                            bottom: 8 + media.padding.bottom,
                          ),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisExtent: 48,
                              ),
                          itemCount: group.episodes.length,
                          itemBuilder: (context, index) => DecoratedBox(
                            decoration: const BoxDecoration(
                              border: Border(
                                right: BorderSide(color: Color(0x18FFFFFF)),
                                bottom: BorderSide(color: Color(0x18FFFFFF)),
                              ),
                            ),
                            child: _EpisodeTile(
                              group: group,
                              episode: group.episodes[index],
                              selected:
                                  group.id == widget.activeGroupId &&
                                  group.episodes[index].id ==
                                      widget.activeEpisodeId,
                              playbackState: widget.playbackState,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.group,
    required this.episode,
    required this.selected,
    required this.playbackState,
  });

  final VideoEpisodeGroup group;
  final VideoEpisode episode;
  final bool selected;
  final ValueListenable<VideoPlaybackBackendState> playbackState;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: ListTile(
      key: Key('video-player-episode-${group.id}-${episode.id}'),
      dense: true,
      visualDensity: VisualDensity.compact,
      minLeadingWidth: 24,
      minVerticalPadding: 0,
      tileColor: Colors.transparent,
      selectedTileColor: videoPlayerSelectedSurface,
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(
        selected
            ? Icons.play_circle_fill_rounded
            : Icons.play_circle_outline_rounded,
        size: 21,
        color: selected ? videoPlayerAccent : videoPlayerSecondary,
      ),
      title: Text(
        episode.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: selected ? videoPlayerForeground : videoPlayerSecondary,
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      trailing: selected
          ? _VideoEpisodePlayingIndicator(playbackState: playbackState)
          : null,
      onTap: () =>
          Navigator.of(context).pop((groupId: group.id, episodeId: episode.id)),
    ),
  );
}

final class _VideoEpisodePlayingIndicator extends StatefulWidget {
  const _VideoEpisodePlayingIndicator({required this.playbackState});

  final ValueListenable<VideoPlaybackBackendState> playbackState;

  @override
  State<_VideoEpisodePlayingIndicator> createState() =>
      _VideoEpisodePlayingIndicatorState();
}

final class _VideoEpisodePlayingIndicatorState
    extends State<_VideoEpisodePlayingIndicator>
    with SingleTickerProviderStateMixin {
  static const _barLevels = <List<double>>[
    <double>[.18, .76, .42, .94, .31, .63, .24],
    <double>[.58, .22, .84, .37, .69, .16, .91, .46, .28],
    <double>[.33, .88, .19, .56, .97, .41],
    <double>[.81, .35, .62, .14, .73, .27, .92, .48],
    <double>[.26, .67, .39, .86, .18, .52, .95, .32, .71, .21],
  ];
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1160),
    value: .08,
  );
  late bool _playing;
  bool _disableAnimations = false;

  @override
  void initState() {
    super.initState();
    _playing = widget.playbackState.value.playing;
    widget.playbackState.addListener(_handlePlaybackStateChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _VideoEpisodePlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playbackState == widget.playbackState) return;
    oldWidget.playbackState.removeListener(_handlePlaybackStateChanged);
    widget.playbackState.addListener(_handlePlaybackStateChanged);
    _playing = widget.playbackState.value.playing;
    _syncAnimation();
  }

  @override
  void dispose() {
    widget.playbackState.removeListener(_handlePlaybackStateChanged);
    _animation.dispose();
    super.dispose();
  }

  void _handlePlaybackStateChanged() {
    final playing = widget.playbackState.value.playing;
    if (playing == _playing) return;
    setState(() => _playing = playing);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (_playing && !_disableAnimations) {
      _animation.repeat();
      return;
    }
    _animation.stop();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: _playing ? '正在播放' : '当前选集',
    child: SizedBox(
      key: const Key('video-player-episode-playing-indicator'),
      width: 22,
      height: 18,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (context, child) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List<Widget>.generate(_barLevels.length, (index) {
            final height = 4 + _irregularBarAmount(index) * 12;
            return SizedBox(
              key: Key('video-player-episode-playing-bar-$index'),
              width: 2.4,
              height: height,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  color: videoPlayerAccent,
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
            );
          }),
        ),
      ),
    ),
  );

  double _irregularBarAmount(int index) {
    final levels = _barLevels[index];
    final position = _animation.value * levels.length;
    final current = position.floor() % levels.length;
    final next = (current + 1) % levels.length;
    final eased = Curves.easeInOutCubic.transform(position - position.floor());
    return levels[current] + (levels[next] - levels[current]) * eased;
  }
}

final class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.group,
    required this.selected,
    required this.onSelected,
  });

  final VideoEpisodeGroup group;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: FilterChip(
      key: Key('video-player-group-${group.id}'),
      selected: selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      backgroundColor: const Color(0x14000000),
      selectedColor: videoPlayerAccent,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      label: Text(
        group.title,
        style: TextStyle(
          color: selected ? const Color(0xFF111214) : videoPlayerForeground,
          fontWeight: FontWeight.w600,
        ),
      ),
      avatar: selected
          ? const Icon(Icons.check_rounded, size: 16, color: Color(0xFF111214))
          : null,
      onSelected: (_) => onSelected(),
    ),
  );
}
