/// Exercises the production Android Rust supervisor and source UI end to end.
///
/// The test imports only its own native plugin package and never reads or
/// clears unrelated app data. Its report contains counts and timing only.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app_router.dart';
import 'package:mg_read/app/bootstrap.dart';
import 'package:mg_read/core/settings/settings.dart';
import 'package:mg_read/features/network_proxy/application/network_proxy_settings.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const pluginId = 'org.mgread.aisishuwu.native';
  const nativeImportPath = String.fromEnvironment(
    'MGREAD_TEST_NATIVE_IMPORT_PATH',
    defaultValue: '/data/user/0/com.mgread.mg_read/files/mgread-native/inbox/aisishuwu-native-0.1.0.mgplugin',
  );

  testWidgets('native Rust Runtime imports and serves the Android source UI', (tester) async {
    final evidence = <String, Object?>{};
    binding.reportData = evidence;
    // integration_test leaves the real IME attached. Its unregistered test
    // input uses client -1, which Flutter accepts only with debug assertions.
    // Register the test keyboard so Profile has the actual focused client ID.
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    await _configureProxy(runtime);

    await runtime.importLocalPluginForTesting(nativeImportPath);
    var status = await runtime.invoke(const RuntimeStatusInvocation());
    expect(status.isHealthy, isTrue);
    expect(status.runtimeKind, 'native-rust');
    evidence['runtimeKind'] = status.runtimeKind;
    evidence['arch'] = status.arch;

    var installed = await runtime.invoke(const InstalledPluginsInvocation());
    var source = installed.singleWhere((plugin) => plugin.id == pluginId);
    expect(source.status, 'active');
    evidence['pluginActive'] = true;

    final disabled = await runtime.invoke(const SetPluginEnabledInvocation(pluginId: pluginId, enabled: false));
    expect(disabled.status, isNot('active'));
    source = await runtime.invoke(const SetPluginEnabledInvocation(pluginId: pluginId, enabled: true));
    expect(source.status, 'active');
    evidence['enableToggle'] = 'passed';

    final discovery = await runtime.invoke(const SourceDiscoverInvocation(pluginId: pluginId, pageSize: 8));
    expect(discovery, isA<PluginDiscoveryDocumentResult>());
    final components = (discovery as PluginDiscoveryDocumentResult).document.components;
    evidence['homeComponentCount'] = components.length;
    final categories = components.whereType<PluginDiscoveryCategoryCollectionComponent>().first;
    expect(categories.categories, isNotEmpty);
    final category = await runtime.invoke(
      SourceDiscoverInvocation(pluginId: pluginId, target: categories.categories.first.target, pageSize: 3),
    );
    expect(category, isA<PluginDiscoveryDocumentResult>());
    evidence['categoryComponentCount'] = (category as PluginDiscoveryDocumentResult).document.components.length;

    final search = await runtime.invoke(const SourceSearchInvocation(pluginId: pluginId, query: '修仙', pageSize: 5));
    expect(search.items, isNotEmpty);
    evidence['searchResultCount'] = search.items.length;

    const completeCatalogId = 'novel:52801';
    final completeCatalogDetail = await runtime.invoke(const SourceDetailInvocation(pluginId: pluginId, id: completeCatalogId));
    final completeCatalog = await runtime.invoke(const SourceChaptersInvocation(pluginId: pluginId, id: completeCatalogId));
    expect(completeCatalog.items, isNotEmpty);
    expect(completeCatalog.items.map((chapter) => chapter.id).toSet().length, completeCatalog.items.length);
    if (completeCatalogDetail.summary.chapterCount != null) {
      expect(completeCatalog.items.length, completeCatalogDetail.summary.chapterCount);
    }
    evidence['completeCatalogChapterCount'] = completeCatalog.items.length;

    const longSampleId = 'novel:3211';
    final detail = await runtime.invoke(const SourceDetailInvocation(pluginId: pluginId, id: longSampleId));
    expect(detail.summary.title, isNotEmpty);
    final chapters = await runtime.invoke(const SourceChaptersInvocation(pluginId: pluginId, id: longSampleId));
    expect(chapters.items, isNotEmpty);
    if (detail.summary.chapterCount != null) {
      expect(chapters.items.length, detail.summary.chapterCount);
    }
    evidence['longSampleChapterCount'] = chapters.items.length;
    expect(chapters.items.map((chapter) => chapter.id).toSet().length, chapters.items.length);
    final sampleIndexes = <int>{0, chapters.items.length ~/ 2, chapters.items.length - 1}.toList()..sort();
    final sampleUtf8Bytes = <int>[];
    final sampleSha256 = <String>[];
    for (final index in sampleIndexes) {
      final chapter = await runtime.invoke(
        SourceContentInvocation(pluginId: pluginId, id: longSampleId, chapterId: chapters.items[index].id),
      );
      expect(chapter.text, isNotEmpty);
      final bytes = utf8.encode(chapter.text!);
      sampleUtf8Bytes.add(bytes.length);
      sampleSha256.add(sha256.convert(bytes).toString());
    }
    expect(sampleUtf8Bytes.first, greaterThan(48 * 1024));
    evidence['longSampleFirstMiddleLastUtf8Bytes'] = sampleUtf8Bytes;
    evidence['longSampleFirstMiddleLastSha256'] = sampleSha256;

    final longSampleCoverUrl = detail.summary.coverUrl;
    expect(longSampleCoverUrl, isNotNull);
    final longSampleCoverResource = await runtime.invoke(SourceResourceDecodeInvocation(url: longSampleCoverUrl!.toString()));
    expect(longSampleCoverResource.pluginId, pluginId);
    final coverClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..findProxy = (_) => 'DIRECT';
    addTearDown(coverClient.close);
    final longSampleCoverResponse = await (await coverClient.getUrl(longSampleCoverUrl)).close();
    evidence['longSampleCoverStatus'] = longSampleCoverResponse.statusCode;
    await longSampleCoverResponse.drain<void>();

    final coverUrl = completeCatalogDetail.summary.coverUrl;
    expect(coverUrl, isNotNull);
    final coverResource = await runtime.invoke(SourceResourceDecodeInvocation(url: coverUrl!.toString()));
    expect(coverResource.pluginId, pluginId);
    final coverResponse = await (await coverClient.getUrl(coverUrl)).close();
    expect(coverResponse.statusCode, HttpStatus.ok);
    expect(coverResponse.headers.contentType?.mimeType, startsWith('image/'));
    final coverBuilder = BytesBuilder(copy: false);
    var coverByteCount = 0;
    await for (final chunk in coverResponse) {
      coverByteCount += chunk.length;
      if (coverByteCount > 16 * 1024 * 1024) {
        throw StateError('The native cover response exceeded the integration-test size limit.');
      }
      coverBuilder.add(chunk);
    }
    final coverBytes = coverBuilder.takeBytes();
    expect(coverBytes, isNotEmpty);
    evidence['coverMime'] = coverResponse.headers.contentType?.mimeType;
    evidence['coverByteCount'] = coverBytes.length;
    evidence['coverSha256'] = sha256.convert(coverBytes).toString();

    final nativeWorkerModules = await _nativeWorkerModuleBasenames();
    expect(nativeWorkerModules, contains('libmgread_native_runtime.so'));
    expect(nativeWorkerModules, contains('libaisishuwu_native.so'));
    expect(nativeWorkerModules.where((name) => RegExp(r'(node|javet|v8)', caseSensitive: false).hasMatch(name)), isEmpty);
    evidence['nativeWorkerModuleBasenames'] = nativeWorkerModules;

    final cacheUsage = await runtime.invoke(const PluginCacheUsageInvocation(pluginId: pluginId));
    evidence['cacheUsageEntryCount'] = cacheUsage.length;
    evidence['cacheBytes'] = cacheUsage.fold<int>(0, (sum, entry) => sum + entry.bytes);

    await runtime.debugDispose();
    final restartedRuntime = PluginRuntime();
    addTearDown(restartedRuntime.debugDispose);
    await _configureProxy(restartedRuntime);
    status = await restartedRuntime.invoke(const RuntimeStatusInvocation());
    expect(status.runtimeKind, 'native-rust');
    installed = await restartedRuntime.invoke(const InstalledPluginsInvocation());
    source = installed.singleWhere((plugin) => plugin.id == pluginId);
    expect(source.status, 'active');
    final restartedContent = await restartedRuntime.invoke(
      SourceContentInvocation(pluginId: pluginId, id: longSampleId, chapterId: chapters.items.first.id),
    );
    expect(restartedContent.text, isNotEmpty);
    expect(sha256.convert(utf8.encode(restartedContent.text!)).toString(), sampleSha256.first);
    evidence['serviceRestart'] = 'passed';

    final appDataRoot = await Directory.systemTemp.createTemp('mg-read-android-native-app-');
    final appSettings = AppSettingsManager(store: _NativeTestSettingsStore(), registry: AppSettingKeys.registry);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 2)));
      await appSettings.close();
      if (await appDataRoot.exists()) {
        await appDataRoot.delete(recursive: true);
      }
    });
    await appSettings.initialize();
    const testProxy = String.fromEnvironment('MGREAD_TEST_HTTP_PROXY');
    if (testProxy.isNotEmpty) {
      final proxy = Uri.parse(testProxy);
      await appSettings.set(
        AppSettingKeys.networkProxyPreferences,
        NetworkProxySettings(
          protocol: NetworkProxyProtocol.values.byName(proxy.scheme),
          host: proxy.host,
          port: proxy.port,
          enabled: <NetworkProxyTraffic, bool>{
            for (final traffic in NetworkProxyTraffic.values)
              traffic: traffic == NetworkProxyTraffic.sourceHttp || traffic == NetworkProxyTraffic.cover,
          },
        ).toSettingValue(),
      );
    }
    await bootstrapMgReadApp(
      settingsManager: appSettings,
      dataRootResolver: () async => appDataRoot,
      appRunner: (app) async => tester.pumpWidget(app),
    );
    final searchNavigation = find.byKey(const Key('app-nav-search'));
    await _pumpUntil(tester, searchNavigation.hitTestable(), timeout: const Duration(minutes: 2));
    await tester.tap(searchNavigation);
    await tester.pumpAndSettle(const Duration(milliseconds: 150));
    final sourceSelector = find.byKey(const Key('search-source-selector'));
    await _pumpUntil(tester, sourceSelector.hitTestable(), timeout: const Duration(minutes: 2));
    await tester.tap(sourceSelector);
    await tester.pumpAndSettle(const Duration(milliseconds: 150));
    await tester.enterText(find.byKey(const Key('discovery-source-picker-search')), '爱丽丝书屋 Native');
    await tester.pumpAndSettle(const Duration(milliseconds: 150));
    final sourceRow = find.byKey(const ValueKey<String>('discovery-source-picker-org.mgread.aisishuwu.native'));
    await _pumpUntil(tester, sourceRow.hitTestable());
    await tester.tap(sourceRow);
    await tester.pumpAndSettle(const Duration(milliseconds: 150));

    final readerChapter = await restartedRuntime.invoke(
      SourceContentInvocation(pluginId: pluginId, id: completeCatalogId, chapterId: completeCatalog.items.first.id),
    );
    expect(readerChapter.text, isNotEmpty);
    final readerChapterBytes = utf8.encode(readerChapter.text!);
    final normalizedExpectedReaderText = readerChapter.text!.replaceAll(RegExp(r'[\s\u3000]+'), '');
    final expectedReaderPrefix = normalizedExpectedReaderText.substring(
      0,
      normalizedExpectedReaderText.length < 30 ? normalizedExpectedReaderText.length : 30,
    );
    final uiSearch = await restartedRuntime.invoke(
      SourceSearchInvocation(pluginId: pluginId, query: completeCatalogDetail.summary.title, pageSize: 10),
    );
    final catalogSearchHit = uiSearch.items.where((item) => item.id == completeCatalogId).firstOrNull;
    expect(catalogSearchHit, isNotNull);
    final searchQuery = find.byKey(const Key('source-search-query'));
    await _pumpUntil(tester, searchQuery.hitTestable());
    await tester.enterText(searchQuery, completeCatalogDetail.summary.title);
    // Profile mode can reach the tap before the button rebuilds from disabled
    // to enabled. Wait for the entered query to reach the rendered form.
    await tester.pumpAndSettle(const Duration(milliseconds: 150));
    expect(
      tester.widget<EditableText>(find.descendant(of: searchQuery, matching: find.byType(EditableText))).controller.text ==
          completeCatalogDetail.summary.title,
      isTrue,
      reason: 'The test keyboard did not deliver the search query.',
    );
    final searchSubmit = find.byKey(const Key('source-search-submit'));
    await _pumpUntil(tester, searchSubmit.hitTestable());
    await tester.tap(searchSubmit);
    final resultTile = find.byKey(const ValueKey<String>('search-result-$completeCatalogId'));
    await _pumpUntil(tester, resultTile.hitTestable(), timeout: const Duration(minutes: 2));
    await tester.tap(resultTile);
    await tester.pumpAndSettle(const Duration(milliseconds: 150));
    final startReading = find.byKey(const Key('source-detail-start-reading'));
    await _pumpUntil(tester, startReading.hitTestable(), timeout: const Duration(minutes: 2));
    await tester.tap(startReading);
    await tester.pumpAndSettle(const Duration(milliseconds: 150));
    final readerSurface = find.byKey(const ValueKey<String>('reader-content-surface'));
    await _pumpUntil(tester, readerSurface, timeout: const Duration(minutes: 2));
    final readerText = find.descendant(of: readerSurface, matching: find.byType(RichText));
    await _pumpUntil(tester, readerText, timeout: const Duration(minutes: 2));
    final visibleReaderText = tester.widgetList<RichText>(readerText).map((widget) => widget.text.toPlainText()).join('\n');
    final normalizedVisibleReaderText = visibleReaderText.replaceAll(RegExp(r'[\s\u3000]+'), '');
    final readerPrefixMatched = normalizedVisibleReaderText.contains(expectedReaderPrefix);
    expect(readerPrefixMatched, isTrue, reason: 'The real Reader did not render its selected source chapter.');
    evidence['readerChapterUtf8Bytes'] = readerChapterBytes.length;
    evidence['readerChapterSha256'] = sha256.convert(readerChapterBytes).toString();
    evidence['readerSourcePrefixMatched'] = readerPrefixMatched;

    const PluginCenterRoute().go(tester.element(readerSurface));
    await tester.pumpAndSettle(const Duration(milliseconds: 150));
    final runtimeStatusButton = find.byKey(const Key('data-source-runtime-status'));
    await _pumpUntil(tester, runtimeStatusButton.hitTestable(), timeout: const Duration(minutes: 2));
    await tester.tap(runtimeStatusButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 150));
    final runtimeSummary = find.byKey(const Key('runtime-health-summary-card'));
    await _pumpUntil(tester, runtimeSummary, timeout: const Duration(minutes: 2));
    expect(find.text('Rust 原生数据源引擎'), findsOneWidget);
    expect(find.byKey(const Key('runtime-health-state')), findsOneWidget);
    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('android_native_runtime_status');
    evidence['normalAppSearchDetailRead'] = 'passed';
    evidence['normalAppSearchResultCount'] = uiSearch.items.length;
    evidence['readerSurfaceVisible'] = true;
    evidence['nativeRuntimeStatusVisible'] = true;
  }, timeout: const Timeout(Duration(minutes: 12)));
}

