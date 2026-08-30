import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read_audio_player/mg_read_audio_player.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/media/application/source_audio_playlist_data_source.dart';

void main() {
  test('opens the selected free track and isolates locked adjacent tracks', () async {
    final gateway = _AudioGateway();
    final source = SourceAudioPlaylistDataSource(
      gateway: gateway,
      pluginId: _pluginId,
      initialTrackId: 'chapter:free-2',
      initialDetail: _detail(),
      initialCatalog: _catalog(),
      maximumTracks: 3,
    );

    final playlist = await source.loadPlaylist('audio:book-1');

    expect(playlist.tracks.map((track) => track.id), <String>[
      'chapter:free-2',
      'chapter:free-3',
    ]);
    expect(gateway.contentCalls, <String>['chapter:free-2', 'chapter:free-3']);
  });

  test('does not fail the selected track when the next resource is unavailable', () async {
    final gateway = _AudioGateway(failingChapterId: 'chapter:free-3');
    final source = SourceAudioPlaylistDataSource(
      gateway: gateway,
      pluginId: _pluginId,
      initialTrackId: 'chapter:free-2',
      initialDetail: _detail(),
      initialCatalog: _catalog(),
      maximumTracks: 3,
    );

    final playlist = await source.loadPlaylist('audio:book-1');

    expect(playlist.tracks.single.id, 'chapter:free-2');
    expect(gateway.contentCalls, <String>['chapter:free-2', 'chapter:free-3']);
  });

  test('reports a safe location when the selected resource is unavailable', () async {
    final source = SourceAudioPlaylistDataSource(
      gateway: _AudioGateway(failingChapterId: 'chapter:free-2'),
      pluginId: _pluginId,
      initialTrackId: 'chapter:free-2',
      initialDetail: _detail(),
      initialCatalog: _catalog(),
    );

    await expectLater(
      source.loadPlaylist('audio:book-1'),
      throwsA(
        isA<AudioPlayerLoadException>()
            .having((error) => error.code, 'code', 'audio_selected_resource_unavailable')
            .having((error) => error.location, 'location', '所选章节的播放地址'),
      ),
    );
  });

  test('loads the next available chapters in bounded batches', () async {
    final gateway = _AudioGateway();
    final source = SourceAudioPlaylistDataSource(
      gateway: gateway,
      pluginId: _pluginId,
      initialDetail: _detail(),
      initialCatalog: _catalog(),
    );

    final tracks = await source.loadFollowingTracks(
      'audio:book-1',
      afterTrackId: 'chapter:free-2',
      limit: 2,
    );

    expect(tracks.map((track) => track.id), <String>['chapter:free-3']);
    expect(gateway.contentCalls, <String>['chapter:free-3']);
  });
}

const _pluginId = 'org.example.audio';

PluginContentDetail _detail() => PluginContentDetail(
  pluginId: _pluginId,
  sourceName: '示例音频源',
  summary: PluginContentSummary(
    id: 'audio:book-1',
    title: '测试音频',
    contentKind: PluginContentKind.audio,
    author: '测试主播',
    url: null,
    coverUrl: null,
    description: null,
    language: 'zh-CN',
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.mixed,
    wordCount: null,
    chapterCount: 4,
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

PluginChaptersResult _catalog() => PluginChaptersResult(
  pluginId: _pluginId,
  sourceName: '示例音频源',
  items: <PluginChapterSummary>[
    _chapter('chapter:free-1', 0),
    _chapter('chapter:locked', 1, isLocked: true),
    _chapter('chapter:free-2', 2),
    _chapter('chapter:free-3', 3),
  ],
);

PluginChapterSummary _chapter(String id, int order, {bool isLocked = false}) =>
    PluginChapterSummary(
      id: id,
      title: '第${order + 1}集',
      order: order,
      url: null,
      volumeTitle: null,
      wordCount: null,
      updatedAt: null,
      isLocked: isLocked,
      attributes: const <PluginContentAttribute>[],
    );

final class _AudioGateway implements SourceContentGateway {
  _AudioGateway({this.failingChapterId});

  final String? failingChapterId;
  final List<String> contentCalls = <String>[];

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) async {
    contentCalls.add(chapterId);
    if (chapterId == failingChapterId) throw StateError('fixture unavailable');
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: '示例音频源',
      contentKind: PluginContentKind.audio,
      chapterId: chapterId,
      title: null,
      updatedAt: null,
      text: null,
      pages: const <PluginMangaPage>[],
      media: PluginMediaResource(
        url: Uri.parse('http://127.0.0.1/source-resource/$chapterId'),
        resourceType: PluginMediaResourceType.audio,
        resourcePolicy: PluginMediaResourcePolicy.sessionOnly,
        expiresAt: null,
        mimeType: 'audio/mpeg',
        headers: const <String, String>{},
      ),
    );
  }

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => _detail();

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => _catalog();

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({required String pluginId, String? target, String? cursor, String? collectionId, int pageSize = 20}) => throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) => throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) => throw UnimplementedError();
}
