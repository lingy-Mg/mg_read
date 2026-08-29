/// 统一缓存管理页组件测试。
///
/// 职责：
/// - 验证缓存分类、真实用量投影和封面/漫画正文图片清理交互。
///
/// 注意：
/// - 使用窄网关替身，不访问 Runtime、Content Library 或文件系统。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/cache/application/cover_cache_manager.dart';
import 'package:mg_read/features/cache/application/database_cache_manager.dart';
import 'package:mg_read/features/cache/presentation/cache_management_page.dart';
import 'package:mg_read/features/plugins/application/plugin_cache_manager.dart';
import 'package:mg_read/features/plugins/application/plugin_runtime_connection.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

void main() {
  testWidgets('separates source, cover, and manga-image caches', (tester) async {
    final coverGateway = _CoverCacheGateway();
    final mangaImageGateway = _MangaImageCacheGateway();
    final databaseGateway = _DatabaseCacheGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coverCacheGatewayProvider.overrideWithValue(coverGateway),
          mangaImageCacheGatewayProvider.overrideWithValue(mangaImageGateway),
          databaseCacheGatewayProvider.overrideWithValue(databaseGateway),
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
    await tester.scrollUntilVisible(find.text('数据库缓存'), 240, scrollable: find.byType(Scrollable));
    expect(find.text('数据库缓存'), findsOneWidget);
    expect(find.text('废弃目录快照'), findsOneWidget);
    expect(databaseGateway.inspectCalls, 1);
    await tester.scrollUntilVisible(find.text('封面缓存'), 240, scrollable: find.byType(Scrollable));
    expect(find.text('封面缓存'), findsOneWidget);
    expect(find.text('4.0 KB。封面可按需重新下载，清理不会删除书架数据。'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('漫画正文图片缓存'), 240, scrollable: find.byType(Scrollable));
    expect(find.text('漫画正文图片缓存'), findsOneWidget);
    expect(find.textContaining('总计 8.0 KB。图片可按需重新下载'), findsOneWidget);
    expect(find.text('各漫画缓存'), findsOneWidget);
    expect(find.text('漫画甲'), findsOneWidget);
    expect(find.text('漫画乙'), findsOneWidget);
    expect(find.text('旧版缓存（无法归属）'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('manga-image-cache-entry-manga-a')), matching: find.text('6.0 KB')), findsOneWidget);

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
    expect(find.textContaining('总计 0 B。图片可按需重新下载'), findsOneWidget);
    expect(find.byKey(const Key('manga-image-cache-unattributed')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('manga-image-cache-entry-manga-a')), matching: find.text('0 B')), findsOneWidget);

    await tester.scrollUntilVisible(find.byKey(const Key('database-cache-clear')), -240, scrollable: find.byType(Scrollable));
    await tester.tap(find.byKey(const Key('database-cache-clear')));
    await tester.pumpAndSettle();
    expect(find.text('清理数据库缓存？'), findsOneWidget);
    expect(find.textContaining('已移出书架但仍保留的离线正文'), findsOneWidget);
    await tester.tap(find.byKey(const Key('database-cache-confirm')));
    await tester.pumpAndSettle();
    expect(databaseGateway.clearCalls, 1);
    expect(find.textContaining('数据库缓存已清理'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('database-cache-compact')));
    await tester.tap(find.byKey(const Key('database-cache-compact')));
    await tester.pumpAndSettle();
    expect(find.text('压缩数据库？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('database-cache-compact-confirm')));
    await tester.pumpAndSettle();
    expect(databaseGateway.compactCalls, 1);
    expect(find.textContaining('数据库压缩完成'), findsOneWidget);
  });

  testWidgets('retries manga-image cache usage after an initial failure', (tester) async {
    final mangaImageGateway = _RetryingMangaImageCacheGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coverCacheGatewayProvider.overrideWithValue(_CoverCacheGateway()),
          mangaImageCacheGatewayProvider.overrideWithValue(mangaImageGateway),
          databaseCacheGatewayProvider.overrideWithValue(_DatabaseCacheGateway()),
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

    await tester.scrollUntilVisible(find.text('漫画正文图片缓存信息暂不可用。'), 240, scrollable: find.byType(Scrollable));
    expect(find.text('漫画正文图片缓存信息暂不可用。'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('manga-image-cache-retry')));
    await tester.tap(find.byKey(const Key('manga-image-cache-retry')));
    await tester.pumpAndSettle();

    expect(mangaImageGateway.usageCalls, 2);
    expect(find.textContaining('总计 2.0 KB。图片可按需重新下载'), findsOneWidget);
  });

  testWidgets('automatically scans database cache and retries a failed scan', (tester) async {
    final databaseGateway = _RetryingDatabaseCacheGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coverCacheGatewayProvider.overrideWithValue(_CoverCacheGateway()),
          mangaImageCacheGatewayProvider.overrideWithValue(_MangaImageCacheGateway()),
          databaseCacheGatewayProvider.overrideWithValue(databaseGateway),
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

    await tester.scrollUntilVisible(find.text('数据库缓存信息暂不可用。'), 240, scrollable: find.byType(Scrollable));
    expect(databaseGateway.inspectCalls, 1);
    await tester.tap(find.byKey(const Key('database-cache-retry')));
    await tester.pumpAndSettle();

    expect(databaseGateway.inspectCalls, 2);
    expect(find.text('废弃目录快照'), findsOneWidget);
    expect(find.text('1 条'), findsOneWidget);
  });

  testWidgets('renders the cache page before the database scan completes', (tester) async {
    final databaseGateway = _GatedDatabaseCacheGateway();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseCacheGatewayProvider.overrideWithValue(databaseGateway),
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
    await tester.pump();

    expect(find.text('缓存管理'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('正在扫描可清理的数据库缓存…'), 240, scrollable: find.byType(Scrollable));
    expect(databaseGateway.inspectCalls, 1);

    databaseGateway.complete();
    await tester.pumpAndSettle();
    expect(find.text('未发现可清理的目录、离线正文或无引用对象。'), findsOneWidget);
  });
}

final class _DatabaseCacheGateway implements DatabaseCacheGateway {
  int inspectCalls = 0;
  int clearCalls = 0;
  int compactCalls = 0;
  var _cleared = false;
  var _compacted = false;

  @override
  Future<DatabaseCacheUsage> inspect() async {
    inspectCalls++;
    return DatabaseCacheUsage(
      staleCatalogRecords: _cleared ? 0 : 2,
      detachedMetadataRecords: _cleared ? 0 : 3,
      orphanContentObjects: _cleared ? 0 : 1,
      reclaimableContentBytes: _cleared ? 0 : 4096,
      estimatedReclaimableBytes: _cleared ? 0 : 5120,
      compactableDatabaseBytes: _compacted ? 0 : 4096,
    );
  }

  @override
  Future<DatabaseCacheCleanupResult> clearAll() async {
    clearCalls++;
    _cleared = true;
    return const DatabaseCacheCleanupResult(deletedRecords: 5, deletedContentObjects: 1, releasedLogicalBytes: 5120);
  }

  @override
  Future<DatabaseCacheCompactionResult> compact() async {
    compactCalls++;
    _compacted = true;
    return const DatabaseCacheCompactionResult(releasedBytes: 4096);
  }
}

final class _RetryingDatabaseCacheGateway implements DatabaseCacheGateway {
  int inspectCalls = 0;

  @override
  Future<DatabaseCacheUsage> inspect() async {
    inspectCalls++;
    if (inspectCalls == 1) throw StateError('fixture scan failure');
    return const DatabaseCacheUsage(
      staleCatalogRecords: 1,
      detachedMetadataRecords: 0,
      orphanContentObjects: 0,
      reclaimableContentBytes: 0,
      estimatedReclaimableBytes: 128,
      compactableDatabaseBytes: 0,
    );
  }

  @override
  Future<DatabaseCacheCleanupResult> clearAll() async => const DatabaseCacheCleanupResult();

  @override
  Future<DatabaseCacheCompactionResult> compact() async => const DatabaseCacheCompactionResult();
}

final class _GatedDatabaseCacheGateway implements DatabaseCacheGateway {
  final Completer<DatabaseCacheUsage> _inspection = Completer<DatabaseCacheUsage>();
  int inspectCalls = 0;

  void complete() => _inspection.complete(const DatabaseCacheUsage.empty());

  @override
  Future<DatabaseCacheUsage> inspect() {
    inspectCalls++;
    return _inspection.future;
  }

  @override
  Future<DatabaseCacheCleanupResult> clearAll() async => const DatabaseCacheCleanupResult();

  @override
  Future<DatabaseCacheCompactionResult> compact() async => const DatabaseCacheCompactionResult();
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
  Future<MangaImageCacheUsage> loadUsage() async => const MangaImageCacheUsage(
    totalBytes: 8192,
    unattributedBytes: 1024,
    entries: <MangaImageCacheEntry>[
      MangaImageCacheEntry(itemId: 'manga-a', title: '漫画甲', bytes: 6144),
      MangaImageCacheEntry(itemId: 'manga-b', title: '漫画乙', bytes: 1024),
    ],
  );

  @override
  Future<int> clear() async {
    clearCalls++;
    return 8192;
  }
}

final class _RetryingMangaImageCacheGateway implements MangaImageCacheGateway {
  int usageCalls = 0;

  @override
  Future<MangaImageCacheUsage> loadUsage() async {
    usageCalls++;
    if (usageCalls == 1) throw StateError('fixture usage failure');
    return const MangaImageCacheUsage(
      totalBytes: 2048,
      entries: <MangaImageCacheEntry>[MangaImageCacheEntry(itemId: 'manga-retry', title: '重试漫画', bytes: 2048)],
    );
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
