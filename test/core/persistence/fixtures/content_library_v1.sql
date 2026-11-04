
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
);

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
);

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
);

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
);
