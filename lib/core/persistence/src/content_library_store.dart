/// Content Library 专用关系表与强类型 SQL 存储。
///
/// 职责：
/// - 在 metadata 数据库内拥有书架、目录、统一进度和统一书签四张业务表。
/// - 提供精确列投影、追加目录事务与正文引用 CAS，不暴露数据库连接。
/// - 保持所有 SQL 在 PersistenceRecordStore 的后台 Drift executor 上执行。
///
/// 注意：
/// - 只支持全新 schema，不读取或迁移历史 Content Library metadata records。
/// - TEMP staging table 不属于持久 schema，只用于把完整目录一次批量送入 SQLite。
part of 'record_store.dart';

const _createLibraryItemsSql = '''
CREATE TABLE IF NOT EXISTS library_items (
  item_pk INTEGER PRIMARY KEY,
  item_id TEXT NOT NULL UNIQUE CHECK (length(item_id) > 0),
  item_revision INTEGER NOT NULL DEFAULT 1 CHECK (item_revision > 0),
  shelf_state TEXT NOT NULL DEFAULT 'active' CHECK (shelf_state IN ('active', 'retained')),
  visibility TEXT NOT NULL DEFAULT 'normal' CHECK (visibility IN ('normal', 'private')),
  sort_order INTEGER NOT NULL CHECK (sort_order >= 0),
  content_kind TEXT NOT NULL CHECK (content_kind IN ('novel', 'manga', 'audio', 'video')),
  title TEXT NOT NULL CHECK (length(title) > 0),
  author TEXT,
  cover_url TEXT,
  source_name TEXT,
  source_plugin_id TEXT NOT NULL CHECK (length(source_plugin_id) > 0),
  source_plugin_version TEXT NOT NULL CHECK (length(source_plugin_version) > 0),
  remote_item_id TEXT NOT NULL CHECK (length(remote_item_id) > 0),
  source_chapter_count INTEGER CHECK (source_chapter_count IS NULL OR source_chapter_count >= 0),
  catalog_count INTEGER NOT NULL DEFAULT 0 CHECK (catalog_count >= 0),
  catalog_revision INTEGER NOT NULL DEFAULT 0 CHECK (catalog_revision >= 0),
  summary_excerpt TEXT CHECK (summary_excerpt IS NULL OR length(summary_excerpt) <= 240),
  details_json TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(details_json)),
  created_at_utc INTEGER NOT NULL,
  updated_at_utc INTEGER NOT NULL,
  UNIQUE(source_plugin_id, remote_item_id)
)''';

const _createCatalogChaptersSql = '''
CREATE TABLE IF NOT EXISTS catalog_chapters (
  chapter_pk INTEGER PRIMARY KEY,
  chapter_id TEXT NOT NULL UNIQUE CHECK (length(chapter_id) > 0),
  item_pk INTEGER NOT NULL REFERENCES library_items(item_pk) ON DELETE CASCADE,
  remote_identity TEXT NOT NULL CHECK (length(remote_identity) > 0),
  position INTEGER NOT NULL CHECK (position >= 0),
  source_index INTEGER CHECK (source_index IS NULL OR source_index >= 0),
  title TEXT NOT NULL CHECK (length(title) > 0),
  chapter_url TEXT,
  word_count INTEGER CHECK (word_count IS NULL OR word_count >= 0),
  content_status TEXT NOT NULL DEFAULT 'missing' CHECK (content_status IN ('missing', 'ready', 'failed')),
  content_ref TEXT,
  content_version INTEGER NOT NULL DEFAULT 0 CHECK (content_version >= 0),
  extra_json TEXT CHECK (extra_json IS NULL OR json_valid(extra_json)),
  CHECK (
    (content_status = 'ready' AND content_ref IS NOT NULL AND length(content_ref) > 0 AND content_version > 0)
    OR (content_status IN ('missing', 'failed') AND content_ref IS NULL)
  )
)''';

