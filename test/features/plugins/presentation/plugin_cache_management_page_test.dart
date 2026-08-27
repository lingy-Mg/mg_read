import 'dart:async';

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
    final cacheGateway = _CacheGateway();
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
                PluginRuntimePlugin(
                  activeVersion: '1.0.0',
                  contentKinds: <String>['novel'],
                  displayName: '第二数据源',
                  enabled: true,
                  id: 'org.mgread.fixture.second',
                  name: 'fixture-second',
                  pendingVersion: null,
                  status: 'active',
                ),
              ],
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: PluginCacheManagementPage(onBackRequested: () {}, onDestinationRequested: (AppNavigationDestination _) {}),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('plugin-cache-content')), findsOneWidget);
    expect(find.text('测试数据源'), findsOneWidget);
    expect(find.text('第二数据源'), findsOneWidget);
    expect(find.text('正在读取缓存用量…'), findsNWidgets(2));
    expect(cacheGateway.usageRequests, 1);

    cacheGateway.completeNext(const PluginCacheUsage(pluginId: 'org.mgread.fixture', bytes: 1536));
    await tester.pump();
    await tester.pump();
    expect(cacheGateway.usageRequests, 2);
    expect(find.text('1.5 KB'), findsOneWidget);

    cacheGateway.completeNext(const PluginCacheUsage(pluginId: 'org.mgread.fixture.second', bytes: 2048));
    await tester.pump();
    await tester.pump();
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.textContaining('plugin-cache'), findsNothing);

    await tester.tap(find.byKey(const Key('plugin-cache-clear-all')));
    await tester.pumpAndSettle();
    expect(find.text('清理全部数据源缓存？'), findsOneWidget);
    expect(find.byKey(const Key('plugin-cache-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('plugin-cache-confirm')));
    await tester.pump();
    await tester.pump();
    expect(find.text('缓存已清理完成。'), findsOneWidget);

    cacheGateway.completeNext(const PluginCacheUsage(pluginId: 'org.mgread.fixture', bytes: 0));
    await tester.pump();
    cacheGateway.completeNext(const PluginCacheUsage(pluginId: 'org.mgread.fixture.second', bytes: 0));
    await tester.pump();

    await tester.pump(const Duration(seconds: 2));
    expect(cacheGateway.usageRequests, 4);
  });
}

final class _CacheGateway implements PluginCacheGateway {
  final List<Completer<PluginCacheUsage>> _pending = <Completer<PluginCacheUsage>>[];
  int usageRequests = 0;

  @override
  Future<PluginCacheClearResult> clearAll() => Future.value(
    const PluginCacheClearResult(
      items: <PluginCacheClearItem>[
        PluginCacheClearItem(pluginId: 'org.mgread.fixture', bytesBefore: 1536, bytesRemaining: 0, status: PluginCacheClearStatus.cleared),
        PluginCacheClearItem(
          pluginId: 'org.mgread.fixture.second',
          bytesBefore: 2048,
          bytesRemaining: 0,
          status: PluginCacheClearStatus.cleared,
        ),
      ],
    ),
  );

  @override
  Future<PluginCacheClearResult> clearPlugin(String pluginId) => throw UnimplementedError();

  @override
  Future<List<PluginCacheUsage>> listUsage() async {
    return const <PluginCacheUsage>[];
  }

  @override
  Future<PluginCacheUsage> usageForPlugin(String pluginId) {
    usageRequests++;
    final completer = Completer<PluginCacheUsage>();
    _pending.add(completer);
    return completer.future;
  }

  void completeNext(PluginCacheUsage usage) {
    _pending.removeAt(0).complete(usage);
  }
}
