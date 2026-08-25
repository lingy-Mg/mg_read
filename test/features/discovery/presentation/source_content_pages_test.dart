/// Runtime 发现页层级展示测试。
///
/// 职责：
/// - 覆盖顶级与子级页面的 chrome、返回和减动态呈现。
///
/// 注意：
/// - 此处只验证 Widget 连接；真实 Android 流程由 Integration Test 另行验收。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  testWidgets('renders every nested discovery component and routes category taps', (tester) async {
    String? selectedTarget;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: RuntimeDiscoveryPage(
          result: _documentResult(),
          onDestinationRequested: (_) {},
          onSourcePressed: () {},
          onTabSelected: (_) {},
          onCategorySelected: (target) => selectedTarget = target,
          onContentPressed: (_) {},
          onRefreshRequested: () {},
          onLoadMore: (_) {},
          canNavigateBack: false,
          onBackRequested: () {},
          loadingCollectionId: null,
        ),
      ),
    );

    expect(find.text('嵌套分类'), findsOneWidget);
    expect(find.text('第一本'), findsWidgets);
    expect(find.text('分类一'), findsOneWidget);
    expect(find.byKey(const Key('discovery-source-selector')), findsOneWidget);
    expect(find.byKey(const Key('runtime-discovery-load-more-books')), findsOneWidget);

    await tester.tap(find.text('分类一'));
    expect(selectedTarget, 'category:1');
  });

  testWidgets('adds compact vertical spacing between list categories', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: RuntimeDiscoveryPage(
          result: _documentResult(
            categoryLayout: PluginDiscoveryCategoryLayout.list,
            categories: const <PluginDiscoveryCategory>[
              PluginDiscoveryCategory(id: 'category-1', title: '排行一', target: 'ranking:1', count: null, url: null),
              PluginDiscoveryCategory(id: 'category-2', title: '排行二', target: 'ranking:2', count: null, url: null),
            ],
          ),
          onDestinationRequested: (_) {},
          onSourcePressed: () {},
          onTabSelected: (_) {},
          onCategorySelected: (_) {},
          onContentPressed: (_) {},
          onRefreshRequested: () {},
          onLoadMore: (_) {},
          canNavigateBack: false,
          onBackRequested: () {},
          loadingCollectionId: null,
        ),
      ),
    );

    final first = tester.getRect(find.byKey(const Key('runtime-discovery-category-category-1')));
    final second = tester.getRect(find.byKey(const Key('runtime-discovery-category-category-2')));
    expect(second.top - first.bottom, AppSpacing.compact);
  });

  testWidgets('renders a back control only for a retained navigation stack', (tester) async {
    var backPressed = false;
    var refreshPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: RuntimeDiscoveryPage(
          result: _documentResult(),
          onDestinationRequested: (_) {},
          onSourcePressed: () {},
          onTabSelected: (_) {},
          onCategorySelected: (_) {},
          onContentPressed: (_) {},
          onRefreshRequested: () => refreshPressed = true,
          onLoadMore: (_) {},
          isInBookshelf: (_) => true,
          canNavigateBack: true,
          navigationDepth: 1,
          onBackRequested: () => backPressed = true,
          loadingCollectionId: null,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('runtime-discovery-back')));
    expect(backPressed, isTrue);

    expect(find.byKey(const Key('runtime-discovery-nested-header')), findsOneWidget);
    expect(find.byType(DiscoveryTopBar), findsOneWidget);
    expect(find.byKey(const Key('discovery-source-selector')), findsNothing);
    expect(find.text('刷新'), findsNothing);
    expect(find.byType(DiscoveryEditorsChoiceCard), findsNothing);
    expect(find.text('已在书架'), findsNothing);
    final itemFinder = find.byKey(const ValueKey<String>('runtime-discovery-item-book:1'));
    final itemMaterial = tester.widget<Material>(find.ancestor(of: itemFinder, matching: find.byType(Material)).first);
    expect(itemMaterial.color, AppThemeTokens.of(tester.element(itemFinder)).featureSurface.withValues(alpha: 0.48));

    await tester.tap(find.byTooltip('刷新发现内容'));
    expect(refreshPressed, isTrue);
  });

  testWidgets('removes page movement when reduce motion is enabled', (tester) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: AppTheme.light(),
          home: RuntimeDiscoveryPage(
            result: _documentResult(),
            onDestinationRequested: (_) {},
            onSourcePressed: () {},
            onTabSelected: (_) {},
            onCategorySelected: (_) {},
            onContentPressed: (_) {},
            onRefreshRequested: () {},
            onLoadMore: (_) {},
            canNavigateBack: true,
            navigationDepth: 1,
            onBackRequested: () {},
            loadingCollectionId: null,
          ),
        ),
      ),
    );

    final switcher = tester
        .widgetList<AnimatedSwitcher>(find.byType(AnimatedSwitcher))
        .singleWhere((value) => value.reverseDuration == Duration.zero);
    expect(switcher.duration, Duration.zero);
    expect(switcher.reverseDuration, Duration.zero);
  });

  testWidgets('allows a locally routed child page to commit Android predictive back', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: AppTheme.light(),
        home: const Scaffold(body: Text('发现父页')),
      ),
    );

    navigatorKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => RuntimeDiscoveryPage(
          result: _documentResult(),
          onDestinationRequested: (_) {},
          onSourcePressed: () {},
          onTabSelected: (_) {},
          onCategorySelected: (_) {},
          onContentPressed: (_) {},
          onRefreshRequested: () {},
          onLoadMore: (_) {},
          canNavigateBack: true,
          navigationDepth: 1,
          onBackRequested: () => navigatorKey.currentState!.pop(),
          loadingCollectionId: null,
          allowsRoutePop: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final popScope = tester.widget<PopScope<Object?>>(find.byWidgetPredicate((widget) => widget is PopScope && widget.canPop));
    expect(popScope.canPop, isTrue);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('发现父页'), findsOneWidget);
    expect(find.byType(RuntimeDiscoveryPage), findsNothing);
  });

  testWidgets('Escape returns one retained discovery category level', (tester) async {
    var backPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: RuntimeDiscoveryPage(
          result: _documentResult(),
          onDestinationRequested: (_) {},
          onSourcePressed: () {},
          onTabSelected: (_) {},
          onCategorySelected: (_) {},
          onContentPressed: (_) {},
          onRefreshRequested: () {},
          onLoadMore: (_) {},
          canNavigateBack: true,
          onBackRequested: () => backPressed = true,
          loadingCollectionId: null,
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(backPressed, isTrue);
  });
}

