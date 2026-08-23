import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  testWidgets(
    'renders every nested discovery component and routes category taps',
    (tester) async {
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
      expect(
        find.byKey(const Key('runtime-discovery-load-more-books')),
        findsOneWidget,
      );

      await tester.tap(find.text('分类一'));
      expect(selectedTarget, 'category:1');
    },
  );

  testWidgets('renders a back control only for a retained navigation stack', (
    tester,
  ) async {
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
          canNavigateBack: true,
          onBackRequested: () => backPressed = true,
          loadingCollectionId: null,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('runtime-discovery-back')));
    expect(backPressed, isTrue);

    expect(
      find.descendant(
        of: find.byType(DiscoveryTopBar),
        matching: find.text('嵌套分类'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(DiscoveryTopBar),
        matching: find.text('发现'),
      ),
      findsNothing,
    );
    expect(find.byKey(const Key('discovery-refresh-action')), findsOneWidget);
    expect(find.text('刷新'), findsNothing);
    expect(find.byType(DiscoveryEditorsChoiceCard), findsNothing);

    await tester.tap(find.byKey(const Key('discovery-refresh-action')));
    expect(refreshPressed, isTrue);
  });
}

PluginDiscoveryDocumentResult _documentResult() =>
    PluginDiscoveryDocumentResult(
      pluginId: 'org.example.source',
      sourceName: '示例书源',
      document: PluginDiscoveryDocument(
        components: <PluginDiscoveryComponent>[
          PluginDiscoveryTabsComponent(
            id: 'tabs',
            tabs: const <PluginDiscoveryTab>[
              PluginDiscoveryTab(id: 'all', label: '全部', target: 'all'),
            ],
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
                  const PluginDiscoveryTextComponent(
                    id: 'text',
                    text: '书源声明的说明文字',
                  ),
                  PluginDiscoveryContentCollectionComponent(
                    id: 'books',
                    layout: PluginDiscoveryContentLayout.list,
                    items: <PluginDiscoveryContentItem>[_item('book:1', '第一本')],
                    continuation: const PluginDiscoveryContinuation(
                      target: 'category:books',
                      cursor: 'next',
                    ),
                  ),
                  PluginDiscoveryCategoryCollectionComponent(
                    id: 'categories',
                    layout: PluginDiscoveryCategoryLayout.grid,
                    categories: const <PluginDiscoveryCategory>[
                      PluginDiscoveryCategory(
                        id: 'category-1',
                        title: '分类一',
                        target: 'category:1',
                        count: 0,
                        url: null,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );

PluginDiscoveryContentItem _item(String id, String title) =>
    PluginDiscoveryContentItem(
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
