import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginRuntimeStatusPage(
            onBackRequested: () {},
            onDestinationRequested: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('管理数据来源'), findsOneWidget);
    expect(find.text('数据来源分组'), findsNothing);

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('data_source_management_light');
  });
}
