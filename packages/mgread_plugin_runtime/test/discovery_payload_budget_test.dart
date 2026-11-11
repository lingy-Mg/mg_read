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
            'contentKinds': ['video', 'novel', 'manga'],
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
      final thousandSearch = await runtime.invoke(
        const SourceSearchInvocation(
          pluginId: 'org.test.budget',
          query: 'thousand',
          pageSize: 1000,
        ),
      );
      expect(thousandSearch.items, hasLength(1000));
      final thousandDiscovery =
          await runtime.invoke(
                const SourceDiscoverInvocation(
                  pluginId: 'org.test.budget',
                  target: 'thousand',
                  pageSize: 1000,
                ),
              )
              as PluginDiscoveryDocumentResult;
      expect(
        (thousandDiscovery.document.components.single
                as PluginDiscoveryContentCollectionComponent)
            .items,
        hasLength(1000),
      );
      final catalog = await runtime.invoke(
        const SourceChaptersInvocation(
          pluginId: 'org.test.budget',
          id: 'novel:1',
        ),
      );
      expect(catalog.items, hasLength(800));
      final manga = await runtime.invoke(
        const SourceContentInvocation(
          pluginId: 'org.test.budget',
          id: 'manga:1',
          chapterId: 'manga',
        ),
      );
      expect(manga.pages, hasLength(500));
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
  const count = request.target === 'thousand' ? 1000 : request.target === 'oversized' ? 110 : request.target === 'small' ? 1 : 100;
  const pageSize = request.target === 'thousand' ? 1000 : 50;
  const content = {title:'Fixture',contentKind:'video',coverOrientation:'portrait',author:null,url:null,
    coverUrl:null,description:request.target === 'thousand' ? null : '详'.repeat(32000),language:null,status:'unknown',access:'unknown',
    wordCount:null,chapterCount:null,publishedAt:null,updatedAt:null,latestChapter:null,categories:[],tags:[],attributes:[]};
  return {kind:'document',document:{components:Array.from({length:Math.ceil(count/pageSize)},(_,part)=>({
    type:'contentCollection',id:`list:${part}`,layout:'coverGrid',continuation:null,
    items:Array.from({length:Math.min(pageSize,count-part*pageSize)},(_,i)=>({
      content:{...content,id:`video:${part*pageSize+i}`},rank:null,metric:null,recommendation:null
    }))
  }))}};
}
export function search(request){return {items:request.query==='thousand'?discover({target:'thousand'}).document.components[0].items.map(item=>item.content):[],nextCursor:null,totalCount:null};}
export function getDetail(){throw new Error('unused');}
export function getChapters(){return {items:Array.from({length:800},(_,i)=>({
  id:`${i}-${'x'.repeat(4090)}`,title:'Chapter',order:i,url:null,volumeTitle:null,wordCount:null,updatedAt:null,isLocked:null,attributes:[]
}))};}
export function getContent(request){if(request.chapterId==='manga')return {
  chapterId:request.chapterId,contentKind:'manga',title:null,updatedAt:null,text:null,
  pages:Array.from({length:500},(_,index)=>({id:`page:${index}`,index,url:`https://example.com/${'x'.repeat(4096)}`,mimeType:null,width:null,height:null}))
};return {
  chapterId:request.chapterId,contentKind:'novel',title:null,updatedAt:null,pages:[],
  text:(request.chapterId==='escaped'?'\0':'x').repeat(10*1024*1024+(request.chapterId==='oversized'?1:0))
};}
''';
