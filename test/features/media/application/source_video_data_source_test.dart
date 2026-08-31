/// Safe diagnostic tests for the source-to-video-player adapter.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_video_data_source.dart';

void main() {
  test('loads catalog metadata without resolving every signed resource', () async {
    final gateway = _VideoGateway(failEpisodeResource: false);
    final source = SourceVideoDataSource(gateway: gateway, pluginId: _pluginId);

    final content = await source.load('video-1');

    expect(gateway.contentCalls, isEmpty);
    expect(content.groups.single.episodes.single.uri, isNull);
  });

  test('resolves only the explicitly selected episode', () async {
    final gateway = _VideoGateway(failEpisodeResource: false);
    final source = SourceVideoDataSource(gateway: gateway, pluginId: _pluginId);
    await source.load('video-1');

    final episode = await source.loadEpisode('video-1', groupId: 'default', episodeId: 'episode-1');

    expect(gateway.contentCalls, <String>['episode-1']);
    expect(episode.uri, 'http://127.0.0.1/source-resource/episode-1');
    expect(episode.httpHeaders['Referer'], 'https://source.example/');
  });

  test('redacts a selected video resource failure with a stable location', () async {
    final gateway = _VideoGateway(failEpisodeResource: true);
    final source = SourceVideoDataSource(gateway: gateway, pluginId: _pluginId);
    await source.load('video-1');

    await expectLater(
      source.loadEpisode('video-1', groupId: 'default', episodeId: 'episode-1'),
      throwsA(
        isA<VideoPlayerLoadException>()
            .having((failure) => failure.code, 'code', 'video_episode_resource_load_failed')
            .having((failure) => failure.location, 'location', '请求选集播放资源')
            .having((failure) => failure.message, 'message', '所选集的播放资源暂时无法获取，请稍后重试。'),
      ),
    );
  });
}

const _pluginId = 'org.example.video';

final class _VideoGateway implements SourceContentGateway {
  _VideoGateway({required this.failEpisodeResource});

  final bool failEpisodeResource;
  final List<String> contentCalls = <String>[];

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => PluginContentDetail(
    pluginId: pluginId,
    sourceName: '示例视频源',
    summary: PluginContentSummary(
      id: id,
      title: '测试视频',
      contentKind: PluginContentKind.video,
      author: null,
      url: null,
      coverUrl: null,
      description: null,
      language: null,
      status: PluginContentStatus.unknown,
      access: PluginAccessKind.free,
      wordCount: null,
      chapterCount: 1,
      publishedAt: null,
      updatedAt: null,
      latestChapter: null,
      categories: const <String>[],
      tags: const <String>[],
      attributes: const <PluginContentAttribute>[],
    ),
    aliases: const <String>[],
    catalogUrl: null,
  );

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => PluginChaptersResult(
    pluginId: pluginId,
    sourceName: '示例视频源',
    items: <PluginChapterSummary>[
      PluginChapterSummary(
        id: 'episode-1',
        title: '第 1 集',
        order: 0,
        url: null,
        volumeTitle: null,
        wordCount: null,
        updatedAt: null,
        isLocked: false,
        attributes: const <PluginContentAttribute>[],
      ),
    ],
  );

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    contentCalls.add(chapterId);
    if (failEpisodeResource) throw StateError('https://private.example/signed-url');
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: '示例视频源',
      contentKind: PluginContentKind.video,
      chapterId: chapterId,
      title: null,
      updatedAt: null,
      text: null,
      pages: const <PluginMangaPage>[],
      media: PluginMediaResource(
        url: Uri.parse('http://127.0.0.1/source-resource/$chapterId'),
        resourceType: PluginMediaResourceType.hls,
        resourcePolicy: PluginMediaResourcePolicy.sessionOnly,
        expiresAt: null,
        mimeType: 'application/vnd.apple.mpegurl',
        headers: const <String, String>{'Referer': 'https://source.example/'},
      ),
    );
  }

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
}
