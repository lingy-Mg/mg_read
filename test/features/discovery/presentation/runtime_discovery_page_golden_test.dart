import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/presentation/runtime_discovery_page.dart';

void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(
        rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'),
      );
    final FontLoader materialIcons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  testWidgets('matches the compact light discovery list reference', (
    tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(const _GoldenHost());
    await tester.pumpAndSettle();

    expect(find.text('科幻'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsNothing);
    expect(find.text('加入书架'), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/runtime_discovery_list_compact_light.png'),
    );
  });

  testWidgets('matches the wide discovery list proportions', (tester) async {
    await _setViewport(tester, const Size(723, 1080));
    await tester.pumpWidget(const _GoldenHost());
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/runtime_discovery_list_wide_light.png'),
    );
  });

  testWidgets('renders the source row while discovery content is loading', (
    tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(const _GoldenHost(loading: true));

    expect(find.byKey(const Key('discovery-source-selector')), findsOneWidget);
    expect(find.text('爱丽丝书屋'), findsOneWidget);
    expect(find.byKey(const Key('discovery-loading-content')), findsOneWidget);
  });
}

class _GoldenHost extends StatelessWidget {
  const _GoldenHost({this.loading = false});

  final bool loading;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    themeMode: ThemeMode.light,
    builder: (context, child) {
      final mediaQuery = MediaQuery.of(context);
      return MediaQuery(
        data: mediaQuery.copyWith(
          padding: const EdgeInsets.only(top: 24),
          viewPadding: const EdgeInsets.only(top: 24),
        ),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: RuntimeDiscoveryPage(
      result: loading ? null : _result,
      sourceName: loading ? '爱丽丝书屋' : null,
      isContentLoading: loading,
      onDestinationRequested: (_) {},
      onSourcePressed: () {},
      onTabSelected: (_) {},
      onCategorySelected: (_) {},
      onContentPressed: (_) {},
      onRefreshRequested: () {},
      onLoadMore: (_) {},
      canNavigateBack: true,
      onBackRequested: () {},
      loadingCollectionId: null,
    ),
  );
}

final PluginDiscoveryDocumentResult _result = PluginDiscoveryDocumentResult(
  pluginId: 'golden.source',
  sourceName: '爱丽丝书屋',
  document: PluginDiscoveryDocument(
    components: <PluginDiscoveryComponent>[
      PluginDiscoverySectionComponent(
        id: 'golden-scifi',
        title: '科幻',
        subtitle: null,
        children: <PluginDiscoveryComponent>[
          PluginDiscoveryContentCollectionComponent(
            id: 'golden-books',
            layout: PluginDiscoveryContentLayout.list,
            items: <PluginDiscoveryContentItem>[
              _item(
                id: 'secret-master',
                title: '诡秘之主',
                author: '爱潜水的乌贼',
                category: '东方玄幻',
                tags: <String>['穿越', '克苏鲁', '蒸汽朋克'],
                description: '蒸汽与神秘的潮声中，谁能触及那扇门？\n我是小丑，我是愚者，我是诡秘之主！',
                chapters: 1268,
                update: '1天前更新',
                heat: '562.3万',
              ),
              _item(
                id: 'great-dawn',
                title: '大道朝天',
                author: '猫腻',
                category: '东方玄幻',
                tags: <String>['传统玄幻', '天才流', '长生流'],
                description: '东海北荒，大古大仙能的传承再次苏醒。\n少年自微末崛起，踏上无尽修行之路！',
                chapters: 512,
                status: PluginContentStatus.completed,
                update: '2023-12-10完结',
                heat: '512.1万',
              ),
              _item(
                id: 'deep-shore',
                title: '深空彼岸',
                author: '辰东',
                category: '东方玄幻',
                tags: <String>['宇宙星空', '升级流', '热血'],
                description: '星空一瞬，人间千年。\n宇宙浩瀚，彼岸何在？战至最后一刻！',
                chapters: 1042,
                update: '6小时前更新',
                heat: '420.8万',
              ),
              _item(
                id: 'fate-ring',
                title: '宿命之环',
                author: '爱潜水的乌贼',
                category: '东方玄幻',
                tags: <String>['克苏鲁', '命运', '冒险'],
                description: '在时间之外，他们预演着宿命与因果。\n命运的齿轮转动，谁能揭破既定的轨迹？',
                chapters: 388,
                update: '12小时前更新',
                heat: '388.6万',
              ),
              _item(
                id: 'great-hitter',
                title: '大奉打更人',
                author: '卖报小郎君',
                category: '东方玄幻',
                tags: <String>['轻松', '探案', '穿越'],
                description: '许七安，带你领略这个不一样的大奉。\n打更人，守人间，总有妖魔作祟！',
                chapters: 957,
                update: '9小时前更新',
                heat: '317.4万',
              ),
              _item(
                id: 'myth-emperor',
                title: '万古神帝',
                author: '飞天鱼',
                category: '东方玄幻',
                tags: <String>['重生', '无敌流', '杀伐果断'],
                description: '八百年前，明帝之子张若尘被未婚妻击杀。\n八百年后，重临巅峰，万族俯首！',
                chapters: 3430,
                update: '3小时前更新',
                heat: '306.9万',
              ),
              _item(
                id: 'unbreakable-god',
                title: '不朽神王',
                author: '观棋',
                category: '东方玄幻',
                tags: <String>['剑道', '强者归来', '热血'],
                description: '九死一生，重回少年。\n这一世，我定要踏碎诸天，成就不朽神王！',
                chapters: 2287,
                status: PluginContentStatus.completed,
                update: '2022-05-20完结',
                heat: '289.3万',
              ),
            ],
            continuation: null,
          ),
        ],
      ),
    ],
  ),
);

PluginDiscoveryContentItem _item({
  required String id,
  required String title,
  required String author,
  required String category,
  required List<String> tags,
  required String description,
  required int chapters,
  required String update,
  required String heat,
  PluginContentStatus status = PluginContentStatus.ongoing,
}) => PluginDiscoveryContentItem(
  content: PluginContentSummary(
    id: id,
    title: title,
    contentKind: PluginContentKind.novel,
    author: author,
    url: null,
    coverUrl: null,
    description: description,
    language: 'zh-CN',
    status: status,
    access: PluginAccessKind.free,
    wordCount: null,
    chapterCount: chapters,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: <String>[category],
    tags: tags,
    attributes: <PluginContentAttribute>[
      PluginContentAttribute(
        key: 'discoveryUpdatedLabel',
        label: '更新时间',
        value: update,
      ),
    ],
  ),
  rank: null,
  metric: PluginDiscoveryMetric(label: '热度', value: heat),
  recommendation: null,
);

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
