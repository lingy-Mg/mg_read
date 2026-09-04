import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/features/profile/data/content_library_profile_reading_stats_loader.dart';

void main() {
  test('projects local shelf count, read books, and reading duration', () async {
    final root = await Directory.systemTemp.createTemp('mg-read-profile-');
    final library = await ContentLibrary.open(dataRoot: root);
    addTearDown(() async {
      await library.close();
      await root.delete(recursive: true);
    });
    final readItem = await library.addLibraryItem(
      const BookshelfAddRequest(
        title: '已读书',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'read',
      ),
    );
    await library.addLibraryItem(
      const BookshelfAddRequest(
        title: '未读书',
        author: null,
        kind: ContentKind.novel,
        pluginId: 'fixture',
        pluginVersion: '1.0.0',
        remoteContentId: 'unread',
      ),
    );
    await library.saveProgress(
      LibraryReadingProgress(
        itemId: readItem.id,
        chapterId: 'chapter-1',
        paragraphId: 'chapter-1:paragraph:0',
        characterOffset: 0,
        chapterIndex: 0,
        chapterFraction: 0,
        bookFraction: 0,
        updatedAtUtc: DateTime.utc(2026, 8, 22),
        totalReadingSeconds: 7320,
      ),
    );

    final stats = await ContentLibraryProfileReadingStatsLoader(library).load();

    expect(stats.shelfBookCount, 2);
    expect(stats.readBookCount, 1);
    expect(stats.totalReadingSeconds, 7320);
  });
}
