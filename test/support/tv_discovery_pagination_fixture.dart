/// Controlled discovery snapshots shared by widget and Android TV acceptance.
/// Each page remains pending until complete() publishes it; no Runtime or network
/// is started. The capture key exposes the real Flutter window without overriding
/// device metrics, and requests records collection/cursor pairs for assertions.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

class TvDiscoveryPaginationFixture {
  TvDiscoveryPaginationFixture({int count = 1, this.depth = 0, this.tv = true}) : counts = {'videos': count};
  final captureKey = GlobalKey();
  final int depth;
  final bool tv;
  final Map<String, int> counts;
  final cursors = <String, String?>{'videos': '2'};
  final requests = <(String, String)>[];
  String target = 'home';
  String? loading;
  bool replacing = false;
  late StateSetter _setState;

  void rebuild() => _setState(() {});
  void complete({int add = 1, String? next}) => _setState(() {
    counts[loading!] = counts[loading!]! + add;
    cursors[loading!] = next;
    loading = null;
  });

  Widget get widget => ProviderScope(
    child: MaterialApp(
      theme: appTvTheme(AppTheme.dark()),
      builder: (_, child) => RepaintBoundary(
        key: captureKey,
        child: TvModeScope(
          enabled: tv,
          onChanged: (_) {},
          child: TvRemoteShortcuts(child: child!),
        ),
      ),
      home: StatefulBuilder(
        builder: (context, setState) {
          _setState = setState;
          return RuntimeDiscoveryPage(
            result: PluginDiscoveryDocumentResult(
              pluginId: 'pagination',
              sourceName: '分页测试',
              document: PluginDiscoveryDocument(
                components: [
                  for (final entry in counts.entries)
                    PluginDiscoverySectionComponent(
                      id: 'section-${entry.key}',
                      title: '影视分类',
                      subtitle: null,
                      children: [
                        PluginDiscoveryContentCollectionComponent(
                          id: entry.key,
                          layout: PluginDiscoveryContentLayout.coverGrid,
                          items: List.generate(entry.value, (i) => _item('${entry.key}-$i')),
                          continuation: cursors[entry.key] == null
                              ? null
                              : PluginDiscoveryContinuation(target: target, cursor: cursors[entry.key]!),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            paginationIdentity: ('pagination', target, depth),
            onDestinationRequested: (_) {},
            onSourcePressed: () {},
            onTabSelected: (_) {},
            onCategorySelected: (_) {},
            onContentPressed: (_) {},
            onRefreshRequested: () {},
            onLoadMore: (collection) {
              requests.add((collection.id, collection.continuation!.cursor));
              _setState(() => loading = collection.id);
            },
            loadingCollectionId: loading,
            isContentLoading: replacing,
            navigationDepth: depth,
            canNavigateBack: depth > 0,
            onBackRequested: () {},
          );
        },
      ),
    ),
  );
}

PluginDiscoveryContentItem _item(String id) => PluginDiscoveryContentItem(
  content: PluginContentSummary(
    id: id,
    title: '影片 $id',
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
