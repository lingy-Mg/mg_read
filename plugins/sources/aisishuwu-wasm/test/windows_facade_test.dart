/// Opt-in Windows source acceptance against the production Facade and a private
/// cold-installed Runtime data root. Evidence contains metadata and counts only.
// This opt-in test lives outside Flutter's conventional root test/ directory.
// ignore_for_file: invalid_use_of_visible_for_testing_member
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

void main() {
  test(
    'Windows Facade reads the portable Rust source and complete catalog',
    () async {
      final root = Directory.current.absolute;
      final manifest =
          jsonDecode(await File('${root.path}/plugins/sources/aisishuwu-wasm/package.json').readAsString()) as Map<String, dynamic>;
      final version = manifest['version'] as String;
      const id = 'org.mgread.aisishuwu.wasm';
      final data = await Directory.systemTemp.createTemp('mgread-wasm-facade-');
      addTearDown(() async {
        final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
        final target = await data.resolveSymbolicLinks();
        if (!target.startsWith('$temporaryRoot${Platform.pathSeparator}')) {
          throw StateError('Refusing cleanup outside the temporary test root.');
        }
        // Installed artifacts are deliberately read-only on Windows.
        final attributes = await Process.run('attrib.exe', ['-R', '${data.path}\\*', '/S', '/D']);
        if (attributes.exitCode != 0) throw StateError('Cannot release test artifact attributes.');
        await data.delete(recursive: true);
      });
      final inbox = await Directory('${data.path}/import-inbox').create();
      final artifact = File('${root.path}/plugins/sources/aisishuwu-wasm/artifacts/$id-$version.mgplugin.js');
      await artifact.copy('${inbox.path}/$id-$version.mgplugin.js');
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: Directory('${root.path}/packages/mg_read_node_runtime'),
        runtimeDataRoot: data,
      );
      addTearDown(runtime.debugDispose);
      final proxy = Platform.environment['HTTPS_PROXY'];
      if (proxy != null && proxy.isNotEmpty) await runtime.configurePluginHttpProxy(Uri.parse(proxy));
      final status = await runtime.invoke(const RuntimeStatusInvocation());
      final evidence = <String, Object?>{'platform': 'windows', 'runtimeKind': status.runtimeKind, 'version': version};
      final source = (await runtime.invoke(const InstalledPluginsInvocation())).singleWhere((plugin) => plugin.id == id);
      expect(source.status, 'active');
      final cold = Stopwatch()..start();
      await runtime.invoke(const SourceSearchSuggestionsInvocation(pluginId: id, cursor: 'search-suggestions-page:2'));
      evidence['coldBinaryCallMs'] = cold.elapsedMilliseconds;
      final home = await runtime.invoke(const SourceDiscoverInvocation(pluginId: id));
      expect(home, isA<PluginDiscoveryDocumentResult>());
      final categories = (home as PluginDiscoveryDocumentResult).document.components
          .whereType<PluginDiscoveryCategoryCollectionComponent>()
          .first;
      final category = await runtime.invoke(
        SourceDiscoverInvocation(pluginId: id, target: categories.categories.first.target, pageSize: 3),
      );
      expect(category, isA<PluginDiscoveryDocumentResult>());
      final search = await runtime.invoke(const SourceSearchInvocation(pluginId: id, query: '修仙', pageSize: 3));
      expect(search.items, isNotEmpty);
      evidence['searchItems'] = search.items.length;
      const book = 'novel:52801';
      final detail = await runtime.invoke(const SourceDetailInvocation(pluginId: id, id: book));
      final chapters = await runtime.invoke(const SourceChaptersInvocation(pluginId: id, id: book));
      expect(chapters.items.length, detail.summary.chapterCount);
      expect(chapters.items.length, greaterThan(700));
      expect(chapters.items.map((c) => c.id).toSet().length, chapters.items.length);
      final lengths = <int>[];
      for (final index in <int>{0, chapters.items.length ~/ 2, chapters.items.length - 1}) {
        final content = await runtime.invoke(SourceContentInvocation(pluginId: id, id: book, chapterId: chapters.items[index].id));
        expect(content.text, isNotEmpty);
        lengths.add(content.text!.length);
      }
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
      addTearDown(client.close);
      final response = await (await client.getUrl(detail.summary.coverUrl!)).close();
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, startsWith('image/'));
      expect(await response.first, isNotEmpty);
      evidence.addAll({
        'chapterCount': chapters.items.length,
        'firstMiddleLastTextLengths': lengths,
        'coverMime': response.headers.contentType?.mimeType,
        'status': 'passed',
      });
      await File(
        '${root.path}/artifacts/wasm-source/windows-facade-report.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: !Platform.isWindows,
  );
}
