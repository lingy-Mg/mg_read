/// Installs the unchanged portable Wasm artifact and exercises the real Android
/// Runtime/Facade, live site and resource proxy. Reports counts, never book text.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const pluginId = 'org.mgread.aisishuwu.wasm';

  testWidgets('portable Rust binary completes the Android live source chain', (tester) async {
    await tester.pump();
    final runtime = PluginRuntime();
    addTearDown(runtime.debugDispose);
    const proxy = String.fromEnvironment('MGREAD_TEST_HTTP_PROXY');
    if (proxy.isNotEmpty) await runtime.configurePluginHttpProxy(Uri.parse(proxy));
    final evidence = <String, Object?>{};
    binding.reportData = evidence;
    evidence['explicitTestProxy'] = proxy.isNotEmpty;
    final status = await runtime.invoke(const RuntimeStatusInvocation());
    evidence['runtimeKind'] = status.runtimeKind;
    evidence['arch'] = status.arch;
    final installed = await runtime.invoke(const InstalledPluginsInvocation());
    final source = installed.singleWhere((plugin) => plugin.id == pluginId);
    expect(source.status, 'active');
    evidence['pluginVersion'] = source.activeVersion;

    final cold = Stopwatch()..start();
    final empty = await runtime.invoke(
      const SourceSearchSuggestionsInvocation(pluginId: pluginId, cursor: 'search-suggestions-page:2', pageSize: 5),
    );
    expect(empty.items, isEmpty);
    evidence['coldBinaryCallMs'] = cold.elapsedMilliseconds;
    final warm = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      await runtime.invoke(const SourceSearchSuggestionsInvocation(pluginId: pluginId, cursor: 'search-suggestions-page:2', pageSize: 5));
    }
    evidence['warmBinaryCallMeanMs'] = warm.elapsedMicroseconds / 20000;

    final home = await runtime.invoke(const SourceDiscoverInvocation(pluginId: pluginId, pageSize: 5));
    expect(home, isA<PluginDiscoveryDocumentResult>());
    final components = (home as PluginDiscoveryDocumentResult).document.components;
    evidence['homeComponents'] = components.length;
    final categories = components.whereType<PluginDiscoveryCategoryCollectionComponent>().first;
    expect(categories.categories, isNotEmpty);
    final category = await runtime.invoke(
      SourceDiscoverInvocation(pluginId: pluginId, target: categories.categories.first.target, pageSize: 3),
    );
    expect(category, isA<PluginDiscoveryDocumentResult>());
    evidence['category'] = 'passed';
    final search = await runtime.invoke(const SourceSearchInvocation(pluginId: pluginId, query: '修仙', pageSize: 3));
    expect(search.items, isNotEmpty);
    evidence['searchItems'] = search.items.length;
    // Use the same stable catalog as the repository's full-catalog acceptance.
    const contentId = 'novel:52801';
    final detail = await runtime.invoke(const SourceDetailInvocation(pluginId: pluginId, id: contentId));
    expect(detail.summary.title, isNotEmpty);
    final chapters = await runtime.invoke(const SourceChaptersInvocation(pluginId: pluginId, id: contentId));
    expect(chapters.items, isNotEmpty);
    if (detail.summary.chapterCount != null) expect(chapters.items.length, detail.summary.chapterCount);
    expect(chapters.items.map((chapter) => chapter.id).toSet().length, chapters.items.length);
    evidence['chapterCount'] = chapters.items.length;
    final lengths = <int>[];
    for (final index in <int>{0, chapters.items.length ~/ 2, chapters.items.length - 1}) {
      final content = await runtime.invoke(SourceContentInvocation(pluginId: pluginId, id: contentId, chapterId: chapters.items[index].id));
      expect(content.text, isNotEmpty);
      lengths.add(content.text!.length);
    }
    evidence['firstMiddleLastTextLengths'] = lengths;
    final cover = detail.summary.coverUrl;
    expect(cover, isNotNull);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    addTearDown(client.close);
    final response = await (await client.getUrl(cover!)).close();
    expect(response.statusCode, 200);
    expect(response.headers.contentType?.mimeType, startsWith('image/'));
    final prefix = await response.first;
    expect(prefix, isNotEmpty);
    evidence['detailCoverMime'] = response.headers.contentType?.mimeType;
    evidence['detailCoverPrefixBytes'] = prefix.length;
    evidence['status'] = 'passed';
  }, timeout: const Timeout(Duration(minutes: 10)));
}