const _createReadingProgressSql = '''
CREATE TABLE IF NOT EXISTS reading_progress (
  item_pk INTEGER PRIMARY KEY REFERENCES library_items(item_pk) ON DELETE CASCADE,
  progress_kind TEXT NOT NULL CHECK (progress_kind IN ('novel', 'manga', 'audio', 'video')),
  chapter_id TEXT,
  chapter_position INTEGER CHECK (chapter_position IS NULL OR chapter_position >= 0),
  paragraph_id TEXT,
  image_id TEXT,
  group_id TEXT,
  episode_id TEXT,
  character_offset INTEGER CHECK (character_offset IS NULL OR character_offset >= 0),
  image_fraction REAL CHECK (image_fraction IS NULL OR (image_fraction >= 0 AND image_fraction <= 1)),
  playback_ms INTEGER CHECK (playback_ms IS NULL OR playback_ms >= 0),
  total_duration_ms INTEGER CHECK (total_duration_ms IS NULL OR total_duration_ms >= 0),
  chapter_fraction REAL CHECK (chapter_fraction IS NULL OR (chapter_fraction >= 0 AND chapter_fraction <= 1)),
  book_fraction REAL CHECK (book_fraction IS NULL OR (book_fraction >= 0 AND book_fraction <= 1)),
  total_reading_seconds INTEGER NOT NULL DEFAULT 0 CHECK (total_reading_seconds >= 0),
  updated_at_utc INTEGER NOT NULL,
  CHECK (total_duration_ms IS NULL OR playback_ms IS NULL OR total_duration_ms = 0 OR playback_ms <= total_duration_ms),
  CHECK (
    (progress_kind = 'novel' AND chapter_id IS NOT NULL AND length(chapter_id) > 0 AND chapter_position IS NOT NULL
      AND paragraph_id IS NOT NULL AND length(paragraph_id) > 0
      AND character_offset IS NOT NULL AND chapter_fraction IS NOT NULL AND book_fraction IS NOT NULL
      AND image_id IS NULL AND image_fraction IS NULL AND group_id IS NULL AND episode_id IS NULL
      AND playback_ms IS NULL AND total_duration_ms IS NULL)
    OR
    (progress_kind = 'manga' AND chapter_id IS NOT NULL AND length(chapter_id) > 0 AND chapter_position IS NOT NULL
      AND image_id IS NOT NULL AND length(image_id) > 0
      AND image_fraction IS NOT NULL AND book_fraction IS NOT NULL AND paragraph_id IS NULL AND character_offset IS NULL
      AND chapter_fraction IS NULL AND group_id IS NULL AND episode_id IS NULL AND playback_ms IS NULL AND total_duration_ms IS NULL)
    OR
    (progress_kind = 'audio' AND chapter_id IS NOT NULL AND length(chapter_id) > 0 AND playback_ms IS NOT NULL
      AND chapter_position IS NULL AND paragraph_id IS NULL AND image_id IS NULL AND group_id IS NULL AND episode_id IS NULL
      AND character_offset IS NULL AND image_fraction IS NULL AND chapter_fraction IS NULL AND book_fraction IS NULL)
    OR
    (progress_kind = 'video' AND group_id IS NOT NULL AND length(group_id) > 0
      AND episode_id IS NOT NULL AND length(episode_id) > 0 AND playback_ms IS NOT NULL AND total_duration_ms IS NOT NULL
      AND chapter_id IS NULL AND chapter_position IS NULL AND paragraph_id IS NULL AND image_id IS NULL
      AND character_offset IS NULL AND image_fraction IS NULL AND chapter_fraction IS NULL AND book_fraction IS NULL)
  )
)''';

const _createBookmarksSql = '''
CREATE TABLE IF NOT EXISTS bookmarks (
  bookmark_pk INTEGER PRIMARY KEY,
  bookmark_id TEXT NOT NULL UNIQUE CHECK (length(bookmark_id) > 0),
  item_pk INTEGER NOT NULL REFERENCES library_items(item_pk) ON DELETE CASCADE,
  bookmark_kind TEXT NOT NULL CHECK (bookmark_kind IN ('novel', 'manga')),
  chapter_id TEXT NOT NULL CHECK (length(chapter_id) > 0),
  paragraph_id TEXT,
  image_id TEXT,
  character_offset INTEGER CHECK (character_offset IS NULL OR character_offset >= 0),
  image_fraction REAL CHECK (image_fraction IS NULL OR (image_fraction >= 0 AND image_fraction <= 1)),
  chapter_title TEXT,
  excerpt TEXT,
  created_at_utc INTEGER NOT NULL,
  CHECK (
    (bookmark_kind = 'novel' AND paragraph_id IS NOT NULL AND length(paragraph_id) > 0
      AND character_offset IS NOT NULL AND image_id IS NULL AND image_fraction IS NULL)
    OR
    (bookmark_kind = 'manga' AND image_id IS NOT NULL AND length(image_id) > 0
      AND image_fraction IS NOT NULL AND paragraph_id IS NULL AND character_offset IS NULL)
  )
)''';

