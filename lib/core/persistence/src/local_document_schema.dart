/// In-place upgrade of the app-owned Content Library schema. The Drift shell
/// has no generated tables; this versioned structural migration preserves all
/// five metadata tables and the IDs referenced by progress and bookmarks.
part of 'record_store.dart';

Future<void> _upgradeLocalDocumentSchema(_PersistenceDatabase db) async {
  final info = await db.customSelect('PRAGMA table_info(library_items)').get();
  if (info.isEmpty || info.any((row) => row.data['name'] == 'origin_kind')) return;
  // No business reader is published until open() completes. Disable FK checks
  // only for the atomic parent-table replacement, then verify every reference.
  await db.customStatement('PRAGMA foreign_keys=OFF');
  try {
    await db.transaction(() async {
      await db.customStatement(_createLibraryItemsSql.replaceFirst('library_items (', 'library_items_v2 ('));
      final columns = info.map((row) => '"${row.data['name']}"').join(',');
      await db.customStatement('INSERT INTO library_items_v2 ($columns) SELECT $columns FROM library_items');
      await db.customStatement('DROP TABLE library_items');
      await db.customStatement('ALTER TABLE library_items_v2 RENAME TO library_items');
      await db.customStatement("ALTER TABLE catalog_chapters ADD COLUMN catalog_generation TEXT NOT NULL DEFAULT '0'");
      await db.customStatement('DROP INDEX IF EXISTS catalog_chapters_item_remote');
      await db.customStatement('DROP INDEX IF EXISTS catalog_chapters_item_position');
      final violations = await db.customSelect('PRAGMA foreign_key_check').get();
      if (violations.isNotEmpty) throw const PersistenceConflictError();
    });
  } finally {
    await db.customStatement('PRAGMA foreign_keys=ON');
  }
}
