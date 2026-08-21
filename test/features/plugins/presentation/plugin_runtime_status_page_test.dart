import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_status_page.dart';

import 'plugin_runtime_status_page_fixture.dart';

void main() {
  testWidgets('matches the compact six-source management reference layout', (
    WidgetTester tester,
  ) async {
    await _setViewport(tester, const Size(390, 690));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginRuntimeConnectionProvider.overrideWith(
            (Ref ref) async => dataSourceManagementFixture,
          ),
        ],
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
    expect(find.text('我的数据来源'), findsOneWidget);
    expect(find.text('已启用 4/6'), findsOneWidget);
    expect(find.text('数据来源分组'), findsNothing);
    expect(
      find.byKey(const Key('data-source-management-card')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('data-source-add')), findsOneWidget);
    expect(
      find.byKey(const Key('data-source-toggle-org.mgread.qidian')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('data-source-toggle-org.mgread.17k')),
      findsOneWidget,
    );
    expect(find.text('首页'), findsNothing);
    expect(find.text('发现'), findsNothing);
    expect(find.text('书架'), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);

    final Rect topBar = tester.getRect(
      find.byKey(const Key('data-source-top-bar')),
    );
    final Rect card = tester.getRect(
      find.byKey(const Key('data-source-management-card')),
    );
    expect(topBar.top, closeTo(0, 0.1));
    expect(topBar.height, AppSpacing.dataSourceTopBarHeight);
    expect(
      card.top,
      closeTo(AppSpacing.dataSourceTopBarHeight + AppSpacing.regular, 0.1),
    );
    expect(card.left, closeTo(AppDetailMetrics.horizontalPadding, 0.1));
    expect(
      card.width,
      closeTo(390 - AppDetailMetrics.horizontalPadding * 2, 0.1),
    );

    final Rect firstSource = tester.getRect(
      find.byKey(const Key('data-source-org.mgread.qidian')),
    );
    final Rect lastSource = tester.getRect(
      find.byKey(const Key('data-source-org.mgread.17k')),
    );
    expect(firstSource.height, AppSpacing.dataSourceRowHeight);
    expect(lastSource.bottom, greaterThan(firstSource.bottom));
    expect(tester.takeException(), isNull);
  });
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
