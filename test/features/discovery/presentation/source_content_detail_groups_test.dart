/// Grouped source-detail catalog coverage.
///
/// Verifies that source-owned groups survive the detail projection, switch the
/// visible episode grid, and reach the video-player callback unchanged.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';

void main() {
  testWidgets('detail switches source groups and forwards them to video playback', (tester) async {
    PluginChaptersResult? forwardedCatalog;
    PluginChapterSummary? forwardedEpisode;
    await tester.binding.setSurfaceSize(const Size(390, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _GroupedVideoDetailHost(
          onVideoEpisodeRequested: ({required detail, required firstCatalogPage, required chapter}) async {
            forwardedCatalog = firstCatalogPage;
            forwardedEpisode = chapter;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('选集播放'), findsOneWidget);
    expect(find.text('共 4 集 · 2 个分组'), findsOneWidget);
    expect(find.byKey(const Key('source-detail-group-laoz')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-group-diff')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-episode-laoz-laoz-1')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-episode-diff-diff-1')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('source-detail-group-tabs')));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/source_content_detail_grouped_video_phone_light.png'));

    await tester.tap(find.byKey(const Key('source-detail-group-diff')));
    await tester.pump();

    expect(find.byKey(const Key('source-detail-episode-laoz-laoz-1')), findsNothing);
    expect(find.byKey(const Key('source-detail-episode-diff-diff-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-detail-episode-diff-diff-1')));
    await tester.pumpAndSettle();

    expect(forwardedCatalog?.groups.map((group) => group.title), <String>['Laoz', 'Diff']);
    expect(forwardedEpisode?.id, 'diff-1');
  });
}

class _GroupedVideoDetailHost extends StatefulWidget {
  const _GroupedVideoDetailHost({required this.onVideoEpisodeRequested});

  final SourceVideoEpisodeRequested onVideoEpisodeRequested;

  @override
  State<_GroupedVideoDetailHost> createState() => _GroupedVideoDetailHostState();
}

class _GroupedVideoDetailHostState extends State<_GroupedVideoDetailHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSourceContentDetailSheet(
        context,
        gateway: const _GroupedVideoGateway(),
        pluginId: _pluginId,
        id: _contentId,
        onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

final class _GroupedVideoGateway implements SourceContentGateway {
  const _GroupedVideoGateway();

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => _detail;

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => _catalog;

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

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnimplementedError();
}

const _pluginId = 'org.example.grouped-video';
const _contentId = 'video-1';

final _laozEpisodes = <PluginChapterSummary>[
  _episode(id: 'laoz-1', title: '第01集', order: 0, group: 'Laoz'),
  _episode(id: 'laoz-2', title: '第02集', order: 1, group: 'Laoz'),
];
final _diffEpisodes = <PluginChapterSummary>[
  _episode(id: 'diff-1', title: '第01集', order: 0, group: 'Diff'),
  _episode(id: 'diff-2', title: '第02集', order: 1, group: 'Diff'),
];

final _catalog = PluginChaptersResult(
  pluginId: _pluginId,
  sourceName: '分组视频源',
  items: <PluginChapterSummary>[..._laozEpisodes, ..._diffEpisodes],
  groups: <PluginMediaGroup>[
    PluginMediaGroup(id: 'laoz', title: 'Laoz', order: 0, episodes: _laozEpisodes),
    PluginMediaGroup(id: 'diff', title: 'Diff', order: 1, episodes: _diffEpisodes),
  ],
);

final _detail = PluginContentDetail(
  pluginId: _pluginId,
  sourceName: '分组视频源',
  summary: PluginContentSummary(
    id: _contentId,
    title: '分组动画',
    contentKind: PluginContentKind.video,
    coverOrientation: PluginCoverOrientation.portrait,
    author: null,
    url: null,
    coverUrl: null,
    description: '用于验证详情与播放器之间的分组传递。',
    language: 'zh-CN',
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.free,
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

PluginChapterSummary _episode({required String id, required String title, required int order, required String group}) =>
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
