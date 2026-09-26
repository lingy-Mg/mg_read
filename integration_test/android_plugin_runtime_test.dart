/// Android Runtime 集成验收。
///
/// 职责：
/// - 验证构建所选 Android 后端的插件安装、数据面、传输、取消和 Debug listener；
/// - 通过 IntegrationTest 与公开 Runtime Facade 执行离线、可重复的调用。
///
/// 注意：
/// - 只能由已授权的 Android 模拟器执行；
/// - 网络数据源的真实页面验收由人工在 Debug listener 页面完成。
///
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/content_library_source_text_reader.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const useNodeProcess = bool.fromEnvironment('MGREAD_TEST_ANDROID_NODE_PROCESS');

  setUpAll(() async {
    await const MethodChannel(
      'mgread_plugin_runtime/android_backend',
    ).invokeMethod<void>('select', {'backend': useNodeProcess ? 'nodeProcess' : 'javet'});
    await AndroidNodeRuntimeSettings.instance.initialize();
  });

  testWidgets('Android Runtime accepts the normal app proxy warmup call', (WidgetTester tester) async {
    await tester.pump();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);

    await runtime.configurePluginHttpProxy(null);
    await runtime.configurePluginHttpProxy(Uri.parse('http://127.0.0.1:12345'));
    await runtime.configurePluginHttpProxy(null);
    final ping = await runtime.invoke(const RuntimePingInvocation());
    expect(ping.isHealthy, isTrue);
    expect(ping.nodeVersion, useNodeProcess ? '24.21.0' : '26.9.0');
    final status = await runtime.invoke(const RuntimeStatusInvocation());
    expect(status.runtimeKind, useNodeProcess ? 'android-node-process' : 'android-javet');
  });

  testWidgets('Android Runtime keeps the Debug listener alive until disabled', (WidgetTester tester) async {
    await tester.pump();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);

    final enabled = await runtime.setDebugHttpEnabled(true);
    expect(enabled.enabled, isTrue);
    expect(enabled.startedAt, isNotNull);
    expect(enabled.endpoints, isNotEmpty);

    final client = HttpClient();
    addTearDown(client.close);
    final pageRequest = await client.getUrl(Uri.parse(enabled.endpoints.first));
    final pageResponse = await pageRequest.close();
    expect(pageResponse.statusCode, HttpStatus.ok);
    expect(await utf8.decodeStream(pageResponse), contains('MgRead 调试信息面板'));

    final disabled = await runtime.setDebugHttpEnabled(false);
    expect(disabled.enabled, isFalse);
    expect(disabled.endpoints, isEmpty);
  });

  testWidgets('Android Runtime installs plugins and serves offline source data', (WidgetTester tester) async {
    await tester.pump();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    final facadeDiagnostics = <RuntimeDiagnostic>[];
    final diagnosticSubscription = runtime.diagnostics.listen(facadeDiagnostics.add);
    addTearDown(diagnosticSubscription.cancel);
    final ping = await runtime.invoke(const RuntimePingInvocation());
    expect(ping.isHealthy, isTrue);
    expect(ping.nodeVersion, isNotEmpty);

    final plugins = await runtime.invoke(const InstalledPluginsInvocation());
    final aisishuwu = plugins.singleWhere((plugin) => plugin.id == 'org.mgread.aisishuwu');
    expect(aisishuwu.status, 'active');
    expect(aisishuwu.activeVersion, '0.2.12');
    const fixtureId = 'org.mgread.android-runtime-fixture';
    final fixture = plugins.singleWhere((plugin) => plugin.id == fixtureId);
    expect(fixture.status, 'active');
    expect(fixture.activeVersion, '1.0.0');

    final search = await runtime.invoke(const SourceSearchInvocation(pluginId: fixtureId, query: 'offline', pageSize: 5));
    expect(search.items.single.title, 'fixture:offline');
    final fixtureDetail = await runtime.invoke(const SourceDetailInvocation(pluginId: fixtureId, id: 'fixture:one'));
    expect(fixtureDetail.summary.title, 'fixture:detail');
    final fixtureChapters = await runtime.invoke(const SourceChaptersInvocation(pluginId: fixtureId, id: 'fixture:one'));
    expect(fixtureChapters.items.single.id, 'chapter:one');

    final libraryRoot = await Directory.systemTemp.createTemp('mg-read-android-source-reader-');
    final library = await ContentLibrary.open(dataRoot: libraryRoot);
    addTearDown(() async {
      await library.close();
      await libraryRoot.delete(recursive: true);
    });
    final shelfItem = await library.addLibraryItem(
      BookshelfAddRequest(
        title: fixtureDetail.summary.title,
        author: fixtureDetail.summary.author,
        kind: ContentKind.novel,
        pluginId: fixture.id,
        pluginVersion: fixture.activeVersion!,
        remoteContentId: fixtureDetail.summary.id,
      ),
    );
    final gateway = _AndroidRuntimeSourceGateway(runtime);
    final prefetcher = ContentLibrarySourcePrefetcher(library, gateway);
    final reader = ContentLibrarySourceTextReader(library, gateway, prefetcher);
    prefetcher.start(shelfItem);
    final launch = await reader.launch(shelfItem.id.value);
    expect(await library.listAllCatalog(shelfItem.id), hasLength(1));
    final lastChapter = await launch.dataSource.loadChapterAtIndex(launch.bookId, 0);
    final lastContent = await launch.dataSource.loadChapterContent(launch.bookId, lastChapter.id);
    expect(lastContent.paragraphs, isNotEmpty);

    final discovery = await runtime.invoke(const SourceDiscoverInvocation(pluginId: fixtureId, pageSize: 20));
    expect(discovery, isA<PluginDiscoveryDocumentResult>());
    final artifacts = await runtime.invoke(const PluginTransferListInvocation());
    final fixtureArtifact = artifacts.singleWhere((artifact) => artifact.pluginId == fixtureId);
    final exported = await runtime.exportPluginArtifact(fixtureArtifact);
    final exportedBytes = await exported.expand((chunk) => chunk).toList();
    expect(exportedBytes.length, fixtureArtifact.bytes);
    await runtime.invoke(const UninstallPluginInvocation(pluginId: fixtureId));
    final imported = await runtime.importPluginArtifacts([(artifact: fixtureArtifact, bytes: Stream<List<int>>.value(exportedBytes))]);
    expect(imported.single.status, PluginTransferImportStatus.installed);
    final reinstalled = await runtime.invoke(const InstalledPluginsInvocation());
    expect(reinstalled.singleWhere((plugin) => plugin.id == fixtureId).status, 'active');
    if (!useNodeProcess) {
      expect(facadeDiagnostics.where((diagnostic) => diagnostic.code == 'runtime_facade_invoke_started').length, greaterThanOrEqualTo(2));
      expect(facadeDiagnostics.where((diagnostic) => diagnostic.code == 'runtime_facade_invoke_completed').length, greaterThanOrEqualTo(2));
    }
  });

  testWidgets('Android Runtime cancels a slow Source call and remains healthy', (WidgetTester tester) async {
    await tester.pump();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    final cancellation = PluginInvocationCancellation();
    unawaited(Future<void>.delayed(const Duration(milliseconds: 100), cancellation.cancel));
    final timer = Stopwatch()..start();
    await expectLater(
      runtime.invoke(
        const SourceSearchInvocation(pluginId: 'org.mgread.android-runtime-fixture', query: 'slow'),
        cancellation: cancellation,
      ),
      throwsA(isA<PluginRuntimeException>().having((error) => error.code, 'code', 'cancelled')),
    );
    expect(timer.elapsed, lessThan(const Duration(seconds: 2)));
    expect((await runtime.invoke(const RuntimePingInvocation())).isHealthy, isTrue);
  });
}

