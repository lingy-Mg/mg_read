/// Filters cross the real Node validator and public Dart Facade decoder.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'test_paths.dart';

void main() {
  test(
    'decodes source filter groups and rejects invalid selections and oversized option sets',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-discovery-filters-',
      );
      final plugin = Directory.fromUri(
        root.uri.resolve('plugins/org.test.filters/'),
      );
      final version = Directory.fromUri(plugin.uri.resolve('versions/1.0.0/'));
      await Directory.fromUri(
        version.uri.resolve('dist/'),
      ).create(recursive: true);
      await File.fromUri(version.uri.resolve('package.json')).writeAsString(
        jsonEncode({
          'name': '@mgread-plugin/filters',
          'version': '1.0.0',
          'type': 'module',
          'main': 'dist/index.mjs',
          'engines': {'node': '>=24'},
          'mgread': {
            'schemaVersion': 1,
            'id': 'org.test.filters',
            'displayName': 'Filters fixture',
            'sourceUrl': 'https://fixture.example/',
            'pluginApi': 1,
            'contentKinds': ['video'],
          },
        }),
      );
      await File.fromUri(
        version.uri.resolve('package-lock.json'),
      ).writeAsString(
        jsonEncode({
          'name': '@mgread-plugin/filters',
          'version': '1.0.0',
          'lockfileVersion': 3,
          'packages': {
            '': {'name': '@mgread-plugin/filters', 'version': '1.0.0'},
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
                const SourceDiscoverInvocation(pluginId: 'org.test.filters'),
              )
              as PluginDiscoveryDocumentResult;
      final filters =
          result.document.components.single as PluginDiscoveryFiltersComponent;
      expect(filters.resetTarget, 'library');
      expect(filters.groups.single.label, 'Genre');
      expect(filters.groups.single.selectedOptionId, 'genre:2');
      expect(filters.groups.single.options, hasLength(45));
      expect(filters.groups.single.options[2].target, 'filter:2');
      for (final target in ['invalid', 'too-many']) {
        await expectLater(
          runtime.invoke(
            SourceDiscoverInvocation(
              pluginId: 'org.test.filters',
              target: target,
            ),
          ),
          throwsA(isA<PluginRuntimeException>()),
        );
      }
    },
  );
}

const _source = r'''
export function activate() {}
export function discover(request) { return {kind:'document',document:{components:[{
  type:'filters',id:'filters',resetTarget:'library',groups:[{id:'genre',label:'Genre',
    selectedOptionId:request.target==='invalid'?'missing':'genre:2',
    options:Array.from({length:request.target==='too-many'?65:45},(_,i)=>({id:`genre:${i}`,label:`Genre ${i}`,target:`filter:${i}`}))
  }]
}]}};}
export function search(){return {items:[],nextCursor:null,totalCount:0};}
export function getDetail(){throw new Error('unused');}
export function getChapters(){throw new Error('unused');}
export function getContent(){throw new Error('unused');}
''';
