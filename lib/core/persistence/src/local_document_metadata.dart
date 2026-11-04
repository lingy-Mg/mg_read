/// Local document metadata transactions. Only validated, immutable file-object
/// references enter this boundary; staging and parsing never run in SQLite.
part of 'record_store.dart';

final class LocalCatalogWrite {
  const LocalCatalogWrite({
    required this.id,
    required this.key,
    required this.title,
    required this.index,
    required this.reference,
    required this.wordCount,
  });
  final String id, key, title, reference;
  final int index, wordCount;
}

extension LocalDocumentMetadata on ContentLibraryMetadataStore {
  Future<StoredLibraryItem?> localItemByGeneration(String generation) => _owner._withOperation(() async {
    final rows = await _select("SELECT * FROM library_items WHERE origin_kind='local' AND active_generation=? LIMIT 1", [
      Variable.withString(generation),
    ]);
    return rows.isEmpty ? null : StoredLibraryItem(rows.single);
  });

  Future<StoredLibraryItem?> localItemByHash(String hash) => _owner._withOperation(() async {
    final rows = await _select("SELECT * FROM library_items WHERE origin_kind = 'local' AND raw_sha256 = ? LIMIT 1", [
      Variable.withString(hash),
    ]);
    return rows.isEmpty ? null : StoredLibraryItem(rows.single);
  });

  Future<List<StoredLibraryItem>> localItems({bool includeRetained = true}) => _owner._withOperation(() async {
    final rows = await _select(
      "SELECT * FROM library_items WHERE origin_kind = 'local'${includeRetained ? '' : " AND shelf_state = 'active'"} ORDER BY updated_at_utc DESC LIMIT 1000",
      const [],
    );
    return rows.map(StoredLibraryItem.new).toList(growable: false);
  });

  Future<StoredLibraryItem> reactivateLocalItem(String itemId, int maximum) => _owner._withOperation(
    () => _owner._database.transaction(() async {
      final row = await readItem(itemId);
      if (row == null || row.values['origin_kind'] != 'local') throw const PersistenceNotFoundError();
      if (row.values['shelf_state'] == 'retained') {
        final count = await _owner._database.customSelect("SELECT COUNT(*) AS n FROM library_items WHERE shelf_state='active'").getSingle();
        if ((count.data['n']! as int) >= maximum) throw const PersistenceCapacityError();
        await _owner._database.customStatement(
          "UPDATE library_items SET shelf_state='active', item_revision=item_revision+1 WHERE item_id=?",
          [itemId],
        );
      }
      return (await readItem(itemId))!;
    }),
  );

  Future<StoredLibraryItemWriteResult> commitLocalDocument({
    required String itemId,
    required String documentId,
    required String title,
    required String? author,
    required String format,
    required String rawSha256,
    required String generation,
    required String detailsJson,
    required List<LocalCatalogWrite> chapters,
    required int maximumActiveItems,
    int? expectedRevision,
    Map<String, Object?>? progress,
    List<Map<String, Object?>>? bookmarks,
  }) => _owner._withOperation(
    () => _owner._database.transaction(() async {
      final existing = await readItem(itemId);
      final duplicate = expectedRevision == null ? await localItemByHash(rawSha256) : null;
      if (duplicate != null) {
        return StoredLibraryItemWriteResult(item: await reactivateLocalItem(duplicate.itemId, maximumActiveItems), created: false);
      }
      if (expectedRevision != null &&
          (existing == null || existing.values['item_revision'] != expectedRevision || existing.values['origin_kind'] != 'local')) {
        throw const PersistenceConflictError();
      }
      final now = _owner._clock().toUtc().millisecondsSinceEpoch;
      if (existing == null || existing.values['shelf_state'] == 'retained') {
        final count = await _owner._database.customSelect("SELECT COUNT(*) AS n FROM library_items WHERE shelf_state='active'").getSingle();
        if ((count.data['n']! as int) >= maximumActiveItems) throw const PersistenceCapacityError();
      }
      if (existing == null) {
        final order = await _owner._database.customSelect('SELECT COALESCE(MAX(sort_order), -1)+1 AS n FROM library_items').getSingle();
        await _owner._database.customStatement(
          '''INSERT INTO library_items
          (item_id,sort_order,content_kind,title,author,origin_kind,local_document_id,local_format,raw_sha256,
          active_generation,source_name,source_chapter_count,catalog_count,catalog_revision,details_json,created_at_utc,updated_at_utc)
          VALUES (?,?,'novel',?,?,'local',?,?,?,?,?,?,?,?,?,?,?)''',
          [
            itemId,
            order.data['n'],
            title,
            author,
            documentId,
            format,
            rawSha256,
            generation,
            '本地导入',
            chapters.length,
            chapters.length,
            1,
            detailsJson,
            now,
            now,
          ],
        );
      } else {
        await _owner._database.customStatement(
          '''UPDATE library_items SET title=?,author=?,local_format=?,raw_sha256=?,
          active_generation=?,details_json=?,catalog_count=?,source_chapter_count=?,catalog_revision=catalog_revision+1,
          item_revision=item_revision+1,shelf_state='active',updated_at_utc=? WHERE item_id=?''',
          [title, author, format, rawSha256, generation, detailsJson, chapters.length, chapters.length, now, itemId],
        );
      }
      final committed = (await readItem(itemId))!;
      await _owner._database.batch((batch) {
        for (final chapter in chapters) {
          batch.customStatement(
            '''INSERT INTO catalog_chapters
            (chapter_id,item_pk,catalog_generation,remote_identity,position,source_index,title,word_count,content_status,content_ref,content_version)
            VALUES (?,?,?,?,?,?,?,?,'ready',?,1)''',
            [
              chapter.id,
              committed.itemPk,
              generation,
              chapter.key,
              chapter.index,
              chapter.index,
              chapter.title,
              chapter.wordCount,
              chapter.reference,
            ],
          );
        }
      });
      if (progress != null) await saveProgress(itemId, progress);
      if (bookmarks != null) {
        await _owner._database.customStatement('DELETE FROM bookmarks WHERE item_pk=?', [committed.itemPk]);
        for (final bookmark in bookmarks) {
          await saveBookmark(itemId, bookmark);
        }
      }
      return StoredLibraryItemWriteResult(item: committed, created: existing == null);
    }),
  );

