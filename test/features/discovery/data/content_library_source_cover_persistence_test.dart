import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/discovery/data/content_library_source_cover_persistence.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

void main() {
  test('persists a source cover and reuses it after reopening', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-source-cover-');
    var library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    final url = Uri.parse('https://covers.example/shared.png');
    var fetchCount = 0;
    final first = await ContentLibrarySourceCoverPersistence(
      library,
      fetcher: (uri) async {
        expect(uri, url);
        fetchCount += 1;
        return <int>[7, 8, 9];
      },
    ).resolve(BookCoverRequest(pluginId: 'fixture-source', pluginVersion: '1.0.0', remoteContentId: 'book-1', coverUrl: url));
    expect(first, <int>[7, 8, 9]);
    expect(fetchCount, 1);

    await library.close();
    library = await ContentLibrary.open(dataRoot: root);
    final second = await ContentLibrarySourceCoverPersistence(
      library,
      fetcher: (_) async {
        fail('A persisted source cover should not be fetched again.');
      },
    ).resolve(BookCoverRequest(pluginId: 'fixture-source', pluginVersion: '1.0.0', remoteContentId: 'book-1', coverUrl: url));

    expect(second, <int>[7, 8, 9]);
  });
}
