import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/tv_companion/application/companion_controller.dart';

import 'companion_controller_testkit.dart';

void main() {
  late CompanionPairFixture fixture;

  tearDown(() async => fixture.close());

  test('catalog search paginates a merged cross-source result without repeats or losing source identity', () async {
    final gateway = _PagedSearchGateway();
    fixture = await CompanionPairFixture.create(sourceGateway: gateway);
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);

    final first = await fixture.phone.request('search', arguments: const {'query': 'featured'});
    final firstRows = (first['items'] as List).cast<Map>();
    expect(firstRows, hasLength(20));
    expect(first['hasMore'], isTrue);
    expect(first['cursor'], isA<String>());
    expect(firstRows.map((row) => row['pluginId']).toSet(), {'source-a', 'source-b'});

    final second = await fixture.phone.request('search', arguments: {'query': 'featured', 'cursor': first['cursor']});
    final secondRows = (second['items'] as List).cast<Map>();
    expect(secondRows, hasLength(10));
    expect(second['hasMore'], isFalse);
    final firstIds = firstRows.map((row) => '${row['pluginId']}:${row['contentId']}').toSet();
    final secondIds = secondRows.map((row) => '${row['pluginId']}:${row['contentId']}').toSet();
    expect(firstIds.intersection(secondIds), isEmpty);
    expect(gateway.calls, hasLength(2));
  });

  test('a cancelled late source response cannot replace the next query session', () async {
    final gateway = _LateSearchGateway();
    fixture = await CompanionPairFixture.create(sourceGateway: gateway);
    await fixture.connect();
    await fixture.waitFor(() => fixture.phone.remoteState != null);

    final oldRequest = fixture.phone.request('search', arguments: const {'query': 'old'});
    final oldFailure = expectLater(oldRequest, throwsA(anything));
    await gateway.oldQueryStarted.future.timeout(const Duration(seconds: 3));
    fixture.phone.cancelSearch();
    final nextQuery = await fixture.phone.request('search', arguments: const {'query': 'new'});
    expect((nextQuery['items'] as List).single['title'], 'new result');

    gateway.releaseOld.complete();
    await oldFailure;
    final repeated = await fixture.phone.request('search', arguments: const {'query': 'new'});
    expect((repeated['items'] as List).single['title'], 'new result');
    expect(gateway.newQueryCalls, 2);
  });
}

final class _PagedSearchGateway implements SourceContentGateway {
  final calls = <String>[];

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => [_source('source-a', 'Source A'), _source('source-b', 'Source B')];

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) async {
    calls.add('$pluginId:$query:$cursor');
    return PluginSearchResult(
      pluginId: pluginId,
      sourceName: pluginId,
      items: [for (var index = 0; index < 15; index++) _summary(pluginId, index)],
      nextCursor: null,
      totalCount: 15,
    );
  }

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();
  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) => throw UnimplementedError();
  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) => throw UnimplementedError();
  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnimplementedError();
}

final class _LateSearchGateway implements SourceContentGateway {
  final oldQueryStarted = Completer<void>();
  final releaseOld = Completer<void>();
  int newQueryCalls = 0;

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => [_source('source-a', 'Source A')];

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) async {
    if (query == 'old') {
      oldQueryStarted.complete();
      await releaseOld.future;
      return PluginSearchResult(
        pluginId: pluginId,
        sourceName: 'Source A',
        items: [_summary(pluginId, 0, title: 'late old result')],
        nextCursor: null,
        totalCount: 1,
      );
    }
    newQueryCalls++;
    return PluginSearchResult(
      pluginId: pluginId,
      sourceName: 'Source A',
      items: [_summary(pluginId, 1, title: 'new result')],
      nextCursor: null,
      totalCount: 1,
    );
  }

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();
  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) => throw UnimplementedError();
  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) => throw UnimplementedError();
  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnimplementedError();
}

PluginSourceDescriptor _source(String id, String label) =>
    PluginSourceDescriptor(id: id, displayName: label, pluginVersion: '1', contentKinds: const [PluginContentKind.video]);

PluginContentSummary _summary(String pluginId, int index, {String? title}) => PluginContentSummary(
  id: '$pluginId-item-$index',
  title: title ?? '$pluginId title $index',
  contentKind: PluginContentKind.video,
  author: null,
  url: null,
  coverUrl: null,
  description: null,
  language: null,
  status: PluginContentStatus.unknown,
  access: PluginAccessKind.unknown,
  wordCount: null,
  chapterCount: null,
  publishedAt: null,
  updatedAt: null,
  latestChapter: null,
  categories: const [],
  tags: const [],
  attributes: const [],
);