  Future<bool> saveLocalProgress(String itemId, String generation, Map<String, Object?> values) => _owner._withOperation(
    () => _owner._database.transaction(() async {
      final row = await readItem(itemId);
      if (row?.values['active_generation'] != generation || row?.values['origin_kind'] != 'local') return false;
      await saveProgress(itemId, values);
      return true;
    }),
  );

  Future<bool> saveLocalBookmark(String itemId, String generation, Map<String, Object?> values) => _owner._withOperation(
    () => _owner._database.transaction(() async {
      final row = await readItem(itemId);
      if (row?.values['active_generation'] != generation || row?.values['origin_kind'] != 'local') return false;
      await saveBookmark(itemId, values);
      return true;
    }),
  );

  Future<void> updateLocalDetails(String itemId, int revision, String title, String? author, String detailsJson) =>
      _owner._withOperation(() async {
        final changed = await _owner._database.customUpdate(
          '''UPDATE library_items SET title=?,author=?,details_json=?,
        item_revision=item_revision+1,updated_at_utc=? WHERE item_id=? AND item_revision=? AND origin_kind='local' ''',
          variables: [
            Variable.withString(title),
            Variable<String>(author),
            Variable.withString(detailsJson),
            Variable.withInt(_owner._clock().toUtc().millisecondsSinceEpoch),
            Variable.withString(itemId),
            Variable.withInt(revision),
          ],
          updates: const {},
        );
        if (changed != 1) throw const PersistenceConflictError();
      });

  Future<void> replaceLocalBookmarks(String itemId, List<Map<String, Object?>> bookmarks) => _owner._withOperation(() async {
    final item = await readItem(itemId);
    if (item == null) throw const PersistenceNotFoundError();
    await _owner._database.customStatement('DELETE FROM bookmarks WHERE item_pk=?', [item.itemPk]);
    for (final bookmark in bookmarks) {
      await saveBookmark(itemId, bookmark);
    }
  });

  Future<void> retireLocalGenerations(String itemId, String current, String? previous) => _owner._withOperation(() async {
    await _owner._database.customStatement(
      'DELETE FROM catalog_chapters WHERE item_pk=(SELECT item_pk FROM library_items WHERE item_id=?) AND catalog_generation<>? AND catalog_generation<>?',
      [itemId, current, previous ?? current],
    );
  });

  Future<Set<String>> referencedLocalGenerations() => _owner._withOperation(() async {
    final rows = await _select("SELECT DISTINCT catalog_generation FROM catalog_chapters WHERE catalog_generation <> '0'", const []);
    return {for (final row in rows) row['catalog_generation']! as String};
  });

  Future<Set<String>> referencedLocalHashes() => _owner._withOperation(() async {
    final rows = await _select("SELECT raw_sha256,details_json FROM library_items WHERE origin_kind='local'", const []);
    return {
      for (final row in rows) row['raw_sha256']! as String,
      for (final row in rows)
        if ((jsonDecode(row['details_json']! as String) as Map)['local'] case final Map local)
          if (local['coverHash'] case final String hash) hash,
    };
  });
}