final class _NativeTestSettingsStore implements SettingsStore {
  final Map<String, SettingsDocument> _documents = <String, SettingsDocument>{};

  @override
  Future<List<SettingsDocument>> loadAll(Iterable<SettingsDocumentDefinition> documents) async => <SettingsDocument>[
    for (final definition in documents) ?_documents[definition.kind],
  ];

  @override
  Future<List<SettingsDocument>> writeAll(List<SettingsDocument> documents) async {
    final written = <SettingsDocument>[];
    for (final document in documents) {
      final next = SettingsDocument(id: document.id, kind: document.kind, values: document.values, revision: (document.revision ?? 0) + 1);
      _documents[document.kind] = next;
      written.add(next);
    }
    return written;
  }

  @override
  Future<void> close() async {}
}

Future<void> _configureProxy(PluginRuntime runtime) async {
  const proxy = String.fromEnvironment('MGREAD_TEST_HTTP_PROXY');
  if (proxy.isNotEmpty) {
    await runtime.configurePluginHttpProxy(Uri.parse(proxy));
  }
}

Future<List<String>> _nativeWorkerModuleBasenames() async {
  const workerProcess = 'com.mgread.mg_read:mgread_native';
  final pidResult = await Process.run('/system/bin/pidof', <String>[workerProcess]);
  final pids = (pidResult.stdout as String).trim().split(RegExp(r'\s+')).where((pid) => pid.isNotEmpty).toList();
  expect(pidResult.exitCode, 0);
  expect(pids, isNotEmpty);
  final mapLines = await File('/proc/${pids.first}/maps').readAsLines();
  final basenames = <String>{};
  for (final line in mapLines) {
    final fields = line.trim().split(RegExp(r'\s+'));
    if (fields.isEmpty) continue;
    var path = fields.last;
    if (path == '(deleted)' && fields.length > 1) path = fields[fields.length - 2];
    if (path.startsWith('/') && path.endsWith('.so')) {
      basenames.add(path.split('/').last);
    }
  }
  return basenames.toList()..sort();
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final timer = Stopwatch()..start();
  while (finder.evaluate().isEmpty) {
    if (timer.elapsed > timeout) {
      fail('Timed out waiting for an Android native integration UI state.');
    }
    await tester.pump(const Duration(milliseconds: 200));
  }
}
