import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/content_library/src/content_library.dart';
import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/features/library/application/library_book_detail_failure.dart';
import 'package:mg_read/features/library/data/content_library_book_detail_launcher.dart';

void main() {
  test(
    'maps a persisted shelf item and catalog to the detail launch data',
    () async {
      final root = await Directory.systemTemp.createTemp('mg-read-detail-');
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      const source = ContentLibraryIngest(
        pluginId: 'org.example.source',
        producerPluginVersion: '1.0.0',
        dataVersion: 1,
        opaqueData: <String, Object?>{'remoteBookId': 'book-7'},
      );
      final item = await library.bookshelf.add(
        title: '书架详情测试',
        author: '测试作者',
        kind: ContentKind.novel,
        source: source,
      );
      await library.catalog.replaceSnapshot(
        itemId: item.id,
        bindingId: const SourceBindingId('binding-7'),
        entries: <IngestCatalogEntry>[
          IngestCatalogEntry(
            remoteIdentity: 'chapter-1',
            title: '第一章',
            orderKey: '000001',
            kindCode: ContentKind.novel.code,
            source: source,
            index: 0,
            wordCount: 1234,
          ),
        ],
      );

      final detail = await ContentLibraryBookDetailLauncher(
        library,
      ).load(item.id.value);

      expect(detail.pluginId, 'org.example.source');
      expect(detail.remoteContentId, 'book-7');
      expect(detail.initialContent.title, '书架详情测试');
      expect(detail.initialContent.contentKind, PluginContentKind.novel);
      expect(detail.initialContent.chapterCount, 1);
      expect(detail.initialCatalog.totalCount, 1);
      expect(detail.initialCatalog.items.single.id, 'chapter-1');
      expect(detail.initialCatalog.items.single.wordCount, 1234);
    },
  );

  test(
    'reports a safe code when an old shelf item lacks source metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('mg-read-detail-');
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      final item = await library.bookshelf.add(
        title: '旧书架记录',
        author: null,
        kind: ContentKind.novel,
        source: const ContentLibraryIngest(
          pluginId: 'org.example.source',
          producerPluginVersion: '1.0.0',
          dataVersion: 1,
          opaqueData: <String, Object?>{},
        ),
      );

      await expectLater(
        ContentLibraryBookDetailLauncher(library).load(item.id.value),
        throwsA(
          isA<LibraryBookDetailFailure>()
              .having(
                (failure) => failure.reason,
                'reason',
                LibraryBookDetailFailureReason.sourceMissing,
              )
              .having(
                (failure) => failure.diagnosticCode,
                'diagnosticCode',
                'library_detail_source_missing_invalid_format',
              ),
        ),
      );
    },
  );
}
