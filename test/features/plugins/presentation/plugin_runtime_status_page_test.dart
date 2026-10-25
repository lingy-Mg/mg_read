/// 数据源浏览入口契约：用途、类型筛选、临时跳转和次要管理操作。
/// 仅验证 Widget，不替代真实 Runtime 和设备验收。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/data_source_management_row.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';
import 'plugin_runtime_status_page_fixture.dart';

void main() {
  testWidgets('missing source homepage leaves discovery and search available', (tester) async {
    var discovered = false;
    var searched = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: DataSourceManagementRow(
            source: const DataSourceManagementRowData(
              id: 'legacy',
              name: '旧数据源',
              description: '局域网传输的旧插件',
              kindLabel: '小说',
              enabled: true,
              brand: DataSourceBrand.generic,
              isDevelopment: false,
            ),
            isPending: false,
            onPressed: () {},
            onChanged: (_) {},
            onDiscover: () => discovered = true,
            onSearch: () => searched = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('缺少'), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const Key('data-source-open-url-legacy'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('data-source-discover-legacy')));
    await tester.tap(find.byKey(const Key('data-source-search-legacy')));
    expect(discovered, isTrue);
    expect(searched, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows purpose and direct source actions without switches', (tester) async {
    String? discovered;
    String? searched;
    String? detail;
    Uri? launched;
    await tester.pumpWidget(
      _host(
        onDiscover: (id) => discovered = id,
        onSearch: (id) => searched = id,
        onDetail: (id) => detail = id,
        launchSourceUrl: (url) async {
          launched = url;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('找到想看的内容'), findsOneWidget);
    expect(find.text('阅文集团旗下原创文学平台'), findsOneWidget);
    expect(find.text('https://www.qidian.com/'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    await tester.tap(find.byKey(const Key('data-source-discover-org.mgread.qidian')));
    expect(discovered, 'org.mgread.qidian');
    await tester.tap(find.byKey(const Key('data-source-search-org.mgread.qidian')));
    expect(searched, 'org.mgread.qidian');
    await tester.tap(find.byKey(const Key('data-source-open-url-org.mgread.qidian')));
    await tester.pumpAndSettle();
    expect(launched, Uri.parse('https://www.qidian.com/'));
    expect(detail, isNull);
    await tester.tap(find.byKey(const Key('data-source-menu-org.mgread.qidian')));
    await tester.pumpAndSettle();
    expect(find.text('停用数据源'), findsOneWidget);
    await tester.tap(find.text('详情与管理'));
    await tester.pumpAndSettle();
    expect(detail, 'org.mgread.qidian');
    expect(tester.takeException(), isNull);
  });

  testWidgets('filters by content type and purpose and recovers from no matches', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('data-source-filter-video')));
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的数据源'), findsOneWidget);
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

  testWidgets('disabled and inactive sources cannot launch; menu retains enable action', (tester) async {
    bool? enabled;
    var launched = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: DataSourceManagementRow(
            source: const DataSourceManagementRowData(
              id: 'disabled',
              name: '停用源',
              description: '完整用途说明',
              kindLabel: '小说',
              enabled: false,
              brand: DataSourceBrand.generic,
              isDevelopment: false,
            ),
            isPending: false,
            onPressed: () {},
            onChanged: (value) => enabled = value,
            onDiscover: () => launched = true,
            onSearch: () => launched = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('data-source-discover-disabled'))).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('data-source-search-disabled'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('data-source-menu-disabled')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用数据源'));
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
    expect(launched, isFalse);
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
      await tester.ensureVisible(find.byKey(const Key('data-source-search-org.mgread.qidian')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('data-source-search-org.mgread.qidian')).hitTestable(), findsOneWidget);
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
