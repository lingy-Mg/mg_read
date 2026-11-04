/// Loads the previous relational schema rather than simulating an upgrade by
/// opening a fresh database. Foreign-key-linked IDs must survive migration.
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mg_read/core/content_library/content_library.dart';
// Drift's actual SQLite engine is used only to construct the old fixture.
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('upgrades v1 tables without losing source identity, catalog, progress or bookmarks', () async {
    final root = await Directory.systemTemp.createTemp('mgread-v1-upgrade-');
    addTearDown(() => root.delete(recursive: true));
    final database = sqlite3.open('${root.path}/app_metadata.sqlite');
    final schema = await File('test/core/persistence/fixtures/content_library_v1.sql').readAsString();
    for (final statement in schema.split(';').where((statement) => statement.trim().isNotEmpty)) {
      database.execute(statement);
    }
    database.execute('PRAGMA user_version=1');
    database.execute(
      "INSERT INTO library_items(item_pk,item_id,sort_order,content_kind,title,source_plugin_id,source_plugin_version,remote_item_id,catalog_count,created_at_utc,updated_at_utc) VALUES(7,'old-book',0,'novel','升级前的书','real.source','1.0.0','remote-book',1,0,0)",
    );
    database.execute(
      "INSERT INTO catalog_chapters(chapter_id,item_pk,remote_identity,position,title) VALUES('old-entry',7,'remote-chapter',0,'第一章')",
    );
    database.execute(
      "INSERT INTO reading_progress(item_pk,progress_kind,chapter_id,chapter_position,paragraph_id,character_offset,chapter_fraction,book_fraction,total_reading_seconds,updated_at_utc) VALUES(7,'novel','remote-chapter',0,'old-paragraph',3,0.4,0.4,120,0)",
    );
    database.execute(
      "INSERT INTO bookmarks(bookmark_id,item_pk,bookmark_kind,chapter_id,paragraph_id,character_offset,created_at_utc) VALUES('old-bookmark',7,'novel','remote-chapter','old-paragraph',3,0)",
    );
    database.close();
    final library = await ContentLibrary.open(dataRoot: root);
    try {
      final item = (await library.getLibraryItem(const LibraryItemId('old-book')))!;
      expect(item.source.isLocal, isFalse);
      expect(item.source.pluginId, 'real.source');
      expect((await library.listAllCatalog(item.id)).single.id.value, 'old-entry');
      final progress = await library.loadProgress(item.id) as LibraryReadingProgress;
      expect(progress.paragraphId, 'old-paragraph');
      expect(progress.totalReadingSeconds, 120);
      expect((await library.loadBookmarks(item.id, ContentKind.novel)).single.id, 'old-bookmark');
      expect(await library.persistentTableNamesForTest(), hasLength(5));
    } finally {
      await library.close();
    }
  });
}
