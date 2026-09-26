/// Real Node/Facade regression for optional whole-line catalogs, including
/// decoder state and request correlation. Uses an isolated temporary source.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'test_paths.dart';

void main() {
  test(
    'Facade loads 3000-episode lines without treating deferred groups as empty',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-deferred-test-',
      );
      final plugin = Directory.fromUri(
        root.uri.resolve('plugins/org.test.deferred/'),
      );
      final version = Directory.fromUri(plugin.uri.resolve('versions/1.0.0/'));
      await Directory.fromUri(
        version.uri.resolve('dist/'),
      ).create(recursive: true);
      await File.fromUri(version.uri.resolve('package.json')).writeAsString(
        jsonEncode({
          'name': '@mgread-plugin/deferred',
          'version': '1.0.0',
          'type': 'module',
          'main': 'dist/index.mjs',
          'engines': {'node': '>=24'},
          'mgread': {
            'schemaVersion': 1,
            'id': 'org.test.deferred',
            'displayName': 'Deferred fixture',
            'pluginApi': 1,
            'contentKinds': ['video'],
          },
        }),
      );
      await File.fromUri(
        version.uri.resolve('package-lock.json'),
      ).writeAsString(
        jsonEncode({
          'name': '@mgread-plugin/deferred',
          'version': '1.0.0',
          'lockfileVersion': 3,
          'packages': {
            '': {'name': '@mgread-plugin/deferred', 'version': '1.0.0'},
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
      final initial = await runtime.invoke(
        const SourceChaptersInvocation(
          pluginId: 'org.test.deferred',
          id: 'video',
        ),
      );
      expect(initial.items, hasLength(3000));
      expect(initial.groups.last.deferred, isTrue);
      expect(initial.groups.last.episodes, isEmpty);
      final loaded = await runtime.invoke(
        const SourceChaptersInvocation(
          pluginId: 'org.test.deferred',
          id: 'video',
          groupId: 'b',
        ),
      );
      expect(loaded.groups.last.deferred, isFalse);
      expect(loaded.groups.last.episodes.last.id, 'b-2999');
      await expectLater(
        runtime.invoke(
          const SourceChaptersInvocation(
            pluginId: 'org.test.deferred',
            id: 'video',
            groupId: 'missing',
          ),
        ),
        throwsA(isA<PluginRuntimeException>()),
      );
    },
  );
}

const _source = r'''
export const deferredGroups = true;
export function activate() {}
export function discover() {}
export function search() {}
export function searchSuggestions() { return {items: [], nextCursor: null, totalCount: 0}; }
export function getDetail() {}
export function getContent() {}
export function getChapters(request) {
  const selected = request.groupId ?? 'a';
  const groups = ['a','b'].map((id, order) => ({ id, title:id, order,
    ...(id !== selected ? {deferred:true} : {}),
    episodes: id !== selected ? [] : Array.from({length:3000}, (_, i) => ({
      id: id+'-'+i, title:'Episode '+i, order:i, url:null, volumeTitle:null,
      wordCount:null, updatedAt:null, isLocked:false, attributes:[]
    }))
  }));
  return {groups, items:groups.flatMap(group => group.episodes)};
}
''';
