import 'dart:io';

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
    if (Platform.isWindows) {
      expect(
        find.byKey(const Key('data-source-open-runtime-directory')),
        findsOneWidget,
      );
    }
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
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);

    final Rect topBar = tester.getRect(
      find.byKey(const Key('data-source-top-bar')),
    );
    final Rect card = tester.getRect(
      find.byKey(const Key('data-source-management-card')),
    );
    expect(topBar.top, closeTo(0, 0.1));
    expect(topBar.height, AppDetailMetrics.topBarHeight);
    expect(
      card.top,
      closeTo(AppDetailMetrics.topBarHeight + AppSpacing.regular, 0.1),
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

  testWidgets('places the data-source header below the Android top inset', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginRuntimeConnectionProvider.overrideWith(
            (Ref ref) async => dataSourceManagementFixture,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
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
          home: PluginRuntimeStatusPage(
            onBackRequested: () {},
            onDestinationRequested: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect topBar = tester.getRect(
      find.byKey(const Key('data-source-top-bar')),
    );
    expect(topBar.top, 24);
    expect(topBar.height, AppDetailMetrics.topBarHeight);
  });

  testWidgets('marks a development source as live and keeps it immutable', (
    WidgetTester tester,
  ) async {
    const developmentSource = PluginRuntimeConnection(
      isHealthy: true,
      nodeVersion: '24.16.0',
      runtimeVersion: '0.2.0-standard.2',
      plugins: <PluginRuntimePlugin>[
        PluginRuntimePlugin(
          activeVersion: '0.1.0',
          contentKinds: <String>['novel'],
          displayName: '发现组件演示',
          enabled: true,
          id: 'org.mgread.discovery-demo',
          name: '@mgread-plugin/discovery-demo',
          pendingVersion: null,
          status: 'development',
        ),
      ],
    );
    await _setViewport(tester, const Size(390, 690));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginRuntimeConnectionProvider.overrideWith(
            (Ref ref) async => developmentSource,
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

    expect(find.text('小说 · 开发源（即时生效）'), findsOneWidget);
    final toggle = tester.widget<Switch>(
      find.byKey(const Key('data-source-toggle-org.mgread.discovery-demo')),
    );
    expect(toggle.value, isTrue);
    expect(toggle.onChanged, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opens a selected data source detail intent', (
    WidgetTester tester,
  ) async {
    String? selected;
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
            onSourcePressed: (String sourceId) => selected = sourceId,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('data-source-org.mgread.qidian')));

    expect(selected, 'org.mgread.qidian');
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
