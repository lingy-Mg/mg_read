/// 统一缓存管理页组件测试。
///
/// 职责：
/// - 验证缓存分类、真实用量投影和封面/漫画正文图片清理交互。
///
/// 注意：
/// - 使用窄网关替身，不访问 Runtime、Content Library 或文件系统。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/cache/application/cover_cache_manager.dart';
import 'package:mg_read/features/cache/presentation/cache_management_page.dart';
import 'package:mg_read/features/plugins/application/plugin_cache_manager.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

void main() {
  testWidgets('separates source, cover, and manga-image caches', (tester) async {
    final coverGateway = _CoverCacheGateway();
    final mangaImageGateway = _MangaImageCacheGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coverCacheGatewayProvider.overrideWithValue(coverGateway),
          mangaImageCacheGatewayProvider.overrideWithValue(mangaImageGateway),
          pluginCacheGatewayProvider.overrideWithValue(const _PluginCacheGateway()),
          pluginRuntimeConnectionProvider.overrideWith(
            (ref) async => const PluginRuntimeConnection(
              isHealthy: true,
              nodeVersion: '24.16.0',
              runtimeVersion: 'test',
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
          home: CacheManagementPage(onBackRequested: () {}, onDestinationRequested: (AppNavigationDestination _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('缓存管理'), findsOneWidget);
    expect(find.text('数据源网页与文件缓存'), findsOneWidget);
    expect(find.text('测试数据源'), findsOneWidget);
    expect(find.text('1.5 KB'), findsOneWidget);
    expect(find.text('封面缓存'), findsOneWidget);
    expect(find.textContaining('4.0 KB'), findsOneWidget);
    expect(find.text('漫画正文图片缓存'), findsOneWidget);
    expect(find.textContaining('8.0 KB。图片可按需重新下载'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('cover-cache-clear')));
    await tester.tap(find.byKey(const Key('cover-cache-clear')));
    await tester.pumpAndSettle();
    expect(find.text('清理封面缓存？'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cover-cache-confirm')));
    await tester.pumpAndSettle();

    expect(coverGateway.clearCalls, 1);
    expect(find.text('封面缓存已清理完成。'), findsOneWidget);
    expect(find.textContaining('0 B。封面可按需重新下载'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('manga-image-cache-clear')));
    await tester.tap(find.byKey(const Key('manga-image-cache-clear')));
    await tester.pumpAndSettle();
    expect(find.text('清理漫画正文图片缓存？'), findsOneWidget);
    expect(find.text('只会删除可重新下载的漫画正文图片，不影响书架、章节清单（manifest）、阅读进度和书签。'), findsOneWidget);

    await tester.tap(find.byKey(const Key('manga-image-cache-confirm')));
    await tester.pumpAndSettle();

    expect(mangaImageGateway.clearCalls, 1);
    expect(find.text('漫画正文图片缓存已清理完成。'), findsOneWidget);
    expect(find.textContaining('0 B。图片可按需重新下载'), findsOneWidget);
  });

  testWidgets('retries manga-image cache usage after an initial failure', (tester) async {
    final mangaImageGateway = _RetryingMangaImageCacheGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coverCacheGatewayProvider.overrideWithValue(_CoverCacheGateway()),
          mangaImageCacheGatewayProvider.overrideWithValue(mangaImageGateway),
          pluginCacheGatewayProvider.overrideWithValue(const _PluginCacheGateway()),
          pluginRuntimeConnectionProvider.overrideWith(
            (ref) async => const PluginRuntimeConnection(
              isHealthy: true,
              nodeVersion: '24.16.0',
              runtimeVersion: 'test',
              plugins: <PluginRuntimePlugin>[],
            ),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: CacheManagementPage(onBackRequested: () {}, onDestinationRequested: (AppNavigationDestination _) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('漫画正文图片缓存信息暂不可用。'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('manga-image-cache-retry')));
    await tester.tap(find.byKey(const Key('manga-image-cache-retry')));
    await tester.pumpAndSettle();

    expect(mangaImageGateway.usageCalls, 2);
    expect(find.textContaining('2.0 KB。图片可按需重新下载'), findsOneWidget);
  });
}

final class _CoverCacheGateway implements CoverCacheGateway {
  int clearCalls = 0;

  @override
  Future<int> usageBytes() async => 4096;

  @override
  Future<int> clear() async {
    clearCalls++;
    return 4096;
  }
}

final class _MangaImageCacheGateway implements MangaImageCacheGateway {
  int clearCalls = 0;

  @override
  Future<int> usageBytes() async => 8192;

  @override
  Future<int> clear() async {
    clearCalls++;
    return 8192;
  }
}

final class _RetryingMangaImageCacheGateway implements MangaImageCacheGateway {
  int usageCalls = 0;

  @override
  Future<int> usageBytes() async {
    usageCalls++;
    if (usageCalls == 1) throw StateError('fixture usage failure');
    return 2048;
  }

  @override
  Future<int> clear() async => 0;
}

final class _PluginCacheGateway implements PluginCacheGateway {
  const _PluginCacheGateway();

  @override
  Future<List<PluginCacheUsage>> listUsage() async => const <PluginCacheUsage>[
    PluginCacheUsage(pluginId: 'org.mgread.fixture', bytes: 1536),
  ];

  @override
  Future<PluginCacheUsage> usageForPlugin(String pluginId) async => PluginCacheUsage(pluginId: pluginId, bytes: 1536);

  @override
  Future<PluginCacheClearResult> clearAll() async => const PluginCacheClearResult(items: <PluginCacheClearItem>[]);

  @override
  Future<PluginCacheClearResult> clearPlugin(String pluginId) async => const PluginCacheClearResult(items: <PluginCacheClearItem>[]);
}