Future<void> _createContentLibrarySchema(_PersistenceDatabase database) async {
  await database.customStatement(_createLibraryItemsSql);
  await database.customStatement(_createCatalogChaptersSql);
  await database.customStatement(_createReadingProgressSql);
  await database.customStatement(_createBookmarksSql);
  await database.customStatement(
    "CREATE INDEX IF NOT EXISTS library_items_active_order ON library_items(visibility, sort_order, item_pk) WHERE shelf_state = 'active'",
  );
  await database.customStatement(
    'CREATE UNIQUE INDEX IF NOT EXISTS catalog_chapters_item_remote ON catalog_chapters(item_pk, remote_identity)',
  );
  await database.customStatement('CREATE UNIQUE INDEX IF NOT EXISTS catalog_chapters_item_position ON catalog_chapters(item_pk, position)');
  await database.customStatement(
    'CREATE INDEX IF NOT EXISTS bookmarks_item_created ON bookmarks(item_pk, created_at_utc DESC, bookmark_pk DESC)',
  );
  await database.customStatement('''
    CREATE TEMP TABLE IF NOT EXISTS catalog_chapter_stage (
      input_order INTEGER PRIMARY KEY,
      chapter_id TEXT NOT NULL,
      remote_identity TEXT NOT NULL UNIQUE,
      source_index INTEGER,
      title TEXT NOT NULL,
      chapter_url TEXT,
      word_count INTEGER,
      extra_json TEXT
    )
  ''');
}

final class StoredLibraryItem {
  const StoredLibraryItem(this.values);
  final Map<String, Object?> values;
  int get itemPk => values['item_pk']! as int;
  String get itemId => values['item_id']! as String;
}

final class StoredLibraryItemWriteResult {
  const StoredLibraryItemWriteResult({required this.item, required this.created});

  final StoredLibraryItem item;
  final bool created;
}

final class StoredShelfItem {
  const StoredShelfItem(this.values);
  final Map<String, Object?> values;
}

final class StoredCatalogChapter {
  const StoredCatalogChapter(this.values);
  final Map<String, Object?> values;
  int get chapterPk => values['chapter_pk']! as int;
}

final class StoredProgress {
  const StoredProgress(this.values);
  final Map<String, Object?> values;
}

final class StoredBookmark {
  const StoredBookmark(this.values);
  final Map<String, Object?> values;
}

final class StoredReaderProjection {
  const StoredReaderProjection(this.values);

  final Map<String, Object?> values;
  StoredLibraryItem get item => StoredLibraryItem(values);
  StoredProgress? get progress => values['progress_kind'] == null ? null : StoredProgress(values);
  StoredCatalogChapter? get chapter {
    if (values['target_chapter_pk'] == null) return null;
    return StoredCatalogChapter(<String, Object?>{
      'chapter_pk': values['target_chapter_pk'],
      'chapter_id': values['target_chapter_id'],
      'item_pk': values['item_pk'],
      'remote_identity': values['target_remote_identity'],
      'position': values['target_position'],
      'source_index': values['target_source_index'],
      'title': values['target_title'],
      'chapter_url': values['target_chapter_url'],
      'word_count': values['target_word_count'],
      'content_status': values['target_content_status'],
      'content_ref': values['target_content_ref'],
      'content_version': values['target_content_version'],
      'content_kind': values['content_kind'],
    });
  }
}

final class ContentLibraryCatalogWrite {
  const ContentLibraryCatalogWrite({
    required this.chapterId,
    required this.remoteIdentity,
    required this.title,
    required this.sourceIndex,
    this.chapterUrl,
    this.wordCount,
    this.extraJson,
  });
  final String chapterId;
  final String remoteIdentity;
  final String title;
  final int sourceIndex;
  final String? chapterUrl;
  final int? wordCount;
  final String? extraJson;
}

final class ContentLibraryMetadataStore {
  ContentLibraryMetadataStore._(this._owner);
  final PersistenceRecordStore _owner;
  int _businessQueryCount = 0;

  int get businessQueryCountForTest => _businessQueryCount;
  void resetBusinessQueryCountForTest() => _businessQueryCount = 0;

  Future<List<Map<String, dynamic>>> _select(String sql, List<Variable<Object>> variables) async {
    _businessQueryCount++;
    final rows = await _owner._database.customSelect(sql, variables: variables).get();
    return <Map<String, dynamic>>[for (final row in rows) row.data];
  }