PluginDiscoveryDocumentResult _documentResult({
  PluginDiscoveryCategoryLayout categoryLayout = PluginDiscoveryCategoryLayout.grid,
  List<PluginDiscoveryCategory> categories = const <PluginDiscoveryCategory>[
    PluginDiscoveryCategory(id: 'category-1', title: '分类一', target: 'category:1', count: 0, url: null),
  ],
}) => PluginDiscoveryDocumentResult(
  pluginId: 'org.example.source',
  sourceName: '示例书源',
  document: PluginDiscoveryDocument(
    components: <PluginDiscoveryComponent>[
      PluginDiscoveryTabsComponent(
        id: 'tabs',
        tabs: const <PluginDiscoveryTab>[PluginDiscoveryTab(id: 'all', label: '全部', target: 'all')],
        selectedTabId: 'all',
      ),
      PluginDiscoverySectionComponent(
        id: 'section',
        title: '嵌套分类',
        subtitle: null,
        children: <PluginDiscoveryComponent>[
          PluginDiscoveryGroupComponent(
            id: 'group',
            layout: PluginDiscoveryGroupLayout.vertical,
            children: <PluginDiscoveryComponent>[
              const PluginDiscoveryTextComponent(id: 'text', text: '书源声明的说明文字'),
              PluginDiscoveryContentCollectionComponent(
                id: 'books',
                layout: PluginDiscoveryContentLayout.list,
                items: <PluginDiscoveryContentItem>[_item('book:1', '第一本')],
                continuation: const PluginDiscoveryContinuation(target: 'category:books', cursor: 'next'),
              ),
              PluginDiscoveryCategoryCollectionComponent(id: 'categories', layout: categoryLayout, categories: categories),
            ],
          ),
        ],
      ),
    ],
  ),
);

PluginDiscoveryContentItem _item(String id, String title) => PluginDiscoveryContentItem(
  content: PluginContentSummary(
    id: id,
    title: title,
    contentKind: PluginContentKind.novel,
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
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  ),
  rank: null,
  metric: null,
  recommendation: null,
);
