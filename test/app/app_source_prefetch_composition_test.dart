/// 应用级书架预取组合回归测试。
///
/// 职责：
/// - 验证生产 bootstrap 注入的保存与阅读适配器共享同一预取任务。
/// - 只替换 typed Source gateway，不启动真实 Runtime、窗口或平台设备。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_settings_lifecycle.dart';
import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/diagnostics/diagnostics.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/discovery/application/discovery_bookshelf_saver.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/application/library_reader_launcher.dart';
import 'package:mg_read/features/reader/application/reader_launch_request.dart';

import '../core/settings/settings_testkit.dart';

void main() {
  test('save prefetch and immediate reader launch reuse one catalog and first-content task', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-app-prefetch-composition-');
    final library = await ContentLibrary.open(dataRoot: root);
    final diagnostics = DiagnosticsManager(
      sink: const NoopDiagnosticEventSink(),
      registry: AppDiagnosticEvents.registry,
      source: DiagnosticSource.app,
    );
    final settings = AppSettingsManager(store: FakeSettingsStore(), registry: AppSettingKeys.registry);
    final gateway = _GatedSourceContentGateway();
    late ProviderScope scope;

    await bootstrapMgReadApp(
      settingsManager: settings,
      diagnosticsManager: diagnostics,
      diagnosticsServiceFactory: null,
      contentLibrary: library,
      contentLibraryFactory: null,
      appPersistenceFactory: null,
      appRunner: (app) => scope = app as ProviderScope,
      child: const SizedBox.shrink(),
    );

    final host = scope.child as AppSettingsLifecycleHost;
    final container = ProviderContainer(overrides: [...scope.overrides, sourceContentGatewayProvider.overrideWithValue(gateway)]);
    addTearDown(() async {
      container.dispose();
      await host.manager.close();
      await host.closeContentLibrary?.call();
      host.disposeDiagnosticsBoundary?.call();
      host.disposeFatalErrorReporter?.call();
      await host.diagnostics?.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    final saver = container.read(discoveryBookshelfSaverProvider);
    await saver.save(source: _source, detail: _detail);
    await gateway.catalogRequested.future;
    final item = (await library.listLibrary(const LibraryQuery())).items.single;

    final launch = container.read(libraryReaderLauncherProvider).launch(item.id.value);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final catalogCallsWhileFirstRequestWasBlocked = gateway.catalogCalls;

    gateway.releaseCatalog();
    await gateway.contentRequested.future;
    gateway.releaseContent();
    final request = await launch;
    await Future<void>.delayed(Duration.zero);

    expect(request, isA<NovelReaderLaunchRequest>());
    expect(catalogCallsWhileFirstRequestWasBlocked, 1);
    expect(gateway.catalogCalls, 1);
    expect(gateway.contentCalls, 1);
  });
}

final PluginSourceDescriptor _source = PluginSourceDescriptor(
  id: 'org.example.shared-prefetch',
  displayName: '共享预取测试源',
  pluginVersion: '1.0.0',
  contentKinds: const <PluginContentKind>[PluginContentKind.novel],
);

final PluginContentDetail _detail = PluginContentDetail(
  pluginId: _source.id,
  sourceName: _source.displayName,
  aliases: const <String>[],
  catalogUrl: null,
  summary: PluginContentSummary(
    id: 'book-shared-prefetch',
    title: '共享预取测试书',
    contentKind: PluginContentKind.novel,
    author: null,
    url: null,
    coverUrl: null,
    description: null,
    language: 'zh-CN',
    status: PluginContentStatus.ongoing,
    access: PluginAccessKind.free,
    wordCount: 4,
    chapterCount: 1,
    publishedAt: null,
    updatedAt: null,
    latestChapter: null,
    categories: const <String>[],
    tags: const <String>[],
    attributes: const <PluginContentAttribute>[],
  ),
);

final class _GatedSourceContentGateway implements SourceContentGateway {
  final Completer<void> catalogRequested = Completer<void>();
  final Completer<void> contentRequested = Completer<void>();
  final Completer<void> _catalogRelease = Completer<void>();
  final Completer<void> _contentRelease = Completer<void>();
  int catalogCalls = 0;
  int contentCalls = 0;

  void releaseCatalog() {
    if (!_catalogRelease.isCompleted) _catalogRelease.complete();
  }

  void releaseContent() {
    if (!_contentRelease.isCompleted) _contentRelease.complete();
  }

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) async => _detail;

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) async {
    catalogCalls += 1;
    if (!catalogRequested.isCompleted) catalogRequested.complete();
    await _catalogRelease.future;
    return PluginChaptersResult(
      pluginId: pluginId,
      sourceName: _source.displayName,
      items: <PluginChapterSummary>[
        PluginChapterSummary(
          id: 'chapter-1',
          title: '第一章',
          order: 0,
          url: null,
          volumeTitle: null,
          wordCount: 4,
          updatedAt: null,
          isLocked: false,
          attributes: <PluginContentAttribute>[],
        ),
      ],
    );
  }

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) async {
    contentCalls += 1;
    if (!contentRequested.isCompleted) contentRequested.complete();
    await _contentRelease.future;
    return PluginChapterContent(
      pluginId: pluginId,
      sourceName: _source.displayName,
      contentKind: PluginContentKind.novel,
      chapterId: chapterId,
      title: '第一章',
      updatedAt: null,
      text: '测试正文',
      pages: const <PluginMangaPage>[],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