  Future<StoredLibraryItem?> readItem(String itemId) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _select('SELECT * FROM library_items WHERE item_id = ? LIMIT 1', <Variable<Object>>[Variable.withString(itemId)]);
    return rows.isEmpty ? null : StoredLibraryItem(rows.single);
  });

  Future<StoredLibraryItemWriteResult> putItem({
    required String itemId,
    required String contentKind,
    required String title,
    required String? author,
    required String visibility,
    required String? coverUrl,
    required String? sourceName,
    required String pluginId,
    required String pluginVersion,
    required String remoteItemId,
    required int? sourceChapterCount,
    required String? summaryExcerpt,
    required String detailsJson,
    required int maximumActiveItems,
  }) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final now = _owner._clock().toUtc().millisecondsSinceEpoch;
    return _owner._database.transaction(() async {
      final existing = await _owner._database
          .customSelect(
            'SELECT item_pk, item_id, content_kind FROM library_items WHERE source_plugin_id = ? AND remote_item_id = ? LIMIT 1',
            variables: <Variable<Object>>[Variable.withString(pluginId), Variable.withString(remoteItemId)],
          )
          .get();
      final created = existing.isEmpty;
      if (created) {
        final count = await _owner._database
            .customSelect("SELECT COUNT(*) AS value FROM library_items WHERE shelf_state = 'active'")
            .getSingle();
        if ((count.data['value']! as int) >= maximumActiveItems) {
          throw const PersistenceCapacityError();
        }
        final order = await _owner._database
            .customSelect('SELECT COALESCE(MAX(sort_order), -1) + 1 AS value FROM library_items')
            .getSingle();
        await _owner._database.customStatement(
          '''INSERT INTO library_items (
            item_id, sort_order, content_kind, title, author, visibility, cover_url, source_name,
            source_plugin_id, source_plugin_version, remote_item_id, source_chapter_count,
            summary_excerpt, details_json, created_at_utc, updated_at_utc
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          <Object?>[
            itemId,
            order.data['value']! as int,
            contentKind,
            title,
            author,
            visibility,
            coverUrl,
            sourceName,
            pluginId,
            pluginVersion,
            remoteItemId,
            sourceChapterCount,
            summaryExcerpt,
            detailsJson,
            now,
            now,
          ],
        );
      } else {
        if (existing.single.data['content_kind'] != contentKind) {
          throw const PersistenceConflictError();
        }
        final wasRetained = await _owner._database
            .customSelect(
              'SELECT shelf_state FROM library_items WHERE item_pk = ?',
              variables: <Variable<Object>>[Variable.withInt(existing.single.data['item_pk']! as int)],
            )
            .getSingle();
        if (wasRetained.data['shelf_state'] == 'retained') {
          final count = await _owner._database
              .customSelect("SELECT COUNT(*) AS value FROM library_items WHERE shelf_state = 'active'")
              .getSingle();
          if ((count.data['value']! as int) >= maximumActiveItems) throw const PersistenceCapacityError();
        }
        await _owner._database.customStatement(
          '''UPDATE library_items SET shelf_state = 'active', visibility = ?, content_kind = ?, title = ?, author = ?,
            cover_url = ?, source_name = ?, source_plugin_version = ?, source_chapter_count = ?, summary_excerpt = ?,
            details_json = ?, item_revision = item_revision + 1, updated_at_utc = ? WHERE item_pk = ?''',
          <Object?>[
            visibility,
            contentKind,
            title,
            author,
            coverUrl,
            sourceName,
            pluginVersion,
            sourceChapterCount,
            summaryExcerpt,
            detailsJson,
            now,
            existing.single.data['item_pk']! as int,
          ],
        );
      }
      final rows = await _owner._database
          .customSelect(
            'SELECT * FROM library_items WHERE source_plugin_id = ? AND remote_item_id = ? LIMIT 1',
            variables: <Variable<Object>>[Variable.withString(pluginId), Variable.withString(remoteItemId)],
          )
          .get();
      return StoredLibraryItemWriteResult(item: StoredLibraryItem(rows.single.data), created: created);
    });
  });

  Future<List<StoredShelfItem>> listShelf({required String visibility, required int limit}) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _select(
      '''SELECT i.item_pk, i.item_id, i.content_kind, i.title, i.author, i.cover_url, i.source_name, i.details_json,
        i.source_plugin_id, i.source_plugin_version, i.remote_item_id, i.source_chapter_count,
        i.catalog_count, i.summary_excerpt, p.progress_kind, p.chapter_position, p.book_fraction,
        p.total_reading_seconds, p.updated_at_utc AS progress_updated_at_utc
      FROM library_items i LEFT JOIN reading_progress p ON p.item_pk = i.item_pk
      WHERE i.shelf_state = 'active' AND i.visibility = ?
      ORDER BY i.sort_order, i.item_pk LIMIT ?''',
      <Variable<Object>>[Variable.withString(visibility), Variable.withInt(limit)],
    );
    return List<StoredShelfItem>.unmodifiable(rows.map(StoredShelfItem.new));
  });

  Future<List<StoredLibraryItem>> listItems({String? visibility, int limit = 100}) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _select(
      '''SELECT * FROM library_items WHERE shelf_state = 'active'${visibility == null ? '' : ' AND visibility = ?'}
      ORDER BY sort_order, item_pk LIMIT ?''',
      <Variable<Object>>[if (visibility != null) Variable.withString(visibility), Variable.withInt(limit)],
    );
    return List<StoredLibraryItem>.unmodifiable(rows.map(StoredLibraryItem.new));
  });

  Future<StoredReaderProjection?> openReaderProjection(String itemId, String contentKind) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _select(
      '''SELECT i.*, p.progress_kind, p.chapter_id, p.chapter_position, p.paragraph_id, p.image_id,
        p.group_id, p.episode_id, p.character_offset, p.image_fraction, p.playback_ms,
        p.total_duration_ms, p.chapter_fraction, p.book_fraction, p.total_reading_seconds, p.updated_at_utc,
        c.chapter_pk AS target_chapter_pk, c.chapter_id AS target_chapter_id,
        c.remote_identity AS target_remote_identity, c.position AS target_position,
        c.source_index AS target_source_index, c.title AS target_title, c.chapter_url AS target_chapter_url,
        c.word_count AS target_word_count, c.content_status AS target_content_status,
        c.content_ref AS target_content_ref, c.content_version AS target_content_version
      FROM library_items i
      LEFT JOIN reading_progress p ON p.item_pk = i.item_pk
      LEFT JOIN catalog_chapters c ON c.chapter_pk = COALESCE(
        (SELECT by_id.chapter_pk FROM catalog_chapters by_id
          WHERE by_id.item_pk = i.item_pk AND by_id.remote_identity = p.chapter_id
            AND by_id.position < i.catalog_count LIMIT 1),
        (SELECT by_position.chapter_pk FROM catalog_chapters by_position
          WHERE by_position.item_pk = i.item_pk AND by_position.position = p.chapter_position
            AND by_position.position < i.catalog_count LIMIT 1),
        (SELECT first_chapter.chapter_pk FROM catalog_chapters first_chapter
          WHERE first_chapter.item_pk = i.item_pk AND first_chapter.position = 0
            AND first_chapter.position < i.catalog_count LIMIT 1)
      )
      WHERE i.item_id = ? AND i.content_kind = ? LIMIT 1''',
      <Variable<Object>>[Variable.withString(itemId), Variable.withString(contentKind)],
    );
    return rows.isEmpty ? null : StoredReaderProjection(rows.single);
  });

  Future<void> setVisibility(String itemId, String visibility) => _owner._withOperation(() async {
    _owner._ensureOpen();
    await _owner._database.customStatement(
      'UPDATE library_items SET visibility = ?, item_revision = item_revision + 1, updated_at_utc = ? WHERE item_id = ?',
      <Object?>[visibility, _owner._clock().toUtc().millisecondsSinceEpoch, itemId],
    );
  });

  Future<void> retainItem(String itemId) => _owner._withOperation(() async {
    _owner._ensureOpen();
    await _owner._database.customStatement(
      "UPDATE library_items SET shelf_state = 'retained', item_revision = item_revision + 1, updated_at_utc = ? WHERE item_id = ?",
      <Object?>[_owner._clock().toUtc().millisecondsSinceEpoch, itemId],
    );
  });

  Future<void> deleteItem(String itemId) => _owner._withOperation(() async {
    _owner._ensureOpen();
    await _owner._database.customStatement('DELETE FROM library_items WHERE item_id = ?', <Object?>[itemId]);
  });

  Future<int> appendCatalog({required String itemId, required String contentKind, required List<ContentLibraryCatalogWrite> chapters}) =>
      _owner._withOperation(() async {
        _owner._ensureOpen();
        return _owner._database.transaction(() async {
          await _owner._database.customStatement('DELETE FROM catalog_chapter_stage');
          await _owner._database.batch((batch) {
            for (var index = 0; index < chapters.length; index++) {
              final chapter = chapters[index];
              batch.customStatement(
                '''INSERT INTO catalog_chapter_stage (
              input_order, chapter_id, remote_identity, source_index, title, chapter_url, word_count, extra_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
                <Object?>[
                  index,
                  chapter.chapterId,
                  chapter.remoteIdentity,
                  chapter.sourceIndex,
                  chapter.title,
                  chapter.chapterUrl,
                  chapter.wordCount,
                  chapter.extraJson,
                ],
              );
            }
          });
          final item = await _owner._database
              .customSelect(
                'SELECT item_pk, catalog_count, content_kind FROM library_items WHERE item_id = ? LIMIT 1',
                variables: <Variable<Object>>[Variable.withString(itemId)],
              )
              .getSingleOrNull();
          if (item == null) throw const PersistenceNotFoundError();
          if (item.data['content_kind'] != contentKind) {
            throw StateError('The catalog kind does not match the library item.');
          }
          final itemPk = item.data['item_pk']! as int;
          final base = item.data['catalog_count']! as int;
          await _owner._database.customStatement(
            '''INSERT INTO catalog_chapters (
          chapter_id, item_pk, remote_identity, position, source_index, title, chapter_url, word_count, extra_json
        )
        SELECT s.chapter_id, ?, s.remote_identity,
          ? + ROW_NUMBER() OVER (ORDER BY s.input_order) - 1,
          s.source_index, s.title, s.chapter_url, s.word_count, s.extra_json
        FROM catalog_chapter_stage s
        WHERE NOT EXISTS (
          SELECT 1 FROM catalog_chapters c WHERE c.item_pk = ? AND c.remote_identity = s.remote_identity
        )
        ORDER BY s.input_order
        ON CONFLICT(item_pk, remote_identity) DO NOTHING''',
            <Object?>[itemPk, base, itemPk],
          );
          final changedRow = await _owner._database.customSelect('SELECT changes() AS value').getSingle();
          final inserted = changedRow.data['value']! as int;
          if (inserted > 0) {
            await _owner._database.customStatement(
              '''UPDATE library_items SET catalog_count = catalog_count + ?, catalog_revision = catalog_revision + 1,
            updated_at_utc = ? WHERE item_pk = ?''',
              <Object?>[inserted, _owner._clock().toUtc().millisecondsSinceEpoch, itemPk],
            );
          }
          await _owner._database.customStatement('DELETE FROM catalog_chapter_stage');
          return base + inserted;
        });
      });

  Future<List<StoredCatalogChapter>> listCatalog({
    required String itemId,
    required int upperBound,
    required int afterPosition,
    required int limit,
  }) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _select(
      '''SELECT c.chapter_pk, c.chapter_id, c.item_pk, c.remote_identity, c.position, c.source_index,
        c.title, c.chapter_url, c.word_count, c.content_status, c.content_ref, c.content_version, i.content_kind
      FROM catalog_chapters c JOIN library_items i ON i.item_pk = c.item_pk
      WHERE i.item_id = ? AND c.position > ? AND c.position < ?
      ORDER BY c.position LIMIT ?''',
      <Variable<Object>>[
        Variable.withString(itemId),
        Variable.withInt(afterPosition),
        Variable.withInt(upperBound),
        Variable.withInt(limit),
      ],
    );
    return List<StoredCatalogChapter>.unmodifiable(rows.map(StoredCatalogChapter.new));
  });

  Future<StoredCatalogChapter?> chapterAt(String itemId, int position, int upperBound) => _chapterWhere(
    itemId,
    'c.position = ? AND c.position < ?',
    <Variable<Object>>[Variable.withInt(position), Variable.withInt(upperBound)],
  );

  Future<StoredCatalogChapter?> chapterByRemote(String itemId, String remoteIdentity, int upperBound) => _chapterWhere(
    itemId,
    'c.remote_identity = ? AND c.position < ?',
    <Variable<Object>>[Variable.withString(remoteIdentity), Variable.withInt(upperBound)],
  );

  Future<StoredCatalogChapter?> chapterById(String chapterId) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _select(
      '''SELECT c.chapter_pk, c.chapter_id, c.item_pk, c.remote_identity, c.position, c.source_index,
        c.title, c.chapter_url, c.word_count, c.content_status, c.content_ref, c.content_version,
        i.content_kind, i.item_id
      FROM catalog_chapters c JOIN library_items i ON i.item_pk = c.item_pk
      WHERE c.chapter_id = ? LIMIT 1''',
      <Variable<Object>>[Variable.withString(chapterId)],
    );
    return rows.isEmpty ? null : StoredCatalogChapter(rows.single);
  });

  Future<StoredCatalogChapter?> _chapterWhere(String itemId, String where, List<Variable<Object>> variables) =>
      _owner._withOperation(() async {
        _owner._ensureOpen();
        final rows = await _select(
          '''SELECT c.chapter_pk, c.chapter_id, c.item_pk, c.remote_identity, c.position, c.source_index,
            c.title, c.chapter_url, c.word_count, c.content_status, c.content_ref, c.content_version, i.content_kind
          FROM catalog_chapters c JOIN library_items i ON i.item_pk = c.item_pk
          WHERE i.item_id = ? AND $where LIMIT 1''',
          <Variable<Object>>[Variable.withString(itemId), ...variables],
        );
        return rows.isEmpty ? null : StoredCatalogChapter(rows.single);
      });

  Future<List<StoredCatalogChapter>> chaptersByRemote(String itemId, Set<String> identities, int upperBound) =>
      _owner._withOperation(() async {
        _owner._ensureOpen();
        if (identities.isEmpty) return const <StoredCatalogChapter>[];
        final placeholders = List<String>.filled(identities.length, '?').join(',');
        final rows = await _select(
          '''SELECT c.chapter_pk, c.chapter_id, c.item_pk, c.remote_identity, c.position, c.source_index,
            c.title, c.chapter_url, c.word_count, c.content_status, c.content_ref, c.content_version, i.content_kind
          FROM catalog_chapters c JOIN library_items i ON i.item_pk = c.item_pk
          WHERE i.item_id = ? AND c.position < ? AND c.remote_identity IN ($placeholders)
          ORDER BY c.position''',
          <Variable<Object>>[
            Variable.withString(itemId),
            Variable.withInt(upperBound),
            for (final identity in identities) Variable.withString(identity),
          ],
        );
        return List<StoredCatalogChapter>.unmodifiable(rows.map(StoredCatalogChapter.new));
      });

  Future<bool> attachContent({required int chapterPk, required int expectedVersion, required String contentRef, required int? wordCount}) =>
      _owner._withOperation(() async {
        _owner._ensureOpen();
        final affected = await _owner._database.customUpdate(
          '''UPDATE catalog_chapters SET content_ref = ?, content_version = content_version + 1,
        content_status = 'ready', word_count = COALESCE(?, word_count)
      WHERE chapter_pk = ? AND content_version = ?''',
          variables: <Variable<Object>>[
            Variable.withString(contentRef),
            Variable<int>(wordCount),
            Variable.withInt(chapterPk),
            Variable.withInt(expectedVersion),
          ],
          updates: const <ResultSetImplementation<dynamic, dynamic>>{},
        );
        return affected == 1;
      });

  Future<StoredProgress?> readProgress(String itemId) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _select(
      'SELECT p.* FROM reading_progress p JOIN library_items i ON i.item_pk = p.item_pk WHERE i.item_id = ? LIMIT 1',
      <Variable<Object>>[Variable.withString(itemId)],
    );
    return rows.isEmpty ? null : StoredProgress(rows.single);
  });

  Future<void> saveProgress(String itemId, Map<String, Object?> values) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final kind = values['progress_kind']! as String;
    final affected = await _owner._database.customUpdate(
      '''INSERT INTO reading_progress (
        item_pk, progress_kind, chapter_id, chapter_position, paragraph_id, image_id, group_id, episode_id,
        character_offset, image_fraction, playback_ms, total_duration_ms, chapter_fraction, book_fraction,
        total_reading_seconds, updated_at_utc
      ) SELECT i.item_pk, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
        FROM library_items i WHERE i.item_id = ? AND i.content_kind = ?
      ON CONFLICT(item_pk) DO UPDATE SET
        progress_kind = excluded.progress_kind, chapter_id = excluded.chapter_id,
        chapter_position = excluded.chapter_position, paragraph_id = excluded.paragraph_id,
        image_id = excluded.image_id, group_id = excluded.group_id, episode_id = excluded.episode_id,
        character_offset = excluded.character_offset, image_fraction = excluded.image_fraction,
        playback_ms = excluded.playback_ms, total_duration_ms = excluded.total_duration_ms,
        chapter_fraction = excluded.chapter_fraction, book_fraction = excluded.book_fraction,
        total_reading_seconds = excluded.total_reading_seconds, updated_at_utc = excluded.updated_at_utc''',
      variables: <Variable<Object>>[
        Variable.withString(kind),
        Variable<Object>(values['chapter_id']),
        Variable<Object>(values['chapter_position']),
        Variable<Object>(values['paragraph_id']),
        Variable<Object>(values['image_id']),
        Variable<Object>(values['group_id']),
        Variable<Object>(values['episode_id']),
        Variable<Object>(values['character_offset']),
        Variable<Object>(values['image_fraction']),
        Variable<Object>(values['playback_ms']),
        Variable<Object>(values['total_duration_ms']),
        Variable<Object>(values['chapter_fraction']),
        Variable<Object>(values['book_fraction']),
        Variable.withInt(values['total_reading_seconds'] as int? ?? 0),
        Variable.withInt(values['updated_at_utc']! as int),
        Variable.withString(itemId),
        Variable.withString(kind),
      ],
      updates: const <ResultSetImplementation<dynamic, dynamic>>{},
    );
    if (affected != 1) throw const PersistenceNotFoundError();
  });

  Future<List<StoredProgress>> readProgressMany(Iterable<String> itemIds) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final ids = itemIds.toSet();
    if (ids.isEmpty) return const <StoredProgress>[];
    final placeholders = List<String>.filled(ids.length, '?').join(',');
    final rows = await _select(
      '''SELECT p.*, i.item_id FROM reading_progress p JOIN library_items i ON i.item_pk = p.item_pk
      WHERE i.item_id IN ($placeholders)''',
      <Variable<Object>>[for (final id in ids) Variable.withString(id)],
    );
    return List<StoredProgress>.unmodifiable(rows.map(StoredProgress.new));
  });

  Future<List<StoredBookmark>> listBookmarks(String itemId, String kind) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _select(
      '''SELECT b.* FROM bookmarks b JOIN library_items i ON i.item_pk = b.item_pk
      WHERE i.item_id = ? AND b.bookmark_kind = ? ORDER BY b.created_at_utc DESC, b.bookmark_pk DESC''',
      <Variable<Object>>[Variable.withString(itemId), Variable.withString(kind)],
    );
    return List<StoredBookmark>.unmodifiable(rows.map(StoredBookmark.new));
  });

  Future<void> saveBookmark(String itemId, Map<String, Object?> values) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final kind = values['bookmark_kind']! as String;
    final affected = await _owner._database.customUpdate(
      '''INSERT INTO bookmarks (
        bookmark_id, item_pk, bookmark_kind, chapter_id, paragraph_id, image_id, character_offset,
        image_fraction, chapter_title, excerpt, created_at_utc
      ) SELECT ?, i.item_pk, ?, ?, ?, ?, ?, ?, ?, ?, ?
        FROM library_items i WHERE i.item_id = ? AND i.content_kind = ?
      ON CONFLICT(bookmark_id) DO UPDATE SET chapter_id = excluded.chapter_id, paragraph_id = excluded.paragraph_id,
        image_id = excluded.image_id, character_offset = excluded.character_offset, image_fraction = excluded.image_fraction,
        chapter_title = excluded.chapter_title, excerpt = excluded.excerpt, created_at_utc = excluded.created_at_utc
      WHERE bookmarks.item_pk = excluded.item_pk''',
      variables: <Variable<Object>>[
        Variable.withString(values['bookmark_id']! as String),
        Variable.withString(kind),
        Variable.withString(values['chapter_id']! as String),
        Variable<Object>(values['paragraph_id']),
        Variable<Object>(values['image_id']),
        Variable<Object>(values['character_offset']),
        Variable<Object>(values['image_fraction']),
        Variable<Object>(values['chapter_title']),
        Variable<Object>(values['excerpt']),
        Variable.withInt(values['created_at_utc']! as int),
        Variable.withString(itemId),
        Variable.withString(kind),
      ],
      updates: const <ResultSetImplementation<dynamic, dynamic>>{},
    );
    if (affected != 1) throw const PersistenceConflictError();
  });

  Future<void> deleteBookmark(String itemId, String bookmarkId) => _owner._withOperation(() async {
    _owner._ensureOpen();
    await _owner._database.customStatement(
      '''DELETE FROM bookmarks WHERE bookmark_id = ? AND item_pk =
        (SELECT item_pk FROM library_items WHERE item_id = ? LIMIT 1)''',
      <Object?>[bookmarkId, itemId],
    );
  });

  Future<Set<String>> referencedContentObjects() => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _select("SELECT content_ref FROM catalog_chapters WHERE content_ref IS NOT NULL AND content_ref <> ''", const []);
    return <String>{for (final row in rows) row['content_ref']! as String};
  });

  Future<({int count, int revision})?> catalogStateForTest(String itemId) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final row = await _owner._database
        .customSelect(
          'SELECT catalog_count, catalog_revision FROM library_items WHERE item_id = ? LIMIT 1',
          variables: <Variable<Object>>[Variable.withString(itemId)],
        )
        .getSingleOrNull();
    return row == null ? null : (count: row.data['catalog_count']! as int, revision: row.data['catalog_revision']! as int);
  });

  Future<List<String>> persistentTableNamesForTest() => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _owner._database
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        .get();
    return <String>[for (final row in rows) row.data['name']! as String];
  });

  Future<Map<String, List<String>>> hotIndexPlansForTest(String itemId) async => <String, List<String>>{
    'shelf': await explain(
      "SELECT item_pk FROM library_items WHERE shelf_state = 'active' AND visibility = ? ORDER BY sort_order, item_pk LIMIT ?",
      <Variable<Object>>[Variable.withString('normal'), Variable.withInt(100)],
    ),
    'position': await explain(
      'SELECT chapter_pk FROM catalog_chapters WHERE item_pk = (SELECT item_pk FROM library_items WHERE item_id = ?) AND position > ? AND position < ? ORDER BY position LIMIT ?',
      <Variable<Object>>[Variable.withString(itemId), Variable.withInt(-1), Variable.withInt(100), Variable.withInt(100)],
    ),
    'remote': await explain(
      'SELECT chapter_pk FROM catalog_chapters WHERE item_pk = (SELECT item_pk FROM library_items WHERE item_id = ?) AND remote_identity = ? LIMIT 1',
      <Variable<Object>>[Variable.withString(itemId), Variable.withString('chapter-0')],
    ),
  };

  Future<List<String>> explain(String sql, List<Variable<Object>> variables) => _owner._withOperation(() async {
    _owner._ensureOpen();
    final rows = await _owner._database.customSelect('EXPLAIN QUERY PLAN $sql', variables: variables).get();
    return <String>[for (final row in rows) row.data['detail']! as String];
  });
}

final class PersistenceCapacityError implements Exception {
  const PersistenceCapacityError();
}

final class PersistenceNotFoundError implements Exception {
  const PersistenceNotFoundError();
}
