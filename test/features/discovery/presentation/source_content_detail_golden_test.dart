import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_sheet.dart';

import 'fixtures/alice_book_house_detail_fixture.dart';

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

  testWidgets('matches the compact light book detail reference baseline', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(const _DetailGoldenHost(useReference: true));
    await tester.pumpAndSettle();

    expect(
      tester
          .state<ScrollableState>(_detailVerticalScrollableFinder())
          .position
          .pixels,
      0,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('source-detail-cover'))).dy,
      100,
    );
    expect(find.byKey(const Key('source-detail-header-title')), findsOneWidget);
    expect(find.text('爱潜水的乌贼'), findsWidgets);
    expect(find.text('447万'), findsOneWidget);
    expect(find.text('1268'), findsOneWidget);
    expect(find.text('已完结'), findsOneWidget);
    expect(find.text('9.7'), findsOneWidget);
    expect(find.text('42.3万人评分'), findsOneWidget);
    expect(find.text('克苏鲁'), findsWidgets);
    expect(find.text('西幻'), findsOneWidget);
    expect(
      find.byKey(const Key('source-detail-recommendations-scroll')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('source-detail-recommendations-refresh')),
      findsOneWidget,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/source_content_detail_compact_light.png'),
    );
  });

  testWidgets(
    'formats numeric source stats without duplicating the word label',
    (WidgetTester tester) async {
      await _setViewport(tester, const Size(390, 900));
      await tester.pumpWidget(const _DetailGoldenHost());
      await tester.pumpAndSettle();

      expect(find.text('1.22万'), findsOneWidget);
      expect(find.text('185.96万'), findsOneWidget);
      expect(find.text('字数：1859600'), findsNothing);
    },
  );

  testWidgets('uses the complete catalog length as the chapter count', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(_DetailGoldenHost(gateway: _GoldenDetailGateway()));
    await tester.pumpAndSettle();

    expect(find.text('共 4 章', skipOffstage: false), findsOneWidget);
  });

  testWidgets('reveals more chapters locally without another source request', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    final gateway = _GoldenDetailGateway(catalogItemCount: 22);
    await tester.pumpWidget(_DetailGoldenHost(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('source-detail-load-more-chapters')),
      280,
      scrollable: find.descendant(
        of: find.byKey(const Key('source-content-detail-sheet')),
        matching: _detailVerticalScrollableFinder(),
      ),
    );
    await tester.tap(find.byKey(const Key('source-detail-load-more-chapters')));
    await tester.pumpAndSettle();

    expect(find.text('第二十一章'), findsOneWidget);
    expect(find.text('第二十二章'), findsOneWidget);
    expect(gateway.chapterRequests, 1);
  });

  testWidgets('keeps the list summary visible while detail data is loading', (
    tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    final gateway = _DelayedDetailGateway();
    await tester.pumpWidget(_DetailGoldenHost(gateway: gateway));
    await tester.pump();
    await tester.pump();

    expect(find.text('变身绝色女神（ai加料）'), findsWidgets);
    expect(find.text('正在补充详情…'), findsOneWidget);

    gateway.complete();
    await tester.pumpAndSettle();
    expect(find.text('来源页面已验证的作品简介。'), findsOneWidget);
    expect(find.text('正在补充详情…'), findsNothing);
  });
}

Finder _detailVerticalScrollableFinder() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is Scrollable && widget.axisDirection == AxisDirection.down,
);

class _DetailGoldenHost extends StatelessWidget {
  const _DetailGoldenHost({this.gateway, this.useReference = false});

  final _GoldenDetailGateway? gateway;
  final bool useReference;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    themeMode: ThemeMode.light,
    builder: (BuildContext context, Widget? child) {
      final MediaQueryData mediaQuery = MediaQuery.of(context);
      return MediaQuery(
        data: mediaQuery.copyWith(
          padding: const EdgeInsets.only(top: 24),
          viewPadding: const EdgeInsets.only(top: 24),
        ),
        child: child ?? const SizedBox.shrink(),
      );
    },
    home: _DetailEntry(
      gateway: gateway ?? _GoldenDetailGateway(useReference: useReference),
    ),
  );
}

class _DetailEntry extends StatefulWidget {
  const _DetailEntry({required this.gateway});

  final _GoldenDetailGateway gateway;

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
          initialContent: widget.gateway.detail.summary,
          initialSourceName: widget.gateway.detail.sourceName,
          relatedContents: widget.gateway.recommendations,
          onExternalUrlRequested: (_) async => true,
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

  String get pluginId => useReference
      ? AliceBookHouseDetailFixture.referencePluginId
      : AliceBookHouseDetailFixture.pluginId;
  String get bookId => useReference
      ? AliceBookHouseDetailFixture.referenceBookId
      : AliceBookHouseDetailFixture.bookId;
  PluginContentDetail get detail => useReference
      ? AliceBookHouseDetailFixture.referenceDetail
      : AliceBookHouseDetailFixture.detail;
  List<PluginContentSummary> get recommendations => useReference
      ? AliceBookHouseDetailFixture.referenceRecommendations
      : AliceBookHouseDetailFixture.recommendations;

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async => detail;

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) async {
    chapterRequests += 1;
    final base = useReference
        ? AliceBookHouseDetailFixture.referenceCatalog
        : AliceBookHouseDetailFixture.firstCatalogPage;
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

final class _DelayedDetailGateway extends _GoldenDetailGateway {
  _DelayedDetailGateway() : super();

  final Completer<PluginContentDetail> _detail =
      Completer<PluginContentDetail>();
  final Completer<PluginChaptersResult> _chapters =
      Completer<PluginChaptersResult>();

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) => _detail.future;

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
  }) => _chapters.future;

  void complete() {
    _detail.complete(detail);
    _chapters.complete(AliceBookHouseDetailFixture.firstCatalogPage);
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
