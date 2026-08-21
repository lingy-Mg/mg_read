import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/content_library/src/models.dart';
import 'package:mg_read/features/library/data/content_library_overview_loader.dart';

void main() {
  test(
    'reads persisted bookshelf items through the feature projection',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mg-read-library-home-',
      );
      final library = await ContentLibrary.open(dataRoot: root);
      addTearDown(() async {
        await library.close();
        await root.delete(recursive: true);
      });
      await library.bookshelf.add(
        title: '持久化书架测试',
        kind: ContentKind.novel,
        source: const ContentLibraryIngest(
          pluginId: 'test-source',
          producerPluginVersion: '1.0.0',
          dataVersion: 1,
          opaqueData: <String, Object?>{'remoteBookId': 'persisted-book'},
        ),
      );

      final overview = await ContentLibraryOverviewLoader(library).load();

      expect(overview.items, hasLength(1));
      expect(overview.items.single.id, isNotEmpty);
      expect(overview.items.single.title, '持久化书架测试');
    },
  );
}
