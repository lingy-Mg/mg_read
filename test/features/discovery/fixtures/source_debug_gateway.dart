/// Offline source fixtures for sequential debug and native-preview tests.
library;

import 'dart:async';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';

class DebugTestGateway implements SourceContentGateway, CancellableSourceContentGateway, SourceChapterGroupGateway {
  final calls = <String>[];
  final cancellations = <PluginInvocationCancellation>[];
  final sources = [
    for (final id in ['a', 'b', 'c']) PluginSourceDescriptor(id: id, displayName: '数据源 $id', contentKinds: [PluginContentKind.novel]),
  ];
  Future<PluginDiscoverResult> Function(String id, String? target)? discoverOverride;
  Future<PluginContentDetail> Function(String id)? detailOverride;
  PluginChaptersResult Function(String id)? catalogOverride;
  PluginChapterContent Function(String id, String chapterId)? contentOverride;

  @override
  Future<T> runCancellable<T>(PluginInvocationCancellation cancellation, Future<T> Function() request) {
    cancellations.add(cancellation);
    return request();
  }

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => sources;
  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async {
    calls.add('$pluginId:discover:${target ?? 'home'}');
    return discoverOverride == null ? document(pluginId) : discoverOverride!(pluginId, target);
  }

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async {
    calls.add('$pluginId:detail:$id');
    return detailOverride == null ? detail(pluginId) : detailOverride!(pluginId);
  }

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async {
    calls.add('$pluginId:catalog:$id');
    return catalogOverride?.call(pluginId) ?? catalog(pluginId);
  }

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    calls.add('$pluginId:content:$chapterId');
    return contentOverride?.call(pluginId, chapterId) ?? chapterContent(pluginId, chapterId);
  }

  @override
  Future<PluginChaptersResult> getChapterGroup({required String pluginId, required String id, required String groupId}) async {
    calls.add('$pluginId:group:$groupId');
    return catalog(pluginId);
  }

  @override
  void invalidateChapterGroups(String pluginId, String id) {}
  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();
  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  static PluginContentSummary summary(String id, {PluginContentKind kind = PluginContentKind.novel}) => PluginContentSummary(
    id: 'book-$id',
    title: '首个资源 $id',
    contentKind: kind,
    author: '测试作者',
    url: null,
    coverUrl: null,
    description: '测试简介',
    language: null,
    status: PluginContentStatus.unknown,
    access: PluginAccessKind.unknown,
    wordCount: null,
    chapterCount: 1,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: [],
    tags: [],
    attributes: [],
  );
  static PluginContentDetail detail(String id, {PluginContentKind kind = PluginContentKind.novel}) => PluginContentDetail(
    pluginId: id,
    sourceName: '数据源 $id',
    summary: summary(id, kind: kind),
    aliases: [],
    catalogUrl: null,
  );
  static PluginDiscoveryDocumentResult document(String id, {List<PluginDiscoveryComponent>? components}) => PluginDiscoveryDocumentResult(
    pluginId: id,
    sourceName: '数据源 $id',
    document: PluginDiscoveryDocument(
      components:
          components ??
          [
            PluginDiscoverySectionComponent(
              id: 'section',
              title: '资源',
              subtitle: null,
              children: [
                PluginDiscoveryContentCollectionComponent(
                  id: 'books',
                  layout: PluginDiscoveryContentLayout.list,
                  items: [
                    for (final book in [summary(id), summary('second')])
                      PluginDiscoveryContentItem(content: book, rank: null, metric: null, recommendation: null),
                  ],
                  continuation: null,
                ),
              ],
            ),
          ],
    ),
  );
  static PluginChapterSummary chapter({bool locked = false}) => PluginChapterSummary(
    id: 'chapter-1',
    title: '第一章',
    order: 0,
    url: null,
    volumeTitle: null,
    wordCount: null,
    updatedAt: null,
    isLocked: locked,
    attributes: [],
  );
  static PluginChaptersResult catalog(String id) => PluginChaptersResult(pluginId: id, sourceName: '数据源 $id', items: [chapter()]);
  static PluginChapterContent chapterContent(String id, String chapterId, {String text = '首章正文'}) => PluginChapterContent(
    pluginId: id,
    sourceName: '数据源 $id',
    contentKind: PluginContentKind.novel,
    chapterId: chapterId,
    title: '第一章',
    updatedAt: null,
    text: text,
    pages: [],
  );
}
