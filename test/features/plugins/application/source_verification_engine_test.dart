import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/plugins/application/source_verification.dart';

void main() {
  test('runs the production gateway chain and samples first middle and last content', () async {
    final gateway = _VerificationGateway(chapterCount: 5);
    final report = await SourceVerificationEngine(gateway).run(pluginId: _VerificationGateway.pluginId);

    expect(report.isSuccessful, isTrue);
    expect(gateway.contentChapterIds, <String>['chapter:0', 'chapter:2', 'chapter:4']);
    final source = report.sources.single;
    expect(source.status, SourceVerificationResultStatus.passed);
    expect(source.stages.map((stage) => stage.stage), <String>[
      'runtime',
      'discover',
      'search',
      'detail',
      'chapters',
      'content.first',
      'content.middle',
      'content.last',
      'resource.cover',
      'resource.content',
    ]);
    expect(source.stages.where((stage) => stage.stage == 'resource.cover').single.status, SourceVerificationStageStatus.skipped);
  });

  test('reports a Runtime-visible truncated catalog with a stable stage and code', () async {
    final report = await SourceVerificationEngine(_VerificationGateway(chapterCount: 6)).run(pluginId: _VerificationGateway.pluginId);

    expect(report.isSuccessful, isFalse);
    expect(report.failedCount, 1);
    expect(report.sources.single.failure?.stage, 'chapters');
    expect(report.sources.single.failure?.code, 'chapters_truncated');
    expect(report.sources.single.failure?.summary, <String, Object?>{'expected': 6, 'actual': 5});
  });

  test('accepts a WebP cover whose server reports application/octet-stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      request.response.add(const <int>[0x52, 0x49, 0x46, 0x46, 0x04, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50]);
      await request.response.close();
    });
    try {
      final coverUrl = Uri.parse('http://${server.address.address}:${server.port}/cover.webp');
      final report = await SourceVerificationEngine(
        _VerificationGateway(chapterCount: 5, coverUrl: coverUrl),
      ).run(pluginId: _VerificationGateway.pluginId);

      expect(report.isSuccessful, isTrue);
      final coverStage = report.sources.single.stages.where((stage) => stage.stage == 'resource.cover').single;
      expect(coverStage.status, SourceVerificationStageStatus.passed);
    } finally {
      await server.close(force: true);
    }
  });
}

final class _VerificationGateway implements SourceContentGateway {
  _VerificationGateway({required this.chapterCount, this.coverUrl});

  static const pluginId = 'org.mgread.fixture';
  final int chapterCount;
  final Uri? coverUrl;
  final List<String> contentChapterIds = <String>[];

  PluginContentSummary get summary => PluginContentSummary(
    id: 'novel:fixture',
    title: 'Fixture',
    contentKind: PluginContentKind.novel,
    author: null,
    url: null,
    coverUrl: coverUrl,
    description: null,
    language: 'zh',
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.free,
    wordCount: null,
    chapterCount: chapterCount,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  );

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => <PluginSourceDescriptor>[
    PluginSourceDescriptor(
      id: pluginId,
      displayName: 'Fixture Source',
      pluginVersion: '1.0.0',
      contentKinds: const <PluginContentKind>[PluginContentKind.novel],
    ),
  ];

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async => PluginDiscoveryDocumentResult(
    pluginId: pluginId,
    sourceName: 'Fixture Source',
    document: PluginDiscoveryDocument(
      components: <PluginDiscoveryComponent>[
        PluginDiscoveryContentCollectionComponent(
          id: 'fixture-collection',
          layout: PluginDiscoveryContentLayout.list,
          items: <PluginDiscoveryContentItem>[PluginDiscoveryContentItem(content: summary, rank: null, metric: null, recommendation: null)],
          continuation: null,
        ),
      ],
    ),
  );

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) async =>
      PluginSearchResult(
        pluginId: pluginId,
        sourceName: 'Fixture Source',
        items: <PluginContentSummary>[summary],
        nextCursor: null,
        totalCount: 1,
      );

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used by verification engine.');

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async =>
      PluginContentDetail(pluginId: pluginId, sourceName: 'Fixture Source', summary: summary, aliases: const <String>[], catalogUrl: null);

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async => PluginChaptersResult(
    pluginId: pluginId,
    sourceName: 'Fixture Source',
    items: List<PluginChapterSummary>.generate(
      5,
      (index) => PluginChapterSummary(
        id: 'chapter:$index',
        title: 'Chapter $index',
        order: index,
        url: null,
        volumeTitle: null,
        wordCount: null,
        updatedAt: null,
        isLocked: false,
        attributes: const <PluginContentAttribute>[],
      ),
    ),
  );

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    contentChapterIds.add(chapterId);
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: 'Fixture Source',
      contentKind: PluginContentKind.novel,
      chapterId: chapterId,
      title: null,
      updatedAt: null,
      text: 'fixture body',
      pages: const <PluginMangaPage>[],
    );
  }
}
