import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/plugins/application/plugin_cache_manager.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/features/plugins/presentation/plugin_cache_management_page.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

void main() {
  testWidgets('renders path-free data-source cache usage', (tester) async {
    final cacheGateway = _CacheGateway(<PluginCacheUsage>[
      const PluginCacheUsage(pluginId: 'org.mgread.fixture', bytes: 1536),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          pluginCacheGatewayProvider.overrideWithValue(cacheGateway),
          pluginRuntimeConnectionProvider.overrideWith(
            (ref) async => const PluginRuntimeConnection(
              isHealthy: true,
              nodeVersion: '24.16.0',
              runtimeVersion: '0.2.0-standard.2',
              plugins: <PluginRuntimePlugin>[
                PluginRuntimePlugin(
                  activeVersion: '1.0.0',
                  contentKinds: <String>['novel'],
                  displayName: '测试数据源',
                  enabled: true,
                  id: 'org.mgread.fixture',
                  name: 'fixture',
                  pendingVersion: null,
                  status: 'active',
                ),
              ],
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginCacheManagementPage(
            onBackRequested: () {},
            onDestinationRequested: (AppNavigationDestination _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('plugin-cache-content')), findsOneWidget);
    expect(find.text('测试数据源'), findsOneWidget);
    expect(find.text('1.5 KB'), findsOneWidget);
    expect(find.textContaining('plugin-cache'), findsNothing);

    await tester.tap(find.byKey(const Key('plugin-cache-clear-all')));
    await tester.pumpAndSettle();
    expect(find.text('清理全部数据源缓存？'), findsOneWidget);
    expect(find.byKey(const Key('plugin-cache-confirm')), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('清理全部数据源缓存？'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(cacheGateway.usageRequests, greaterThanOrEqualTo(2));
  });
}

final class _CacheGateway implements PluginCacheGateway {
  _CacheGateway(this.usages);

  final List<PluginCacheUsage> usages;
  int usageRequests = 0;

  @override
  Future<PluginCacheClearResult> clearAll() => throw UnimplementedError();

  @override
  Future<PluginCacheClearResult> clearPlugin(String pluginId) =>
      throw UnimplementedError();

  @override
  Future<List<PluginCacheUsage>> listUsage() async {
    usageRequests++;
    return usages;
  }
}
