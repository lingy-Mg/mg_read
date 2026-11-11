/// 发现空文档、空分区和加载切换的回归验证；不启动 Runtime 或网络请求。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';

void main() {
  testWidgets('non-null empty discovery documents show a refreshable empty state', (tester) async {
    var refreshed = false;
    await tester.pumpWidget(_host(onRefresh: () => refreshed = true));
    expect(find.byKey(const Key('discovery-empty')), findsOneWidget);
    expect(find.text('当前来源没有发现内容。'), findsOneWidget);
    await tester.tap(find.text('刷新'));
    expect(refreshed, isTrue);
  });

  testWidgets('loading empty results keep loading feedback until the request completes', (tester) async {
    await tester.pumpWidget(_host(loading: true));
    expect(find.byKey(const Key('discovery-loading-content')), findsOneWidget);
    expect(find.byKey(const Key('discovery-empty')), findsNothing);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('discovery-empty')), findsOneWidget);
    expect(find.byKey(const Key('discovery-loading-content')), findsNothing);
  });

  testWidgets('empty collections retain filters and pagination rather than a blank body', (tester) async {
    await tester.pumpWidget(
      _host(
        components: [
          PluginDiscoveryTabsComponent(
            id: 'filters',
            selectedTabId: 'all',
            tabs: const [PluginDiscoveryTab(id: 'all', label: '全部', target: 'all')],
          ),
          PluginDiscoveryContentCollectionComponent(
            id: 'books',
            layout: PluginDiscoveryContentLayout.compact,
            items: const [],
            continuation: const PluginDiscoveryContinuation(target: 'books', cursor: 'next'),
          ),
        ],
      ),
    );
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('当前页暂无内容，可以继续加载'), findsOneWidget);
    expect(find.byKey(const Key('runtime-discovery-load-more-books')), findsOneWidget);
  });

  testWidgets('empty documents with errors show failure rather than a false empty success', (tester) async {
    await tester.pumpWidget(_host(failure: '数据源暂时不可用'));
    expect(find.byKey(const Key('discovery-failure')), findsOneWidget);
    expect(find.text('数据源暂时不可用'), findsOneWidget);
    expect(find.byKey(const Key('discovery-empty')), findsNothing);
  });

  testWidgets('no-animation loading remains visible without a spinning indicator', (tester) async {
    await tester.pumpWidget(_host(loading: true, disabled: true));
    expect(find.byKey(const Key('discovery-loading-content')), findsOneWidget);
    expect(find.byIcon(Icons.hourglass_empty_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

Widget _host({
  bool loading = false,
  bool disabled = false,
  String? failure,
  VoidCallback? onRefresh,
  List<PluginDiscoveryComponent> components = const [],
}) => MaterialApp(
  theme: AppTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: disabled),
    child: child!,
  ),
  home: RuntimeDiscoveryPage(
    result: PluginDiscoveryDocumentResult(
      pluginId: 'empty-test',
      sourceName: '空态测试源',
      document: PluginDiscoveryDocument(components: components),
    ),
    isContentLoading: loading,
    contentFailureMessage: failure,
    onDestinationRequested: (_) {},
    onSourcePressed: () {},
    onTabSelected: (_) {},
    onCategorySelected: (_) {},
    onContentPressed: (_) {},
    onRefreshRequested: onRefresh ?? () {},
    onLoadMore: (_) {},
    canNavigateBack: false,
    onBackRequested: () {},
    loadingCollectionId: null,
  ),
);
