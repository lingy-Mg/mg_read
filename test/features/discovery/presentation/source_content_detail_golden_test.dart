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
    await tester.pumpWidget(const _DetailGoldenHost());
    await tester.pumpAndSettle();

    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels,
      0,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('source-detail-cover'))).dy,
      88,
    );
    expect(find.text('喜欢老虎'), findsOneWidget);
    expect(find.text('185.96万'), findsOneWidget);
    expect(find.text('733'), findsOneWidget);
    expect(find.text('章节 · 连载中'), findsOneWidget);
    expect(find.text('12210'), findsOneWidget);
    expect(find.text('热度 · 收藏 49'), findsOneWidget);
    expect(find.text('变身'), findsOneWidget);
    expect(find.text('ai加料'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/source_content_detail_compact_light.png'),
    );
  });

  testWidgets('loads only the next catalog page when requested', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 900));
    final gateway = _GoldenDetailGateway();
    await tester.pumpWidget(_DetailGoldenHost(gateway: gateway));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byKey(const Key('source-detail-load-more-chapters')),
      280,
      scrollable: find.descendant(
        of: find.byKey(const Key('source-content-detail-sheet')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(const Key('source-detail-load-more-chapters')));
    await tester.pumpAndSettle();

    expect(find.text('第三章 风华绝代'), findsOneWidget);
    expect(find.text('第四章 应聘'), findsOneWidget);
    expect(gateway.chapterRequests, <String?>[null, 'catalog-page:1:2']);
  });
}

class _DetailGoldenHost extends StatelessWidget {
  const _DetailGoldenHost({this.gateway});

  final _GoldenDetailGateway? gateway;

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
    home: _DetailEntry(gateway: gateway ?? _GoldenDetailGateway()),
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
          pluginId: AliceBookHouseDetailFixture.pluginId,
          id: AliceBookHouseDetailFixture.bookId,
          onExternalUrlRequested: (_) async => true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold();
}

class _GoldenDetailGateway implements SourceContentGateway {
  final List<String?> chapterRequests = <String?>[];

  @override
  Future<PluginContentDetail> getDetail({
    required String pluginId,
    required String id,
  }) async => AliceBookHouseDetailFixture.detail;

  @override
  Future<PluginChaptersResult> getChapters({
    required String pluginId,
    required String id,
    String? cursor,
    int pageSize = 50,
  }) async {
    chapterRequests.add(cursor);
    return cursor == null
        ? AliceBookHouseDetailFixture.firstCatalogPage
        : AliceBookHouseDetailFixture.secondCatalogPage;
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

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
