import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_health_page.dart';

void main() {
  testWidgets('renders Node health, memory and plugin sections', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginRuntimeStatusProvider.overrideWith(
            (Ref ref) async => _statusFixture,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginRuntimeHealthPage(onBackRequested: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Node 状态'), findsOneWidget);
    expect(find.text('运行正常'), findsOneWidget);
    expect(find.text('Node.js'), findsOneWidget);
    expect(find.text('24.16.0'), findsOneWidget);
    expect(find.byKey(const Key('runtime-health-memory-card')), findsOneWidget);
    expect(find.text('进程占用 RSS'), findsOneWidget);
    expect(find.text('数据源插件'), findsOneWidget);
    expect(find.text('2/2 已启用'), findsOneWidget);
    expect(find.text('演示数据源'), findsOneWidget);
    expect(find.text('测试数据源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('can refresh the Runtime snapshot', (WidgetTester tester) async {
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginRuntimeStatusProvider.overrideWith((Ref ref) async {
            calls += 1;
            return _statusFixture;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginRuntimeHealthPage(onBackRequested: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    await tester.tap(find.byKey(const Key('runtime-health-refresh')));
    await tester.pumpAndSettle();
    expect(calls, 2);
  });
}

const PluginRuntimeStatus _statusFixture = PluginRuntimeStatus(
  arch: 'x64',
  isHealthy: true,
  memory: PluginRuntimeMemory(
    arrayBuffers: 1024,
    external: 2 * 1024 * 1024,
    heapTotal: 16 * 1024 * 1024,
    heapUsed: 8 * 1024 * 1024,
    rss: 64 * 1024 * 1024,
  ),
  nodeVersion: '24.16.0',
  platform: 'win32',
  plugins: <PluginRuntimePlugin>[
    PluginRuntimePlugin(
      activeVersion: '1.0.0',
      contentKinds: <String>['novel'],
      displayName: '演示数据源',
      enabled: true,
      id: 'org.example.demo',
      name: 'demo',
      pendingVersion: null,
      status: 'active',
    ),
    PluginRuntimePlugin(
      activeVersion: '1.0.0',
      contentKinds: <String>['novel'],
      displayName: '测试数据源',
      enabled: true,
      id: 'org.example.test',
      name: 'test',
      pendingVersion: null,
      status: 'active',
    ),
  ],
  runtimeVersion: '0.2.0-standard.2',
  runtimeKind: 'desktop-node',
  uptime: Duration(minutes: 3, seconds: 12),
);
