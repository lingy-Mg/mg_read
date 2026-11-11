/// 数据源管理入口契约：直接启停、详情路由、组合筛选与次级内容操作。
/// 仅验证 Widget，不替代真实 Runtime 和设备验收。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/data_source_management_row.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';
import 'plugin_runtime_status_page_fixture.dart';

void main() {
  testWidgets('TV source filter lets the remote leave the editor vertically', (tester) async {
    await tester.pumpWidget(TvModeScope(enabled: true, onChanged: (_) {}, child: _host()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tv-data-source-search')));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('data-source-search'));
    await tester.enterText(field, '起点');
    await tester.pumpAndSettle();
    final editor = tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)));
    expect(editor.focusNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(editor.focusNode.hasFocus, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('management opens details and exposes direct enable switches', (tester) async {
    String? detail;
    String? discovered;
    await tester.pumpWidget(_host(onDetail: (id) => detail = id, onDiscover: (id) => discovered = id));
    await tester.pumpAndSettle();
    expect(find.text('数据源管理'), findsOneWidget);
    expect(find.text('6 个数据源 · 4 已启用'), findsOneWidget);
    expect(find.byKey(const Key('data-source-description-org.mgread.qidian')), findsNothing);
    final toggle = find.byKey(const Key('data-source-enabled-org.mgread.qidian'));
    await tester.ensureVisible(toggle);
    await tester.tap(find.text('起点中文网'));
    expect(detail, 'org.mgread.qidian');
    expect(discovered, isNull);
    expect(tester.widget<Switch>(toggle).value, isTrue);
    await tester.tap(find.byKey(const Key('data-source-menu-org.mgread.qidian')));
    await tester.pumpAndSettle();
    expect(find.text('停用数据源'), findsNothing);
    await tester.tap(find.text('浏览内容'));
    await tester.pumpAndSettle();
    expect(discovered, 'org.mgread.qidian');
    expect(tester.takeException(), isNull);
  });

  testWidgets('status and content filters compose with identifier and website search', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-status-disabled')));
    await tester.pumpAndSettle();
    expect(find.text('起点中文网'), findsNothing);
    expect(find.text('2 / 6'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('data-source-search')), 'org.mgread.17k');
    await tester.pumpAndSettle();
    expect(find.text('1 / 6'), findsOneWidget);
    await tester.tap(find.byKey(const Key('data-source-filter-video')));
    await tester.pumpAndSettle();
    final reset = find.text('清除筛选');
    await tester.ensureVisible(reset);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(find.text('共 6 个'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('data-source-search')), 'www.qidian.com');
    await tester.pumpAndSettle();
    expect(find.text('1 / 6'), findsOneWidget);
    expect(find.text('起点中文网'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled and missing-homepage sources keep management and content actions distinct', (tester) async {
    bool? enabled;
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: DataSourceManagementRow(
            source: const DataSourceManagementRowData(
              id: 'disabled',
              name: '停用源',
              description: '完整说明',
              kindLabel: '小说',
              enabled: false,
              brand: DataSourceBrand.generic,
              isDevelopment: false,
            ),
            isPending: false,
            onPressed: () {},
            onChanged: (value) => enabled = value,
            onDiscover: () => opened = true,
            onSearch: () => opened = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-enabled-disabled')));
    expect(enabled, isTrue);
    await tester.tap(find.byKey(const Key('data-source-menu-disabled')));
    await tester.pumpAndSettle();
    for (final title in ['浏览内容', '搜索内容', '打开来源网站']) {
      final item = tester.widget<PopupMenuItem<String>>(find.ancestor(of: find.text(title), matching: find.byType(PopupMenuItem<String>)));
      expect(item.enabled, isFalse);
    }
    expect(opened, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('filters by content type and purpose and recovers from no matches', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-filter-video')));
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的数据源'), findsOneWidget);
    await tester.ensureVisible(find.text('清除筛选'));
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('data-source-search')), '阅文');
    await tester.pumpAndSettle();
    expect(find.text('起点中文网'), findsOneWidget);
    expect(find.text('番茄小说'), findsNothing);
    expect(find.text('1 / 6'), findsOneWidget);
    await tester.tap(find.byKey(const Key('data-source-search-clear')));
    await tester.pumpAndSettle();
    expect(find.text('共 6 个'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('narrow large-text cards remain usable in ${dark ? 'dark' : 'light'} theme', (tester) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(_host(dark: dark, large: true));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('data-source-enabled-org.mgread.qidian')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('data-source-enabled-org.mgread.qidian')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('keeps diagnostics and verification in management tools', (tester) async {
    var verified = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pluginRuntimeConnectionProvider.overrideWith((ref) async => dataSourceManagementFixture)],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginRuntimeStatusPage(
            onBackRequested: () {},
            onDestinationRequested: (_) {},
            onVerifyAllRequested: () => verified = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-verify-all')));
    await tester.pumpAndSettle();
    expect(verified, isTrue);
  });
}

Widget _host({
  ValueChanged<String>? onDiscover,
  ValueChanged<String>? onSearch,
  ValueChanged<String>? onDetail,
  Future<bool> Function(Uri)? launchSourceUrl,
  bool dark = false,
  bool large = false,
}) => ProviderScope(
  overrides: [pluginRuntimeConnectionProvider.overrideWith((ref) async => dataSourceManagementFixture)],
  child: MaterialApp(
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(large ? 2 : 1)),
      child: child!,
    ),
    home: PluginRuntimeStatusPage(
      onBackRequested: () {},
      onDestinationRequested: (_) {},
      onSourcePressed: onDetail ?? (_) {},
      onDiscoverSource: onDiscover ?? (_) {},
      onSearchSource: onSearch ?? (_) {},
      launchSourceUrl: launchSourceUrl,
    ),
  ),
);
