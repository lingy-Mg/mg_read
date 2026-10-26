/// Inline discovery input regression: source scoping, errors and stale requests.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';

void main() {
  testWidgets('renders source input in the document and opens resolved content', (tester) async {
    final gateway = _Gateway();
    PluginContentSummary? opened;
    await tester.pumpWidget(_page(gateway, onOpen: (value) => opened = value));
    expect(find.byKey(const Key('bilibili-url-play-action')), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    expect(gateway.calls, 0);
    await tester.enterText(find.byType(TextField), 'BV1tGe36YEap');
    await tester.pump();
    await tester.tap(find.text('读取音频'));
    await tester.pumpAndSettle();
    expect(gateway.pluginId, 'bilibili.source');
    expect(gateway.query, 'BV1tGe36YEap');
    expect(find.text('测试音频'), findsOneWidget);
    await tester.tap(find.text('测试音频'));
    expect(opened?.id, 'bvid:BV1tGe36YEap');
  });

  testWidgets('shows the actual access failure and supports retry', (tester) async {
    final gateway = _Gateway()..error = AppError.fromCode(AppErrorCode.sourceAccessBlocked, detail: 'HTTP 412');
    await tester.pumpWidget(_page(gateway));
    await tester.enterText(find.byType(TextField), 'BV1tGe36YEap');
    await tester.pump();
    await tester.tap(find.text('读取音频'));
    await tester.pumpAndSettle();
    expect(find.textContaining('网站拒绝了当前访问'), findsOneWidget);
    expect(find.textContaining('HTTP 412'), findsOneWidget);
    expect(find.textContaining('确认已安装'), findsNothing);
    gateway.error = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('测试音频'), findsOneWidget);
    expect(gateway.calls, 2);
  });

  testWidgets('editing input discards a pending result', (tester) async {
    final pending = Completer<PluginSearchResult>();
    final gateway = _Gateway()..pending = pending.future;
    await tester.pumpWidget(_page(gateway));
    await tester.enterText(find.byType(TextField), 'BV1tGe36YEap');
    await tester.pump();
    await tester.tap(find.text('读取音频'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'another video');
    pending.complete(_result());
    await tester.pumpAndSettle();
    expect(find.text('测试音频'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _page(_Gateway gateway, {ValueChanged<PluginContentSummary>? onOpen}) => ProviderScope(
  overrides: [sourceContentGatewayProvider.overrideWithValue(gateway)],
  child: MaterialApp(
    theme: AppTheme.light(),
    home: RuntimeDiscoveryPage(
      result: PluginDiscoveryDocumentResult(
        pluginId: 'bilibili.source',
        sourceName: '哔哩哔哩',
        document: PluginDiscoveryDocument(
          components: [
            PluginDiscoverySectionComponent(
              id: 'links',
              title: '链接听书',
              subtitle: null,
              children: [
                PluginDiscoveryGroupComponent(
                  id: 'group',
                  layout: PluginDiscoveryGroupLayout.vertical,
                  children: [
                    const PluginDiscoverySearchInputComponent(id: 'link', label: '视频链接或 BV 号', placeholder: 'BV…', submitLabel: '读取音频'),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      onDestinationRequested: (_) {},
      onSourcePressed: () {},
      onTabSelected: (_) {},
      onCategorySelected: (_) {},
      onContentPressed: onOpen ?? (_) {},
      onRefreshRequested: () {},
      onLoadMore: (_) {},
      canNavigateBack: false,
      onBackRequested: () {},
      loadingCollectionId: null,
    ),
  ),
);

class _Gateway implements SourceContentGateway {
  int calls = 0;
  String? pluginId;
  String? query;
  Object? error;
  Future<PluginSearchResult>? pending;

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) async {
    calls++;
    this.pluginId = pluginId;
    this.query = query;
    if (error case final value?) throw value;
    return pending ?? Future.value(_result());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PluginSearchResult _result() => PluginSearchResult(
  pluginId: 'bilibili.source',
  sourceName: '哔哩哔哩',
  items: [
    PluginContentSummary(
      id: 'bvid:BV1tGe36YEap',
      title: '测试音频',
      contentKind: PluginContentKind.audio,
      coverOrientation: PluginCoverOrientation.landscape,
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
      categories: [],
      tags: [],
      attributes: [],
    ),
  ],
  nextCursor: null,
  totalCount: 1,
);
