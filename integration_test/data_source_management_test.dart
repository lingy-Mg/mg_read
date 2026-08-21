import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the light data-source management reference screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: PluginRuntimeStatusPage(
          onBackRequested: () {},
          onDestinationRequested: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('管理数据来源'), findsOneWidget);
    expect(find.text('我的数据来源'), findsOneWidget);
    expect(find.text('已启用 6/12'), findsOneWidget);
    expect(find.text('数据来源分组'), findsNothing);
    expect(find.byKey(const Key('data-source-qidian')), findsOneWidget);
    expect(find.byKey(const Key('data-source-toggle-17k')), findsOneWidget);
    expect(find.byKey(const Key('data-source-add')), findsOneWidget);

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('data_source_management_light');
  });
}
