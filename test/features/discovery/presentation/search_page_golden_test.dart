import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/discovery/application/search_history_store.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/search_page.dart';
import 'package:mg_read/shared/presentation/widgets/app_page_title.dart';

void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final FontLoader materialIcons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  testWidgets('matches the compact light search reference baseline', (WidgetTester tester) async {
    await _setViewport(tester, const Size(390, 900));
    await tester.pumpWidget(const _SearchPageGoldenHost());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('search-back')), findsNothing);
    expect(find.byKey(const Key('search-source-selector')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('source-search-query'))).height, AppSpacing.searchQueryHeight);
    final Text pageTitle = tester.widget<Text>(find.descendant(of: find.byType(AppPageTitle), matching: find.text('搜索')));
    expect(pageTitle.style?.fontSize, AppSpacing.pageTitleSize);
    expect(pageTitle.style?.fontWeight, FontWeight.w600);
    expect(tester.getRect(find.byType(AppPageTitle)).top, 30);
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/search_page_compact_light.png'));
  });
}

class _SearchPageGoldenHost extends StatelessWidget {
  const _SearchPageGoldenHost();

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      sourceContentGatewayProvider.overrideWithValue(_GoldenSourceGateway()),
      searchHistoryStoreProvider.overrideWithValue(_GoldenSearchHistoryStore()),
    ],
    child: MaterialApp(
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
      home: SearchPage(onDestinationRequested: (_) {}),
    ),
  );
}

final class _GoldenSearchHistoryStore implements SearchHistoryStore {
  @override
  Future<List<String>> load() async => const <String>['诡秘之主', '大道朝天', '深空彼岸', '宿命之环', '道诡异仙'];

  @override
  Future<void> save(List<String> history) async {}
}

class _GoldenSourceGateway implements SourceContentGateway {
  @override
  Future<List<PluginSourceDescriptor>> listSources() async => const <PluginSourceDescriptor>[];

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnimplementedError();

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      Future<PluginSearchSuggestionsResult>.value(
        PluginSearchSuggestionsResult(
          pluginId: pluginId,
          sourceName: 'Golden 数据源',
          items: const <PluginSearchSuggestion>[],
          nextCursor: null,
        ),
      );

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnimplementedError();

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) => throw UnimplementedError();

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) => throw UnimplementedError();

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      throw UnimplementedError();
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
