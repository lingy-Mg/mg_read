/// Deterministic TV detail/player metadata; never contacts a source or network.
library;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';

final tvDetailFixture = PluginContentDetail(
  pluginId: 'tv-fixture',
  sourceName: '影视测试源',
  summary: PluginContentSummary(
    id: 'show',
    title: '电视端影视详情与遥控选集',
    contentKind: PluginContentKind.video,
    author: null,
    url: null,
    coverUrl: null,
    description: '在电视上使用方向键选择影片与选集，按 OK 播放。简介可展开阅读，返回后继续操作。',
    language: 'zh-CN',
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.free,
    wordCount: null,
    chapterCount: 12,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const ['动画', '2026'],
    tags: const [],
    attributes: const [],
  ),
  aliases: const [],
  catalogUrl: null,
);

final tvCatalogFixture = PluginChaptersResult(
  pluginId: 'tv-fixture',
  sourceName: '影视测试源',
  items: tvGroupsFixture.expand((group) => group.episodes).toList(),
  groups: tvGroupsFixture,
);

final tvGroupsFixture = <PluginMediaGroup>[
  for (final group in ['a', 'b'])
    PluginMediaGroup(
      id: group,
      title: '播放源 $group',
      order: group == 'a' ? 0 : 1,
      episodes: List.generate(
        12,
        (i) => PluginChapterSummary(
          id: '$group-$i',
          title: '第 ${i + 1} 集',
          order: i,
          url: null,
          volumeTitle: group,
          wordCount: null,
          updatedAt: null,
          isLocked: false,
          attributes: const [],
        ),
      ),
    ),
];

class TvDetailFixtureGateway implements SourceContentGateway {
  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => tvDetailFixture;
  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => tvCatalogFixture;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TvDetailFixtureEntry extends StatefulWidget {
  const TvDetailFixtureEntry({required this.onPlay, this.onSave, this.onRemove, this.catalog, super.key});
  final SourceVideoEpisodeRequested onPlay;
  final PluginChaptersResult? catalog;
  final SourceShelfSaveRequested? onSave;
  final SourceShelfRemoveRequested? onRemove;
  @override
  State<TvDetailFixtureEntry> createState() => _TvDetailFixtureEntryState();
}

class _TvDetailFixtureEntryState extends State<TvDetailFixtureEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSourceContentDetailSheet(
        context,
        gateway: TvDetailFixtureGateway(),
        pluginId: 'tv-fixture',
        id: 'show',
        initialDetail: tvDetailFixture,
        initialCatalog: widget.catalog ?? tvCatalogFixture,
        refreshInitialContent: false,
        onVideoEpisodeRequested: widget.onPlay,
        onAddToShelf: widget.onSave,
        onRemoveFromShelf: widget.onRemove,
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

class TvFixtureVideoSource implements VideoDataSource {
  @override
  Future<VideoContent> load(String contentId) async => VideoContent(
    id: contentId,
    title: tvDetailFixture.summary.title,
    groups: [
      for (final group in tvCatalogFixture.groups)
        VideoEpisodeGroup(
          id: group.id,
          title: group.title,
          episodes: [
            for (final episode in group.episodes) VideoEpisode(id: episode.id, title: episode.title, uri: 'fixture:${episode.id}'),
          ],
        ),
    ],
  );
}

class TvFixtureVideoStore implements VideoPlaybackStateStore {
  VideoPlaybackProgress? saved;
  @override
  Future<VideoPlaybackProgress?> load(String contentId) async => null;
  @override
  Future<void> save(VideoPlaybackProgress progress) async => saved = progress;
}

/// Injected engine verifies UI and remote operations, not native decoding.
class TvFixtureVideoBackend implements VideoPlaybackBackend {
  @override
  final ValueNotifier<VideoPlaybackBackendState> state = ValueNotifier(const VideoPlaybackBackendState());
  @override
  Widget buildSurface({required BoxFit fit, Key? key}) => ColoredBox(key: key, color: const Color(0xFF142435));
  @override
  Future<void> open(VideoEpisode episode, {required Duration initialPosition, required bool play}) async {
    state.value = VideoPlaybackBackendState(
      playing: play,
      position: initialPosition,
      duration: const Duration(minutes: 24),
      firstFrameReady: true,
    );
  }

  @override
  Future<void> play() async => state.value = state.value.copyWith(playing: true);
  @override
  Future<void> pause() async => state.value = state.value.copyWith(playing: false);
  @override
  Future<void> seek(Duration position) async => state.value = state.value.copyWith(position: position);
  @override
  Future<void> setRate(double rate) async => state.value = state.value.copyWith(rate: rate);
  @override
  Future<void> setVolume(double volume) async => state.value = state.value.copyWith(volume: volume);
  @override
  Future<void> dispose() async => state.dispose();
}
