import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('book detail reference surface renders in light mode', (
    WidgetTester tester,
  ) async {
    final gateway = _ReferenceDetailGateway();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: _ReferenceDetailEntry(gateway: gateway),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('source-content-detail-sheet')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('source-detail-cover')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-source-url')), findsOneWidget);
    expect(
      find.byKey(
        const Key('source-detail-latest-chapter-url'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('source-detail-catalog-url'), skipOffstage: false),
      findsOneWidget,
    );

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('discovery_detail_reference_light');
  });
}

class _ReferenceDetailEntry extends StatefulWidget {
  const _ReferenceDetailEntry({required this.gateway});

  final SourceContentGateway gateway;

  @override
  State<_ReferenceDetailEntry> createState() => _ReferenceDetailEntryState();
}

class _ReferenceDetailEntryState extends State<_ReferenceDetailEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showSourceContentDetailSheet(
          context,
          gateway: widget.gateway,
          pluginId: _ReferenceDetailGateway.pluginId,
          id: _ReferenceDetailGateway.bookId,
          onExternalUrlRequested: (_) async => true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

final class _ReferenceDetailGateway implements SourceContentGateway {
  static const String pluginId = 'org.mgread.reference';
  static const String bookId = 'mystery-lord';

  static final Uri _sourceUrl = Uri.parse(
    'https://www.qidian.com/book/1010868264',
  );
  static final Uri _coverUrl = Uri.parse('https://www.qidian.com');
  static final Uri _catalogUrl = Uri.parse(
    'https://www.qidian.com/book/1010868264#Catalog',
  );
  static final Uri _latestUrl = Uri.parse(
    'https://www.qidian.com/chapter/1010868264/811552318/',
  );

  late final PluginContentSummary _summary = PluginContentSummary(
    id: bookId,
    title: '诡秘之主',
    contentKind: PluginContentKind.novel,
    author: '爱潜水的乌贼',
    url: _sourceUrl,
    coverUrl: _coverUrl,
    description:
        '蒸汽与机械的浪潮中，谁能触及非凡？诡秘的序列，命运的齿轮，'
        '即将开始转动。戴上隐秘的面具，潜入黑暗的深渊，探寻真正的诡秘。',
    language: '中文',
    status: PluginContentStatus.completed,
    access: PluginAccessKind.unknown,
    wordCount: 4470000,
    chapterCount: 1268,
    publishedAt: null,
    updatedAt: DateTime(2026, 8, 21, 9),
    latestChapter: PluginLatestChapter(
      id: '1268',
      title: '第1268章 不可名状的低语（大结局）',
      url: _latestUrl,
      updatedAt: DateTime(2026, 8, 21, 9),
    ),
    categories: const <String>['玄幻'],
    tags: const <String>['克苏鲁', '西幻'],
    attributes: const <PluginContentAttribute>[
      PluginContentAttribute(key: 'theme', label: '主题', value: '克苏鲁'),
      PluginContentAttribute(key: 'genre', label: '题材', value: '蒸汽朋克'),
      PluginContentAttribute(key: 'ability', label: '要素', value: '异能'),
      PluginContentAttribute(key: 'tone', label: '风格', value: '悬疑'),
    ],
  );

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async => PluginContentDetail(
    pluginId: pluginId,
    sourceName: '起点中文网',
    summary: _summary,
    aliases: const <String>[],
    catalogUrl: _catalogUrl,
  );

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
    String? cursor,
    int pageSize = 50,
  }) async => PluginChaptersResult(
    pluginId: pluginId,
    sourceName: '起点中文网',
    items: <PluginChapterSummary>[
      PluginChapterSummary(
        id: '1268',
        title: '第1268章 不可名状的低语（大结局）',
        order: 1268,
        url: _latestUrl,
        volumeTitle: null,
        wordCount: null,
        updatedAt: DateTime(2026, 8, 21, 9),
        isLocked: false,
        attributes: const <PluginContentAttribute>[],
      ),
    ],
    nextCursor: null,
    totalCount: 1268,
  );

  @override
  Future<List<PluginSourceDescriptor>> listSources() async =>
      throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({
    required String pluginId,
    required String query,
    String? cursor,
    int pageSize = 20,
  }) async => throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({
    required String pluginId,
    String? cursor,
    int pageSize = 20,
  }) async => throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async => throw UnimplementedError();

  @override
  Future<PluginChapterContent> getContent({
    required String pluginId,
    required String id,
    required String chapterId,
  }) async => throw UnimplementedError();
}
