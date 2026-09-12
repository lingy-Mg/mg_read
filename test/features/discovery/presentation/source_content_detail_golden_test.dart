import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';

import 'fixtures/alice_book_house_detail_fixture.dart';

void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final FontLoader materialIcons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  testWidgets('matches the compact light book detail reference baseline', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(const _DetailGoldenHost(useReference: true));
    await tester.pumpAndSettle();

    expect(tester.state<ScrollableState>(_detailVerticalScrollableFinder()).position.pixels, 0);
    expect(tester.getTopLeft(find.byKey(const Key('source-detail-cover'))).dy, 84);
    expect(find.byKey(const Key('source-detail-header-title')), findsOneWidget);
    expect(find.text('爱潜水的乌贼'), findsWidgets);
    expect(find.text('447万'), findsOneWidget);
    expect(find.text('1268'), findsOneWidget);
    expect(find.text('已完结'), findsOneWidget);
    expect(find.text('9.7'), findsOneWidget);
    expect(find.text('42.3万人评分'), findsOneWidget);
    expect(find.text('克苏鲁'), findsWidgets);
    expect(find.text('西幻'), findsOneWidget);
    expect(find.byKey(const Key('source-detail-recommendations-scroll')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-recommendations-refresh')), findsOneWidget);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/source_content_detail_compact_light.png'));
  });

  testWidgets('formats numeric source stats without duplicating the word label', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(const _DetailGoldenHost());
    await tester.pumpAndSettle();

    expect(find.text('1.22万'), findsOneWidget);
    expect(find.text('185.96万'), findsOneWidget);
    expect(find.text('字数：1859600'), findsNothing);
  });

  testWidgets('uses the complete catalog length as the chapter count', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_DetailGoldenHost(gateway: _GoldenDetailGateway()));
    await tester.pumpAndSettle();

    expect(find.text('共 4 章', skipOffstage: false), findsOneWidget);
  });

  testWidgets('allows a mouse drag to scroll detail recommendations on desktop', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(const _DetailGoldenHost(useReference: true));
    await tester.pumpAndSettle();

    final recommendations = find.byKey(const Key('source-detail-recommendations-scroll'));
    await tester.scrollUntilVisible(recommendations, 280, scrollable: _detailVerticalScrollableFinder());
    await tester.ensureVisible(recommendations);
    await tester.pumpAndSettle();
    final horizontalScrollable = find.descendant(of: recommendations, matching: find.byType(Scrollable));
    final state = tester.state<ScrollableState>(horizontalScrollable);
    expect(state.position.maxScrollExtent, greaterThan(0));
    expect(state.position.pixels, 0);

    await tester.drag(horizontalScrollable, const Offset(-160, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(state.position.pixels, greaterThan(0));
  });

  testWidgets('delegates a recommendation tap with the selected content', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    PluginContentSummary? requestedContent;
    await tester.pumpWidget(
      _DetailGoldenHost(useReference: true, onRecommendationRequested: (content) async => requestedContent = content),
    );
    await tester.pumpAndSettle();

    final recommendation = find.byKey(const ValueKey<String>('source-detail-recommendation-great-dawn'));
    await tester.scrollUntilVisible(recommendation, 280, scrollable: _detailVerticalScrollableFinder());
    await tester.ensureVisible(recommendation);
    await tester.pumpAndSettle();
    await tester.tap(recommendation);
    await tester.pump();

    expect(requestedContent?.id, 'great-dawn');
    expect(requestedContent?.title, '大道朝天');
  });

  testWidgets('reveals more chapters locally without another source request', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    final gateway = _GoldenDetailGateway(catalogItemCount: 22);
    await tester.pumpWidget(_DetailGoldenHost(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('source-detail-load-more-chapters')),
      280,
      scrollable: find.descendant(of: find.byKey(const Key('source-content-detail-sheet')), matching: _detailVerticalScrollableFinder()),
    );
    await tester.ensureVisible(find.byKey(const Key('source-detail-load-more-chapters')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('source-detail-load-more-chapters')));
    await tester.pumpAndSettle();

    expect(find.text('第二十一章'), findsOneWidget);
    expect(find.text('第二十二章'), findsOneWidget);
    expect(gateway.chapterRequests, 1);
  });

  testWidgets('keeps the list summary visible while detail data is loading', (tester) async {
    await _setViewport(tester, const Size(390, 900));
    final gateway = _DelayedDetailGateway();
    await tester.pumpWidget(_DetailGoldenHost(gateway: gateway));
    await tester.pump();
    await tester.pump();

    expect(find.text('变身绝色女神（ai加料）'), findsWidgets);
    expect(find.text('加载中'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('source-detail-start-reading'))).onPressed, isNull);

    gateway.complete();
    await tester.pumpAndSettle();
    expect(find.text('来源页面已验证的作品简介。'), findsOneWidget);
    expect(find.text('加载中'), findsNothing);
  });

  testWidgets('uses a compact shimmering detail skeleton before a summary exists', (tester) async {
    await _setViewport(tester, const Size(390, 900));
    final gateway = _DelayedDetailGateway();
    await tester.pumpWidget(_DetailGoldenHost(gateway: gateway, includeInitialContent: false));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('source-detail-loading')), findsOneWidget);
    expect(find.text('加载中'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    gateway.complete();
    await tester.pumpAndSettle();
    expect(find.text('来源页面已验证的作品简介。'), findsOneWidget);
  });

  testWidgets('shows stable error details over retained preview and can retry', (tester) async {
    await _setViewport(tester, const Size(390, 900));
    final gateway = _RetryingDetailGateway();
    String? copiedPayload;
    await tester.pumpWidget(_DetailGoldenHost(gateway: gateway, onCopyFailure: (payload) async => copiedPayload = payload));
    await tester.pumpAndSettle();

    expect(find.text('详情加载失败'), findsOneWidget);
    expect(find.textContaining('错误码：invalid_format'), findsOneWidget);
    expect(find.textContaining('失败阶段：source.getDetail.v1'), findsOneWidget);
    expect(find.text('原始原因：Source detail response had an unexpected shape.'), findsOneWidget);
    expect(find.text('已保留列表预览；实时详情和可播放选集尚未加载。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('source-detail-error-copy')));
    await tester.pump();
    expect(copiedPayload, contains('详情加载失败'));
    expect(copiedPayload, contains('数据源名称：'));
    expect(copiedPayload, contains('插件 ID：'));
    expect(copiedPayload, contains('插件版本：'));
    expect(copiedPayload, contains('内容 ID：'));
    expect(copiedPayload, contains('原始原因：Source detail response had an unexpected shape.'));
    expect(copiedPayload, contains('失败阶段：source.getDetail.v1'));
    expect(copiedPayload, contains('可重试：不建议'));
    expect(find.byKey(const Key('source-detail-start-reading')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('source-detail-start-reading'))).onPressed, isNull);

    await tester.tap(find.byKey(const Key('source-detail-retry')));
    await tester.pumpAndSettle();

    expect(gateway.detailRequests, 2);
    expect(find.byKey(const Key('source-content-sheet-failure')), findsNothing);
    expect(find.text('来源页面已验证的作品简介。'), findsOneWidget);
  });
}

