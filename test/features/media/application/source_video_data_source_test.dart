/// Safe diagnostic tests for the source-to-video-player adapter.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_video_player/mg_read_video_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/errors/app_error.dart';
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

  test('preserves source groups for the player and resolves inside the selected group', () async {
    final gateway = _VideoGateway(failEpisodeResource: false, grouped: true);
    final source = SourceVideoDataSource(gateway: gateway, pluginId: _pluginId);

    final content = await source.load('video-1');

    expect(content.groups.map((group) => group.title), <String>['Laoz', 'Diff']);
    expect(content.groups.map((group) => group.episodes.single.id), <String>['episode-1', 'episode-2']);
    final episode = await source.loadEpisode('video-1', groupId: 'diff', episodeId: 'episode-2');
    expect(episode.id, 'episode-2');
    expect(gateway.contentCalls, <String>['episode-2']);
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

  test('surfaces an external media resolver failure without raw details', () async {
    final gateway = _VideoGateway(failEpisodeResource: false, episodeFailureCode: AppErrorCode.sourceMediaResolutionFailed);
    final source = SourceVideoDataSource(gateway: gateway, pluginId: _pluginId);
    await source.load('video-1');

    await expectLater(
      source.loadEpisode('video-1', groupId: 'default', episodeId: 'episode-1'),
      throwsA(
        isA<VideoPlayerLoadException>()
            .having((failure) => failure.code, 'code', 'video_external_resolver_failed')
            .having((failure) => failure.location, 'location', '解析外部播放地址')
            .having((failure) => failure.message, 'message', '外部播放地址解析失败，请稍后重试或更换线路。'),
      ),
    );
  });
}

const _pluginId = 'org.example.video';

final class _VideoGateway implements SourceContentGateway {
  _VideoGateway({required this.failEpisodeResource, this.episodeFailureCode, this.grouped = false});

  final bool failEpisodeResource;
  final AppErrorCode? episodeFailureCode;
  final bool grouped;
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
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async {
    final first = _episode(id: 'episode-1', title: '第 1 集', order: 0, group: grouped ? 'Laoz' : null);
    final second = _episode(id: 'episode-2', title: '第 2 集', order: 0, group: 'Diff');
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: '示例视频源',
      items: <PluginChapterSummary>[first, if (grouped) second],
      groups: grouped
          ? <PluginMediaGroup>[
              PluginMediaGroup(id: 'laoz', title: 'Laoz', order: 0, episodes: <PluginChapterSummary>[first]),
              PluginMediaGroup(id: 'diff', title: 'Diff', order: 1, episodes: <PluginChapterSummary>[second]),
            ]
          : const <PluginMediaGroup>[],
    );
  }

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    contentCalls.add(chapterId);
    final failureCode = episodeFailureCode;
    if (failureCode != null) throw AppError.fromCode(failureCode);
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

PluginChapterSummary _episode({required String id, required String title, required int order, required String? group}) =>
    PluginChapterSummary(
      id: id,
      title: title,
      order: order,
      url: null,
      volumeTitle: group,
      wordCount: null,
      updatedAt: null,
      isLocked: false,
      attributes: const <PluginContentAttribute>[],
    );
