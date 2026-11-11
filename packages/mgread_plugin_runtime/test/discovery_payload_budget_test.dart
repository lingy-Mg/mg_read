/// Verifies discovery budgets and complete 10 MiB novel text over the real Node wire.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'test_paths.dart';

void main() {
  test(
    'decodes a 9 MiB discovery document and rejects a result over 10 MiB',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mgread-payload-budget-',
      );
      final plugin = Directory.fromUri(
        root.uri.resolve('plugins/org.test.budget/'),
      );
      final version = Directory.fromUri(plugin.uri.resolve('versions/1.0.0/'));
      await Directory.fromUri(
        version.uri.resolve('dist/'),
      ).create(recursive: true);
      await File.fromUri(version.uri.resolve('package.json')).writeAsString(
        jsonEncode({
          'name': '@mgread-plugin/budget',
          'version': '1.0.0',
          'type': 'module',
          'main': 'dist/index.mjs',
          'engines': {'node': '>=24'},
          'mgread': {
            'schemaVersion': 1,
            'id': 'org.test.budget',
            'displayName': 'Budget fixture',
            'sourceUrl': 'https://fixture.example/',
            'pluginApi': 1,
            'contentKinds': ['video', 'novel'],
          },
        }),
      );
      await File.fromUri(
        version.uri.resolve('package-lock.json'),
      ).writeAsString(
        jsonEncode({
          'name': '@mgread-plugin/budget',
          'version': '1.0.0',
          'lockfileVersion': 3,
          'packages': {
            '': {'name': '@mgread-plugin/budget', 'version': '1.0.0'},
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
                const SourceDiscoverInvocation(pluginId: 'org.test.budget'),
              )
              as PluginDiscoveryDocumentResult;
      final collections = result.document.components
          .cast<PluginDiscoveryContentCollectionComponent>();
      final items = collections
          .expand((collection) => collection.items)
          .toList();
      expect(items, hasLength(100));
      expect(items.first.content.description, '详' * 32000);
      expect(items.last.content.id, 'video:99');
      await expectLater(
        runtime.invoke(
          const SourceDiscoverInvocation(
            pluginId: 'org.test.budget',
            target: 'oversized',
          ),
        ),
        throwsA(
          isA<PluginRuntimeException>().having(
            (error) => error.message,
            'message',
            contains('10485760-byte limit'),
          ),
        ),
      );
      // An oversized result must not close the socket or break later requests.
      final ping = await runtime.invoke(
        const SourceDiscoverInvocation(
          pluginId: 'org.test.budget',
          target: 'small',
        ),
      );
      expect(
        (ping as PluginDiscoveryDocumentResult).document.components,
        hasLength(1),
      );
      for (final chapterId in ['large', 'escaped']) {
        final content = await runtime.invoke(
          SourceContentInvocation(
            pluginId: 'org.test.budget',
            id: 'novel:1',
            chapterId: chapterId,
          ),
        );
        expect(content.text, hasLength(10 * 1024 * 1024));
        expect(content.text!.codeUnitAt(0), chapterId == 'escaped' ? 0 : 120);
      }
      await expectLater(
        runtime.invoke(
          const SourceContentInvocation(
            pluginId: 'org.test.budget',
            id: 'novel:1',
            chapterId: 'oversized',
          ),
        ),
        throwsA(
          isA<PluginRuntimeException>().having(
            (error) => error.message,
            'measured text limit',
            contains('10485761 bytes exceeds the 10485760-byte limit'),
          ),
        ),
      );
    },
  );
}

const _source = r'''
export function activate() {}
export function discover(request) {
  const count = request.target === 'oversized' ? 110 : request.target === 'small' ? 1 : 100;
  const content = {title:'Fixture',contentKind:'video',coverOrientation:'portrait',author:null,url:null,
    coverUrl:null,description:'详'.repeat(32000),language:null,status:'unknown',access:'unknown',
    wordCount:null,chapterCount:null,publishedAt:null,updatedAt:null,latestChapter:null,categories:[],tags:[],attributes:[]};
  return {kind:'document',document:{components:Array.from({length:Math.ceil(count/50)},(_,part)=>({
    type:'contentCollection',id:`list:${part}`,layout:'coverGrid',continuation:null,
    items:Array.from({length:Math.min(50,count-part*50)},(_,i)=>({
      content:{...content,id:`video:${part*50+i}`},rank:null,metric:null,recommendation:null
    }))
  }))}};
}
export function search(){return {items:[],nextCursor:null,totalCount:0};}
export function getDetail(){throw new Error('unused');}
export function getChapters(){throw new Error('unused');}
export function getContent(request){return {
  chapterId:request.chapterId,contentKind:'novel',title:null,updatedAt:null,pages:[],
  text:(request.chapterId==='escaped'?'\0':'x').repeat(10*1024*1024+(request.chapterId==='oversized'?1:0))
};}
''';
