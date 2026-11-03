/// Controlled video-source fixtures shared by TV cache and UI acceptance tests.
/// Category gates allow out-of-order completion without network or Runtime IO.
library;

import 'dart:async';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/application/discovery_source_selection_store.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

class TvDiscoveryTestGateway implements SourceContentGateway, CancellableSourceContentGateway {
  final requests = <String>[];
  final gates = <String, Completer<void>>{};
  final cancellations = <PluginInvocationCancellation>[];
  bool autoComplete = false;
  Completer<void>? homeGate;
  int active = 0;
  int maxActive = 0;

  @override
  Future<T> runCancellable<T>(PluginInvocationCancellation cancellation, Future<T> Function() request) {
    cancellations.add(cancellation);
    return request();
  }

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => [
    for (final id in ['sakura', 'other'])
      PluginSourceDescriptor(id: id, displayName: id == 'sakura' ? '樱花动漫' : '备用动漫', contentKinds: const [PluginContentKind.video]),
  ];

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async {
    final key = '$pluginId/${target ?? 'home'}';
    requests.add(key);
    if (target == null) await homeGate?.future;
    if (target != null) {
      active++;
      if (active > maxActive) maxActive = active;
      try {
        if (!autoComplete) await gates.putIfAbsent(key, Completer<void>.new).future;
      } finally {
        active--;
      }
    }
    return tvDiscoveryDocument(pluginId: pluginId, target: target);
  }

  void complete(String target, {String source = 'sakura'}) => gates['$source/$target']!.complete();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('Not used by TV discovery tests.');
}

class TvDiscoveryTestSelection implements DiscoverySourceSelectionStore {
  String? selected;
  @override
  Future<String?> load() async => selected;
  @override
  Future<void> save(String sourceId) async => selected = sourceId;
  @override
  Future<List<String>> loadPinned() async => [];
  @override
  Future<void> setPinned(String sourceId, {required bool pinned}) async {}
}

PluginDiscoveryDocumentResult tvDiscoveryDocument({String pluginId = 'sakura', String? target}) => PluginDiscoveryDocumentResult(
  pluginId: pluginId,
  sourceName: pluginId == 'sakura' ? '樱花动漫' : '备用动漫',
  document: PluginDiscoveryDocument(
    components: [
      PluginDiscoverySectionComponent(
        id: 'content-${target ?? 'home'}',
        title: target == null ? '首页全部推荐' : '分类 $target',
        subtitle: null,
        children: [
          PluginDiscoveryContentCollectionComponent(
            id: target ?? 'featured',
            layout: PluginDiscoveryContentLayout.coverGrid,
            items: List.generate(target == null ? 15 : 3, (i) => _item('${target ?? 'home'}-$i')),
            continuation: null,
          ),
        ],
      ),
      if (target == null) ...[
        PluginDiscoverySectionComponent(
          id: 'navigation',
          title: '动漫分类',
          subtitle: null,
          children: [
            PluginDiscoveryCategoryCollectionComponent(
              id: 'categories',
              layout: PluginDiscoveryCategoryLayout.chips,
              categories: [
                for (final entry in {'today': '今日更新', 'hot': '热榜', 'week': '本周追番', 'new': '新片上线'}.entries)
                  PluginDiscoveryCategory(id: entry.key, title: entry.value, target: entry.key, count: null, url: null),
              ],
            ),
          ],
        ),
        PluginDiscoveryTabsComponent(
          id: 'duplicate-tab',
          selectedTabId: 'today',
          tabs: const [PluginDiscoveryTab(id: 'today', label: '今日更新', target: 'today')],
        ),
      ],
    ],
  ),
);

PluginDiscoveryContentItem _item(String id) => PluginDiscoveryContentItem(
  content: PluginContentSummary(
    id: id,
    title: '动漫 $id',
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
  ),
  rank: null,
  metric: null,
  recommendation: null,
);
