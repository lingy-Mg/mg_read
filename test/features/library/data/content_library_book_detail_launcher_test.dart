import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/application/library_book_detail_failure.dart';
import 'package:mg_read/features/library/data/content_library_book_detail_launcher.dart';

void main() {
  test('maps a persisted shelf item and catalog to the detail launch data', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-detail-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.addLibraryItem(
      BookshelfAddRequest(
        title: '书架详情测试',
        author: '测试作者',
        kind: ContentKind.novel,
        pluginId: 'org.example.source',
        pluginVersion: '1.0.0',
        remoteContentId: 'book-7',
        language: 'zh-CN',
        accessCode: 'free',
        categories: const <String>['都市'],
        attributes: const <LibraryItemAttribute>[LibraryItemAttribute(key: 'heat', label: '热度', value: '565.2万')],
        sourceDetail: const <String, Object?>{
          'sourceName': '完整详情源',
          'catalogUrl': 'https://source.example/catalog/book-7',
          'aliases': <Object?>['书架详情别名'],
          'summary': <String, Object?>{
            'id': 'book-7',
            'title': '书架详情测试',
            'contentKind': 'novel',
            'author': '测试作者',
            'language': 'zh-CN',
            'status': 'ongoing',
            'access': 'free',
            'chapterCount': 1,
            'categories': <Object?>['都市'],
            'attributes': <Object?>[
              <String, Object?>{'key': 'heat', 'label': '热度', 'value': '565.2万'},
            ],
          },
        },
      ),
    );
    await library.syncNovelCatalog(
      itemId: item.id,
      chapters: const <SourceNovelCatalogChapter>[
        SourceNovelCatalogChapter(remoteIdentity: 'chapter-1', title: '第一章', index: 0, wordCount: 1234),
      ],
    );

    final detail = await ContentLibraryBookDetailLauncher(library).load(item.id.value);

    expect(detail.pluginId, 'org.example.source');
    expect(detail.pluginVersion, '1.0.0');
    expect(detail.remoteContentId, 'book-7');
    expect(detail.initialContent.title, '书架详情测试');
    expect(detail.initialContent.contentKind, PluginContentKind.novel);
    expect(detail.initialContent.chapterCount, 1);
    expect(detail.initialContent.language, 'zh-CN');
    expect(detail.initialContent.access, PluginAccessKind.free);
    expect(detail.initialContent.categories, <String>['都市']);
    expect(detail.initialContent.attributes.single.key, 'heat');
    expect(detail.initialContent.attributes.single.value, '565.2万');
    expect(detail.initialDetail.sourceName, '完整详情源');
    expect(detail.initialDetail.aliases, <String>['书架详情别名']);
    expect(detail.initialDetail.catalogUrl, Uri.parse('https://source.example/catalog/book-7'));
    expect(detail.initialCatalog.items, hasLength(1));
    expect(detail.initialCatalog.items.single.id, 'chapter-1');
    expect(detail.initialCatalog.items.single.wordCount, 1234);
  });

  test('reports a safe code when a shelf item does not exist', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-detail-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    await expectLater(
      ContentLibraryBookDetailLauncher(library).load('missing'),
      throwsA(
        isA<LibraryBookDetailFailure>()
            .having((failure) => failure.reason, 'reason', LibraryBookDetailFailureReason.itemMissing)
            .having((failure) => failure.diagnosticCode, 'diagnosticCode', 'library_detail_item_missing_not_found'),
      ),
    );
  });

  test('maps a manga shelf item to manga detail content', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-detail-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final item = await library.addLibraryItem(
      const BookshelfAddRequest(
        title: '书架漫画详情',
        author: '漫画作者',
        kind: ContentKind.manga,
        pluginId: 'org.example.manga',
        pluginVersion: '1.0.0',
        remoteContentId: 'manga-7',
        chapterCount: 12,
      ),
    );

    final detail = await ContentLibraryBookDetailLauncher(library).load(item.id.value);

    expect(detail.initialContent.contentKind, PluginContentKind.manga);
    expect(detail.initialContent.title, '书架漫画详情');
    expect(detail.initialContent.chapterCount, 12);
    expect(detail.initialCatalog.items, isEmpty);
  });
}
