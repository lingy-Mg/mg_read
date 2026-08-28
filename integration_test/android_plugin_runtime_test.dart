/// Android Runtime 集成验收。
///
/// 职责：
/// - 验证 Javet 单 VM 内的插件 Runtime、资源数据面和 Debug listener；
/// - 仅通过 IntegrationTest 的 Finder、语义和 Runtime Facade 与应用交互。
///
/// 注意：
/// - 只能由已授权的 Android 模拟器执行；
/// - 网络书源的真实页面验收由人工在 Debug listener 页面完成。
///
/// TODO:
/// - 无。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/app/app.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/application/content_library_source_prefetcher.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/reader/data/content_library_source_text_reader.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
    expect(await utf8.decodeStream(pageResponse), contains('MgRead Runtime Debug'));

    final disabled = await runtime.setDebugHttpEnabled(false);
    expect(disabled.enabled, isFalse);
    expect(disabled.endpoints, isEmpty);
  });

  testWidgets('Android Runtime installs ADB-delivered plugin archives', (WidgetTester tester) async {
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
    expect(aisishuwu.activeVersion, '0.2.11');
    final demo = plugins.singleWhere((plugin) => plugin.id == 'org.mgread.discovery-demo');
    expect(demo.status, 'active');
    expect(demo.activeVersion, '0.1.2');

    final fixtureDetail = await runtime.invoke(const SourceDetailInvocation(pluginId: 'org.mgread.aisishuwu', id: 'novel:52801'));
    expect(fixtureDetail.summary.chapterCount, 733);
    final fixtureChapters = await runtime.invoke(const SourceChaptersInvocation(pluginId: 'org.mgread.aisishuwu', id: 'novel:52801'));
    expect(fixtureChapters.items, hasLength(733));
    expect(fixtureChapters.items.map((chapter) => chapter.id).toSet(), hasLength(733));
    expect(fixtureChapters.items.map((chapter) => chapter.order), orderedEquals(List<int>.generate(733, (index) => index)));

    final libraryRoot = await Directory.systemTemp.createTemp('mg-read-android-source-reader-');
    final library = await ContentLibrary.open(dataRoot: libraryRoot);
    addTearDown(() async {
      await library.close();
      await libraryRoot.delete(recursive: true);
    });
    final shelfItem = await library.bookshelf.addFromSource(
      BookshelfAddRequest(
        title: fixtureDetail.summary.title,
        author: fixtureDetail.summary.author,
        kind: ContentKind.novel,
        pluginId: aisishuwu.id,
        pluginVersion: aisishuwu.activeVersion!,
        remoteContentId: fixtureDetail.summary.id,
      ),
    );
    final gateway = _AndroidRuntimeSourceGateway(runtime);
    final prefetcher = ContentLibrarySourcePrefetcher(library, gateway);
    final reader = ContentLibrarySourceTextReader(library, gateway, prefetcher);
    prefetcher.start(shelfItem);
    final launch = await reader.launch(shelfItem.id.value);
    expect(await library.listAllCatalog(shelfItem.id), hasLength(733));
    final lastChapter = await launch.dataSource.loadChapterAtIndex(launch.bookId, 732);
    final lastContent = await launch.dataSource.loadChapterContent(launch.bookId, lastChapter.id);
    expect(lastContent.paragraphs, isNotEmpty);

    final discovery = await runtime.invoke(const SourceDiscoverInvocation(pluginId: 'org.mgread.aisishuwu', pageSize: 20));
    expect(discovery, isA<PluginDiscoveryDocumentResult>());
    final document = discovery as PluginDiscoveryDocumentResult;
    expect(document.document.components, isNotEmpty);
    expect(document.document.components.whereType<PluginDiscoverySectionComponent>(), isNotEmpty);
    final demoDiscovery = await runtime.invoke(const SourceDiscoverInvocation(pluginId: 'org.mgread.discovery-demo', pageSize: 20));
    expect(demoDiscovery, isA<PluginDiscoveryDocumentResult>());
    final demoDocument = (demoDiscovery as PluginDiscoveryDocumentResult).document;
    expect(demoDocument.components.whereType<PluginDiscoveryTabsComponent>(), hasLength(1));
    expect(_containsDemoGroupLayout(demoDocument.components, PluginDiscoveryGroupLayout.horizontal), isTrue);
    expect(facadeDiagnostics.where((diagnostic) => diagnostic.code == 'runtime_facade_invoke_started').length, greaterThanOrEqualTo(2));
    expect(facadeDiagnostics.where((diagnostic) => diagnostic.code == 'runtime_facade_invoke_completed').length, greaterThanOrEqualTo(2));
  });

  testWidgets('data-source management renders the installed Android test source in light mode', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: MgReadApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('app-nav-profile')));
    await tester.pumpAndSettle();

    final Finder profileContent = find.byKey(const Key('profile-page-content'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('profile-setting-source-management')),
      220,
      scrollable: find.descendant(of: profileContent, matching: find.byType(Scrollable)),
    );
    await tester.tap(find.byKey(const Key('profile-setting-source-management')));
    await tester.pumpAndSettle();

    await _pumpUntilFound(tester, find.byKey(const Key('data-source-management-content')));
    expect(find.byKey(const Key('data-source-management-card')), findsOneWidget);
    final Finder sourceRows = find.byWidgetPredicate((Widget widget) {
      final Key? key = widget.key;
      if (key is! ValueKey<String>) return false;
      final value = key.value;
      return value.startsWith('data-source-') &&
          !value.startsWith('data-source-toggle-') &&
          !value.startsWith('data-source-management-') &&
          value != 'data-source-add' &&
          value != 'data-source-enabled-count';
    }, description: 'an installed data-source row');
    expect(sourceRows, findsWidgets);
    expect(find.byKey(const Key('data-source-add')), findsOneWidget);

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('data_source_management_light');
  });

  testWidgets('discovery detail renders a sourced book in light mode', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: MgReadApp()));
    await tester.pumpAndSettle(const Duration(seconds: 45));

    await tester.tap(find.byKey(const Key('app-nav-discover')));
    await _pumpUntilFound(tester, find.byKey(const Key('runtime-discovery-content')));

    await tester.tap(find.byKey(const Key('discovery-source-selector')));
    final Finder demoSource = find.byKey(const Key('discovery-source-picker-org.mgread.discovery-demo'));
    await _pumpUntilFound(tester, demoSource);
    await tester.tap(demoSource);

    final Finder demoCategory = find.byKey(const Key('discovery-category-category:fantasy'));
    final Finder firstContent = find.byWidgetPredicate((Widget widget) {
      final Key? key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('runtime-discovery-item-');
    }, description: 'a sourced discovery item');
    await _pumpUntilFound(tester, demoCategory);
    await tester.ensureVisible(demoCategory);
    await tester.tap(demoCategory);
    await _pumpUntilFound(tester, firstContent);

    await tester.tap(firstContent.first);
    await _pumpUntilFound(tester, find.byKey(const Key('source-content-detail-sheet')));

    expect(find.byKey(const Key('source-content-detail-sheet')), findsOneWidget);
    expect(find.byKey(const Key('source-detail-cover')), findsOneWidget);
    expect(find.text('组件演示书籍'), findsWidgets);
    expect(find.text('固定离线模拟数据，用于验证发现组件树。'), findsOneWidget);
    expect(find.byKey(const Key('source-detail-latest-chapter-url')), findsNothing);
    expect(find.byKey(const Key('source-detail-catalog-url')), findsOneWidget);

    await binding.convertFlutterSurfaceToImage();
    await tester.pump();
    await binding.takeScreenshot('discovery_detail_light');
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

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 90)}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(finder, findsWidgets);
}

bool _containsDemoGroupLayout(Iterable<PluginDiscoveryComponent> components, PluginDiscoveryGroupLayout layout) => components.any(
  (component) => switch (component) {
    PluginDiscoveryGroupComponent() => component.layout == layout || _containsDemoGroupLayout(component.children, layout),
    PluginDiscoverySectionComponent() => _containsDemoGroupLayout(component.children, layout),
    _ => false,
  },
);
