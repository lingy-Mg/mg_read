/// Exercises inline input validation and decoding across the real Node/Facade boundary.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'test_paths.dart';

void main() {
  test(
    'decodes a source-declared search input and rejects invalid labels',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-discovery-input-',
      );
      final plugin = Directory.fromUri(
        root.uri.resolve('plugins/org.test.input/'),
      );
      final version = Directory.fromUri(plugin.uri.resolve('versions/1.0.0/'));
      await Directory.fromUri(
        version.uri.resolve('dist/'),
      ).create(recursive: true);
      await File.fromUri(version.uri.resolve('package.json')).writeAsString(
        jsonEncode({
          'name': '@mgread-plugin/input',
          'version': '1.0.0',
          'type': 'module',
          'main': 'dist/index.mjs',
          'engines': {'node': '>=24'},
          'mgread': {
            'schemaVersion': 1,
            'id': 'org.test.input',
            'displayName': 'Input fixture',
            'sourceUrl': 'https://fixture.example/',
            'pluginApi': 1,
            'contentKinds': ['audio'],
          },
        }),
      );
      await File.fromUri(
        version.uri.resolve('package-lock.json'),
      ).writeAsString(
        jsonEncode({
          'name': '@mgread-plugin/input',
          'version': '1.0.0',
          'lockfileVersion': 3,
          'packages': {
            '': {'name': '@mgread-plugin/input', 'version': '1.0.0'},
          },
        }),
      );
      await File.fromUri(
        version.uri.resolve('dist/index.mjs'),
      ).writeAsString(_source);
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
      final result =
          await runtime.invoke(
                const SourceDiscoverInvocation(pluginId: 'org.test.input'),
              )
              as PluginDiscoveryDocumentResult;
      final input =
          result.document.components.single
              as PluginDiscoverySearchInputComponent;
      expect(input.id, 'url');
      expect(input.label, '视频链接');
      expect(input.placeholder, 'BV…');
      expect(input.submitLabel, '读取音频');
      await expectLater(
        runtime.invoke(
          const SourceDiscoverInvocation(
            pluginId: 'org.test.input',
            target: 'invalid',
          ),
        ),
        throwsA(isA<PluginRuntimeException>()),
      );
    },
  );
}

const _source = r'''
export function activate() {}
export function discover(request) {
  return {kind:'document', document:{components:[{
    type:'searchInput', id:'url', label:request.target === 'invalid' ? null : '视频链接', placeholder:'BV…', submitLabel:'读取音频'
  }]}};
}
export function search() {}
export function searchSuggestions() { return {items:[], nextCursor:null, totalCount:0}; }
export function getDetail() {}
export function getChapters() {}
export function getContent() {}
''';
