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

import 'package:flutter/material.dart';

import '../api/models.dart';
import 'video_player_visuals.dart';

typedef VideoEpisodeChoice = ({String groupId, String episodeId});

Future<VideoEpisodeChoice?> showVideoEpisodeSheet({
  required BuildContext context,
  required List<VideoEpisodeGroup> groups,
  required String? activeGroupId,
  required String? activeEpisodeId,
}) => showModalBottomSheet<VideoEpisodeChoice>(
  context: context,
  backgroundColor: Colors.transparent,
  barrierColor: const Color(0xA6000000),
  elevation: 0,
  useSafeArea: true,
  showDragHandle: false,
  isScrollControlled: true,
  builder: (_) => Theme(
    data: videoPlayerTheme(),
    child: _VideoEpisodeSheet(
      groups: groups,
      activeGroupId: activeGroupId,
      activeEpisodeId: activeEpisodeId,
    ),
  ),
);

final class _VideoEpisodeSheet extends StatefulWidget {
  const _VideoEpisodeSheet({
    required this.groups,
    required this.activeGroupId,
    required this.activeEpisodeId,
  });

  final List<VideoEpisodeGroup> groups;
  final String? activeGroupId;
  final String? activeEpisodeId;

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
    return VideoPlayerGlassPanel(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Align(
                child: SizedBox(
                  width: 36,
                  height: 4,
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
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.queue_play_next_rounded,
                    color: videoPlayerAccent,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '选集',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
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
                padding: const EdgeInsets.symmetric(horizontal: 16),
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
            const SizedBox(height: 8),
            Expanded(
              child: group == null || group.episodes.isEmpty
                  ? const Center(
                      child: Text(
                        '该分组暂无可播放选集',
                        style: TextStyle(color: videoPlayerSecondary),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 2, 12, 16),
                      itemCount: group.episodes.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (BuildContext context, int index) {
                        final episode = group.episodes[index];
                        final selected =
                            group.id == widget.activeGroupId &&
                            episode.id == widget.activeEpisodeId;
                        return Material(
                          color: Colors.transparent,
                          child: ListTile(
                            key: Key(
                              'video-player-episode-${group.id}-${episode.id}',
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: selected
                                    ? const Color(0x70FFA43A)
                                    : const Color(0x1FFFFFFF),
                              ),
                            ),
                            tileColor: const Color(0x14000000),
                            selectedTileColor: videoPlayerSelectedSurface,
                            selected: selected,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 3,
                            ),
                            leading: Icon(
                              selected
                                  ? Icons.play_circle_fill_rounded
                                  : Icons.play_circle_outline_rounded,
                              color: selected
                                  ? videoPlayerAccent
                                  : videoPlayerSecondary,
                            ),
                            title: Text(
                              episode.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: videoPlayerForeground,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            trailing: selected
                                ? const Icon(
                                    Icons.graphic_eq_rounded,
                                    color: videoPlayerAccent,
                                  )
                                : null,
                            onTap: () => Navigator.of(
                              context,
                            ).pop((groupId: group.id, episodeId: episode.id)),
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
    padding: const EdgeInsets.only(right: 8),
    child: FilterChip(
      key: Key('video-player-group-${group.id}'),
      selected: selected,
      showCheckmark: false,
      backgroundColor: const Color(0x1FFFFFFF),
      selectedColor: videoPlayerAccent,
      side: BorderSide(
        color: selected ? videoPlayerAccent : const Color(0x36FFFFFF),
      ),
      label: Text(
        group.title,
        style: TextStyle(
          color: selected ? const Color(0xFF111214) : videoPlayerForeground,
          fontWeight: FontWeight.w600,
        ),
      ),
      avatar: selected
          ? const Icon(Icons.check_rounded, size: 17, color: Color(0xFF111214))
          : null,
      onSelected: (_) => onSelected(),
    ),
  );
}
