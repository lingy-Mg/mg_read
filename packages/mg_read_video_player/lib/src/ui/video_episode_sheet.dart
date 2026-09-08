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
  constraints: const BoxConstraints(maxWidth: double.infinity),
  builder: (_) => Theme(
    data: videoPlayerTheme(),
    child: _VideoEpisodeSheet(groups: groups, activeGroupId: activeGroupId, activeEpisodeId: activeEpisodeId),
  ),
);

final class _VideoEpisodeSheet extends StatefulWidget {
  const _VideoEpisodeSheet({required this.groups, required this.activeGroupId, required this.activeEpisodeId});

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
    final media = MediaQuery.of(context);
    final bool landscape = media.orientation == Orientation.landscape;
    return VideoPlayerGlassPanel(
      key: const Key('video-player-episode-sheet'),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      showBorder: false,
      blurSigma: 22,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * (landscape ? .86 : .7)),
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
                    decoration: BoxDecoration(color: Color(0x8CFFFFFF), borderRadius: BorderRadius.all(Radius.circular(99))),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.queue_play_next_rounded, color: videoPlayerAccent, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    '选集',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(color: videoPlayerForeground, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  Text('${group?.episodes.length ?? 0} 集', style: const TextStyle(color: videoPlayerSecondary, fontSize: 13)),
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
                      _GroupChip(group: item, selected: item.id == _groupId, onSelected: () => setState(() => _groupId = item.id)),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            const Divider(height: 1),
            Expanded(
              child: group == null || group.episodes.isEmpty
                  ? const Center(
                      child: Text('该分组暂无可播放选集', style: TextStyle(color: videoPlayerSecondary)),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final int columns = constraints.maxWidth >= 720 ? 2 : 1;
                        if (columns == 1) {
                          return ListView.separated(
                            padding: EdgeInsets.only(bottom: 8 + media.padding.bottom),
                            itemCount: group.episodes.length,
                            separatorBuilder: (_, _) => const Divider(height: 1, indent: 46),
                            itemBuilder: (context, index) => _EpisodeTile(
                              group: group,
                              episode: group.episodes[index],
                              selected: group.id == widget.activeGroupId && group.episodes[index].id == widget.activeEpisodeId,
                            ),
                          );
                        }
                        return GridView.builder(
                          padding: EdgeInsets.only(bottom: 8 + media.padding.bottom),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns, mainAxisExtent: 48),
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
                              selected: group.id == widget.activeGroupId && group.episodes[index].id == widget.activeEpisodeId,
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
  const _EpisodeTile({required this.group, required this.episode, required this.selected});

  final VideoEpisodeGroup group;
  final VideoEpisode episode;
  final bool selected;

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
        selected ? Icons.play_circle_fill_rounded : Icons.play_circle_outline_rounded,
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
      trailing: selected ? const Icon(Icons.graphic_eq_rounded, size: 19, color: videoPlayerAccent) : null,
      onTap: () => Navigator.of(context).pop((groupId: group.id, episodeId: episode.id)),
    ),
  );
}

final class _GroupChip extends StatelessWidget {
  const _GroupChip({required this.group, required this.selected, required this.onSelected});

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
        style: TextStyle(color: selected ? const Color(0xFF111214) : videoPlayerForeground, fontWeight: FontWeight.w600),
      ),
      avatar: selected ? const Icon(Icons.check_rounded, size: 16, color: Color(0xFF111214)) : null,
      onSelected: (_) => onSelected(),
    ),
  );
}