Finder _detailVerticalScrollableFinder() =>
    find.byWidgetPredicate((Widget widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down);

class _DetailGoldenHost extends StatelessWidget {
  const _DetailGoldenHost({
    this.gateway,
    this.useReference = false,
    this.includeInitialContent = true,
    this.onRecommendationRequested,
    this.onCopyFailure,
  });

  final _GoldenDetailGateway? gateway;
  final bool useReference;
  final bool includeInitialContent;
  final SourceRecommendationRequested? onRecommendationRequested;
  final SourceDetailFailureCopy? onCopyFailure;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    themeMode: ThemeMode.light,
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData mediaQuery = MediaQuery.of(context);
      return MediaQuery(
        data: mediaQuery.copyWith(padding: const EdgeInsets.only(top: 24), viewPadding: const EdgeInsets.only(top: 24)),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: _DetailEntry(
      gateway: gateway ?? _GoldenDetailGateway(useReference: useReference),
      includeInitialContent: includeInitialContent,
      onRecommendationRequested: onRecommendationRequested,
      onCopyFailure: onCopyFailure,
    ),
  );
}

class _DetailEntry extends StatefulWidget {
  const _DetailEntry({
    required this.gateway,
    required this.includeInitialContent,
    required this.onRecommendationRequested,
    this.onCopyFailure,
  });

  final _GoldenDetailGateway gateway;
  final bool includeInitialContent;
  final SourceRecommendationRequested? onRecommendationRequested;
  final SourceDetailFailureCopy? onCopyFailure;

  @override
  State<_DetailEntry> createState() => _DetailEntryState();
}

class _DetailEntryState extends State<_DetailEntry> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showSourceContentDetailSheet(
          context,
          gateway: widget.gateway,
          pluginId: widget.gateway.pluginId,
          id: widget.gateway.bookId,
          initialContent: widget.includeInitialContent ? widget.gateway.detail.summary : null,
          initialSourceName: widget.includeInitialContent ? widget.gateway.detail.sourceName : null,
          relatedContents: widget.gateway.recommendations,
          onExternalUrlRequested: (_) async => true,
          onRecommendationRequested: widget.onRecommendationRequested,
          onCopyFailure: widget.onCopyFailure ?? (String _) async {},
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

class _GoldenDetailGateway implements SourceContentGateway {
  _GoldenDetailGateway({this.useReference = false, this.catalogItemCount});

  final bool useReference;
  final int? catalogItemCount;
  var chapterRequests = 0;

  String get pluginId => useReference ? AliceBookHouseDetailFixture.referencePluginId : AliceBookHouseDetailFixture.pluginId;
  String get bookId => useReference ? AliceBookHouseDetailFixture.referenceBookId : AliceBookHouseDetailFixture.bookId;
  PluginContentDetail get detail => useReference ? AliceBookHouseDetailFixture.referenceDetail : AliceBookHouseDetailFixture.detail;
  List<PluginContentSummary> get recommendations =>
      useReference ? AliceBookHouseDetailFixture.referenceRecommendations : AliceBookHouseDetailFixture.recommendations;

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => detail;

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async {
    chapterRequests += 1;
    final base = useReference ? AliceBookHouseDetailFixture.referenceCatalog : AliceBookHouseDetailFixture.firstCatalogPage;
    final count = catalogItemCount;
    if (count == null || count <= base.items.length) return base;
    return PluginChaptersResult(
      pluginId: base.pluginId,
      sourceName: base.sourceName,
      items: <PluginChapterSummary>[
        ...base.items,
        for (var index = base.items.length; index < count; index += 1)
          PluginChapterSummary(
            id: 'chapter:${index + 1}',
            title: '第${_chineseNumber(index + 1)}章',
            order: index,
            url: null,
            volumeTitle: null,
            wordCount: null,
            updatedAt: null,
            isLocked: false,
            attributes: const <PluginContentAttribute>[],
          ),
      ],
    );
  }

  @override
  Future<List<PluginSourceDescriptor>> listSources() async => throw UnimplementedError();

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) async =>
      throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) async =>
      throw UnimplementedError();

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) async => throw UnimplementedError();

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async =>
      throw UnimplementedError();
}

final class _DelayedDetailGateway extends _GoldenDetailGateway {
  _DelayedDetailGateway() : super();

  final Completer<PluginContentDetail> _detail = Completer<PluginContentDetail>();
  final Completer<PluginChaptersResult> _chapters = Completer<PluginChaptersResult>();

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) => _detail.future;

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) => _chapters.future;

  void complete() {
    _detail.complete(detail);
    _chapters.complete(AliceBookHouseDetailFixture.firstCatalogPage);
  }
}

final class _RetryingDetailGateway extends _GoldenDetailGateway {
  var detailRequests = 0;

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async {
    detailRequests += 1;
    if (detailRequests == 1) {
      throw AppError.fromCode(AppErrorCode.invalidFormat, detail: 'Source detail response had an unexpected shape.');
    }
    return detail;
  }
}

String _chineseNumber(int value) => switch (value) {
  21 => '二十一',
  22 => '二十二',
  _ => '$value',
};

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
