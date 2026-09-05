import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/library/data/content_library_book_remover.dart';

void main() {
  test('removes the item from the shelf while retaining reusable content', () async {
    final Directory root = await Directory.systemTemp.createTemp('mg-read-book-remover-');
    final ContentLibrary library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });

    final item = await library.addLibraryItem(
      const BookshelfAddRequest(
        title: '待删除书籍',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'test-source',
        pluginVersion: '1.0.0',
        remoteContentId: 'book-to-remove',
      ),
    );

    await ContentLibraryBookRemover(library).removeBook(item.id.value);

    expect((await library.getLibraryItem(item.id))?.state, 'retained');
    expect((await library.listLibrary(const LibraryQuery())).items, isEmpty);
  });
}
