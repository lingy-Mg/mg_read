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

typedef VideoEpisodeChoice = ({String groupId, String episodeId});

Future<VideoEpisodeChoice?> showVideoEpisodeSheet({
  required BuildContext context,
  required List<VideoEpisodeGroup> groups,
  required String? activeGroupId,
  required String? activeEpisodeId,
}) => showModalBottomSheet<VideoEpisodeChoice>(
  context: context,
  backgroundColor: const Color(0xFF17191C),
  useSafeArea: true,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _VideoEpisodeSheet(
    groups: groups,
    activeGroupId: activeGroupId,
    activeEpisodeId: activeEpisodeId,
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
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .82,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Text('选集', style: Theme.of(context).textTheme.titleLarge),
          ),
          if (widget.groups.isNotEmpty)
            SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  for (final item in widget.groups)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        key: Key('video-player-group-${item.id}'),
                        selected: item.id == _groupId,
                        label: Text(item.title),
                        onSelected: (_) => setState(() => _groupId = item.id),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: group == null || group.episodes.isEmpty
                ? const Center(child: Text('该分组暂无可播放选集'))
                : ListView.separated(
                    itemCount: group.episodes.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: Colors.white10),
                    itemBuilder: (BuildContext context, int index) {
                      final episode = group.episodes[index];
                      final selected =
                          group.id == widget.activeGroupId &&
                          episode.id == widget.activeEpisodeId;
                      return ListTile(
                        key: Key(
                          'video-player-episode-${group.id}-${episode.id}',
                        ),
                        selected: selected,
                        selectedColor: const Color(0xFFFFA43A),
                        leading: Icon(
                          selected
                              ? Icons.play_circle_fill_rounded
                              : Icons.play_circle_outline_rounded,
                        ),
                        title: Text(
                          episode.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.of(
                          context,
                        ).pop((groupId: group.id, episodeId: episode.id)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
