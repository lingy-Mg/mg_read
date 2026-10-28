/// Maintenance state is decoded across Node/Facade; blocked entry points cannot reach plugin code.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'test_paths.dart';

void main() {
  for (final state in ['disabled', 'invalid']) {
    test('decodes $state and preserves access to existing content', () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-source-state-',
      );
      final plugin = Directory.fromUri(
        root.uri.resolve('plugins/org.mgread.runtime.fixture/'),
      );
      final version = Directory.fromUri(plugin.uri.resolve('versions/1.0.0/'));
      await Directory.fromUri(
        version.uri.resolve('dist/'),
      ).create(recursive: true);
      final fixture = nodeRuntimeRepositoryRoot.uri.resolve(
        'test/fixtures/standard-plugin/',
      );
      final pkg =
          jsonDecode(
                await File.fromUri(
                  fixture.resolve('package.json'),
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final metadata = pkg['mgread'] as Map<String, dynamic>;
      metadata['sourceState'] = state;
      metadata['sourceStateReason'] = '网站已禁用播放';
      await File.fromUri(
        version.uri.resolve('package.json'),
      ).writeAsString(jsonEncode(pkg));
      await File.fromUri(
        fixture.resolve('dist/index.mjs'),
      ).copy(File.fromUri(version.uri.resolve('dist/index.mjs')).path);
      await File.fromUri(
        plugin.uri.resolve('pending'),
      ).writeAsString('1.0.0\n');
      final runtime = PluginRuntime.desktopForTesting(
        runtimeRepositoryRoot: nodeRuntimeRepositoryRoot,
        runtimeDataRoot: root,
      );
      addTearDown(() async {
        await runtime.debugDispose();
        await root.delete(recursive: true);
      });
      final installed = await runtime.invoke(
        const InstalledPluginsInvocation(),
      );
      expect(installed.single.sourceState, state);
      expect(installed.single.sourceStateReason, '网站已禁用播放');
      for (final invocation in <PluginInvocation<Object?>>[
        const SourceDiscoverInvocation(pluginId: 'org.mgread.runtime.fixture'),
        const SourceSearchInvocation(
          pluginId: 'org.mgread.runtime.fixture',
          query: 'cached',
        ),
        const SourceSearchSuggestionsInvocation(
          pluginId: 'org.mgread.runtime.fixture',
        ),
      ]) {
        await expectLater(
          runtime.invoke(invocation),
          throwsA(
            isA<PluginRuntimeException>().having(
              (e) => e.code,
              'code',
              'plugin_disabled',
            ),
          ),
        );
      }
      final detail = await runtime.invoke(
        const SourceDetailInvocation(
          pluginId: 'org.mgread.runtime.fixture',
          id: 'fixture:cached',
        ),
      );
      expect(detail.summary.id, 'fixture:cached');
    });
  }
}
