import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';

import 'plugin_runtime_status_page_fixture.dart';

/// Widget renders verify themes and action sheets without starting a Runtime.
void main() {
  setUpAll(() async {
    final FontLoader miSans = FontLoader('packages/novel_reader_ui/MiSans')
      ..addFont(rootBundle.load('packages/novel_reader_ui/assets/fonts/MiSansVF.ttf'));
    final FontLoader materialIcons = FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait(<Future<void>>[miSans.load(), materialIcons.load()]);
  });

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';
    testWidgets('renders management and sheets in $mode theme', (tester) async {
      await _setViewport(tester);
      await tester.pumpWidget(_host(dark));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/data_source_management_compact_$mode.png'));
      await tester.tap(find.byKey(const Key('data-source-more')));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/data_source_management_tools_$mode.png'));
      Navigator.of(tester.element(find.text('数据源工具'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('data-source-add')));
      await tester.pumpAndSettle();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/data_source_management_import_$mode.png'));
      expect(tester.takeException(), isNull);
    });
  }
}

Widget _host(bool dark) => ProviderScope(
  overrides: [pluginRuntimeConnectionProvider.overrideWith((Ref ref) async => dataSourceManagementFixture)],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(top: AppDetailMetrics.minimumTopInset)),
      child: child!,
    ),
    home: PluginRuntimeStatusPage(
      onBackRequested: () {},
      onDestinationRequested: (_) {},
      onVerifyAllRequested: () {},
      onRuntimeStatusRequested: () {},
    ),
  ),
);

Future<void> _setViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(AppDetailMetrics.viewportWidth, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pump();
}
