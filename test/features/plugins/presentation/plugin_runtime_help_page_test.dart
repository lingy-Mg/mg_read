/// 数据源说明页 Widget 回归测试。
///
/// 职责：
/// - 验证 Runtime Debug 开关在卡片表面内正确承载 ListTile 材质效果。
///
/// 注意：
/// - 仅覆盖 Flutter Widget 层，不替代 Runtime listener 或平台验收。
///
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_runtime_help_page.dart';

import '../../../app/mg_read_app_test_support.dart';

void main() {
  testWidgets('Runtime Debug switch paints on its own Material surface', (WidgetTester tester) async {
    final reportedErrors = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = reportedErrors.add;
    addTearDown(() => FlutterError.onError = previousHandler);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [pluginRuntimeGatewayProvider.overrideWithValue(const TestReadyPluginRuntimeGateway())],
        child: MaterialApp(theme: AppTheme.light(), home: const PluginRuntimeHelpPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('runtime-debug-http-toggle')), findsOneWidget);
    expect(
      reportedErrors.where((details) => details.exceptionAsString().contains('ListTile background color or ink splashes may be invisible')),
      isEmpty,
    );
  });

  testWidgets('lists every Debug IP with separate copy and open actions', (WidgetTester tester) async {
    const loopbackEndpoint = 'http://127.0.0.1:54321/__debug';
    const lanEndpoint = 'http://192.168.1.8:54321/__debug';
    String? copiedEndpoint;
    final openedEndpoints = <Uri>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copiedEndpoint = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginRuntimeGatewayProvider.overrideWithValue(
            const TestReadyPluginRuntimeGateway(
              debugHttpStatus: PluginRuntimeDebugHttp(
                configuredEnabled: true,
                enabled: true,
                endpoints: <String>[loopbackEndpoint, lanEndpoint],
                startedAt: '2026-08-29T13:00:00.000Z',
                usingTemporaryPort: true,
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginRuntimeHelpPage(
            debugEndpointLauncher: (endpoint) async {
              openedEndpoints.add(endpoint);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('runtime-debug-http-temporary-port')), findsOneWidget);
    expect(find.text('可访问 IP 地址（2）'), findsOneWidget);
    expect(find.text('本机 IP：127.0.0.1'), findsOneWidget);
    expect(find.text('局域网 IP：192.168.1.8'), findsOneWidget);
    expect(find.text('端口：54321'), findsNWidgets(2));
    expect(find.text('复制'), findsNWidgets(2));
    expect(find.text('打开'), findsNWidgets(2));
    expect(find.byKey(const Key('runtime-debug-http-copy-$loopbackEndpoint')), findsOneWidget);
    expect(find.byKey(const Key('runtime-debug-http-open-$loopbackEndpoint')), findsOneWidget);
    expect(find.byKey(const Key('runtime-debug-http-copy-$lanEndpoint')), findsOneWidget);
    expect(find.byKey(const Key('runtime-debug-http-open-$lanEndpoint')), findsOneWidget);

    final copyLoopbackEndpoint = find.byKey(const Key('runtime-debug-http-copy-$loopbackEndpoint'));
    await tester.ensureVisible(copyLoopbackEndpoint);
    await tester.pumpAndSettle();
    await tester.tap(copyLoopbackEndpoint);
    await tester.pump();

    expect(copiedEndpoint, loopbackEndpoint);

    final openLanEndpoint = find.byKey(const Key('runtime-debug-http-open-$lanEndpoint'));
    await tester.ensureVisible(openLanEndpoint);
    await tester.pumpAndSettle();
    await tester.tap(openLanEndpoint);
    await tester.pump();

    expect(openedEndpoints, <Uri>[Uri.parse(lanEndpoint)]);
    expect(tester.takeException(), isNull);
  });
}
