/// TV 管理页的视觉和遥控回归：空库、导入、分类、确认式搜索、菜单与短屏滚动。
/// 使用 Runtime 窄端口替身；截图证明 Widget 布局，不代表真机验收。
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_tv_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:mg_read/shared/presentation/widgets/tv_focusable.dart';
import 'plugin_runtime_status_page_fixture.dart';

const _empty = PluginRuntimeConnection(isHealthy: true, nodeVersion: '26', runtimeVersion: 'test', plugins: []);

void main() {
  setUpAll(() async {
    await (FontLoader(
      'packages/novel_reader_ui/MiSans',
    )..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets('empty TV library focuses add and hides irrelevant filters', (tester) async {
    _viewport(tester);
    await tester.pumpWidget(_host(connection: _empty));
    await tester.pumpAndSettle();
    expect(_focus(tester, 'data-source-add').hasFocus, isTrue);
    expect(find.byKey(const Key('data-source-filters')), findsNothing);
    expect(find.byType(TextField), findsNothing);
    await _golden(tester, 'tv_data_source_empty_dark');
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.byKey(const Key('data-source-add-online-repository')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV import shows one status and keeps add disabled until completion', (tester) async {
    _viewport(tester);
    await tester.pumpWidget(_host(connection: _empty));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(PluginRuntimeStatusPage)));
    final completer = Completer<List<PluginTransferImportResult>?>();
    final import = container
        .read(pluginRuntimeSourceImportProvider.notifier)
        .importSourceCollection(() => completer.future, initialMessage: '正在读取在线插件仓库');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('正在读取在线插件仓库'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byKey(const Key('data-source-import-log')), findsNothing);
    expect(tester.widget<TvFocusable>(find.byKey(const Key('data-source-add'))).onPressed, isNull);
    await _golden(tester, 'tv_data_source_import_dark');
    completer.complete(null);
    await import;
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<TvFocusable>(find.byKey(const Key('data-source-add'))).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV direction keys enter sources and menu returns focus without launching content', (tester) async {
    _viewport(tester);
    String? opened;
    String? detail;
    await tester.pumpWidget(_host(onDiscover: (id) => opened = id, onDetail: (id) => detail = id));
    await tester.pumpAndSettle();
    _focus(tester, 'data-source-filter-all').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focus(tester, 'data-source-open-org.mgread.qidian').hasFocus, isTrue);
    await _golden(tester, 'tv_data_source_list_dark');
    await _key(tester, LogicalKeyboardKey.select);
    expect(detail, 'org.mgread.qidian');
    expect(opened, isNull);
    detail = null;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(opened, isNull);
    expect(find.text(qidianWebsiteDescription), findsOneWidget);
    _focus(tester, 'data-source-detail-org.mgread.qidian').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.select);
    expect(detail, 'org.mgread.qidian');
    expect(_focus(tester, 'data-source-open-org.mgread.qidian').hasFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.contextMenu);
    expect(find.text('停用数据源'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.escape);
    expect(_focus(tester, 'data-source-open-org.mgread.qidian').hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV search applies on confirmation and supports cancel and clearing no matches', (tester) async {
    _viewport(tester);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tv-data-source-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('data-source-search')), '起点');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('番茄小说'), findsNothing);
    expect(find.text('起点中文网'), findsOneWidget);
    expect(_focus(tester, 'tv-data-source-search').hasFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.select);
    await tester.enterText(find.byKey(const Key('data-source-search')), '不存在');
    await _key(tester, LogicalKeyboardKey.escape);
    expect(find.text('起点中文网'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.select);
    await tester.enterText(find.byKey(const Key('data-source-search')), '不存在');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的数据源'), findsOneWidget);
    _focus(tester, 'tv-source-reset').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('番茄小说'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short large-text TV page scrolls categories and sources using directions', (tester) async {
    _viewport(tester, const Size(640, 360));
    await tester.pumpWidget(_host(scale: 1.6));
    await tester.pumpAndSettle();
    _focus(tester, 'data-source-filter-all').requestFocus();
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(tester.takeException(), isNull);
    }
    expect(_focus(tester, 'data-source-filter-manga').hasFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.select);
    expect(find.text('没有匹配的数据源'), findsOneWidget);
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focus(tester, 'tv-source-reset').hasFocus, isTrue);
    await _key(tester, LogicalKeyboardKey.select);
    _focus(tester, 'data-source-filter-all').requestFocus();
    await tester.pumpAndSettle();
    await _key(tester, LogicalKeyboardKey.arrowRight);
    expect(_focus(tester, 'data-source-open-org.mgread.qidian').hasFocus, isTrue);
    for (var i = 0; i < 5; i++) {
      await _key(tester, LogicalKeyboardKey.arrowDown);
      expect(tester.takeException(), isNull);
    }
    expect(_focus(tester, 'data-source-open-org.mgread.17k').hasFocus, isTrue);
    expect(find.byKey(const Key('data-source-open-org.mgread.17k')).hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('data-source-add')).hitTestable(), findsOneWidget);
    await _golden(tester, 'tv_data_source_short_large_text');
  });
}

Widget _host({
  PluginRuntimeConnection connection = dataSourceManagementFixture,
  double scale = 1,
  ValueChanged<String>? onDiscover,
  ValueChanged<String>? onDetail,
}) => ProviderScope(
  overrides: [
    pluginRuntimeConnectionProvider.overrideWith((ref) async => connection),
    pluginRuntimeGatewayProvider.overrideWithValue(_Gateway()),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: appTvTheme(AppTheme.dark()),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: TvModeScope(enabled: true, onChanged: (_) {}, child: child!),
    ),
    home: PluginRuntimeStatusPage(
      onBackRequested: () {},
      onDestinationRequested: (_) {},
      onDiscoverSource: onDiscover ?? (_) {},
      onSearchSource: (_) {},
      onSourcePressed: onDetail ?? (_) {},
    ),
  ),
);

void _viewport(WidgetTester tester, [Size size = const Size(1280, 720)]) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

FocusNode _focus(WidgetTester tester, String key) =>
    tester.widget<Focus>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Focus)).first).focusNode!;

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<void> _golden(WidgetTester tester, String name) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

class _Gateway implements PluginRuntimeGateway {
  @override
  Stream<RuntimeInitializationProgress> get initialization => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
