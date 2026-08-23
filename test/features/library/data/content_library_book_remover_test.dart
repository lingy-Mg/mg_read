import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/features/library/data/content_library_book_remover.dart';

void main() {
  test(
    'removes only the bookshelf record through the Content Library',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'mg-read-book-remover-',
      );
      final ContentLibrary library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });

      final item = await library.bookshelf.add(
        title: '待删除书籍',
        kind: ContentKind.novel,
        source: const ContentLibraryIngest(
          pluginId: 'test-source',
          producerPluginVersion: '1.0.0',
          dataVersion: 1,
          opaqueData: <String, Object?>{'remoteBookId': 'book-to-remove'},
        ),
      );

      await ContentLibraryBookRemover(library).removeBook(item.id.value);

      expect(await library.getLibraryItem(item.id), isNull);
      expect((await library.listLibrary(const LibraryQuery())).items, isEmpty);
    },
  );
}