final class _AndroidRuntimeSourceGateway implements SourceContentGateway {
  const _AndroidRuntimeSourceGateway(this._runtime);

  final PluginRuntime _runtime;

  @override
  Future<PluginContentDetail> getDetail({required String pluginId, required String id}) =>
      _runtime.invoke(SourceDetailInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChaptersResult> getChapters({required String pluginId, required String id}) =>
      _runtime.invoke(SourceChaptersInvocation(pluginId: pluginId, id: id));

  @override
  Future<PluginChapterContent> getContent({required String pluginId, required String id, required String chapterId}) =>
      _runtime.invoke(SourceContentInvocation(pluginId: pluginId, id: id, chapterId: chapterId));

  @override
  Future<List<PluginSourceDescriptor>> listSources() => throw UnsupportedError('Not used by the Android reader flow.');

  @override
  Future<PluginDiscoverResult> discover({
    required String pluginId,
    String? target,
    String? cursor,
    String? collectionId,
    int pageSize = 20,
  }) => throw UnsupportedError('Not used by the Android reader flow.');

  @override
  Future<PluginSearchResult> search({required String pluginId, required String query, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used by the Android reader flow.');

  @override
  Future<PluginSearchSuggestionsResult> searchSuggestions({required String pluginId, String? cursor, int pageSize = 20}) =>
      throw UnsupportedError('Not used by the Android reader flow.');
}
