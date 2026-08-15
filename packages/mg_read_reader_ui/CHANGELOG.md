## 0.4.0

* Added source-kind and optional chapter availability, word-count, and read-state metadata without breaking existing constant constructors.
* Added an optional host-owned chapter-state capability. Existing `loadChapterContent` remains the only entry path for text content and may await host download/cache work; the plugin never downloads chapters directly.
* Added host-owned external font catalog, install, cache-byte, preview-byte, and removal contracts plus the nullable `TextReaderPreferences.customFontId` preference.
* Added independent `Comic*` models, data source, state store, observer, controller, snapshot, preferences, semantic progress, bookmarks, catalog, image metadata, and progressive image-byte contracts. Comic reading is vertical-only and does not reuse text position or pagination models.
* Added `ReaderCommentTarget.comicImage` while preserving existing book, chapter, and paragraph constructors.
* Added development and UI design specifications under `docs/`.

Migration notes:

* Hosts that serialize `TextReaderPreferences` should persist `customFontId` as nullable and treat missing or blank legacy values as null.
* Existing `ReaderBookInfo` and `ReaderChapterInfo` calls remain source compatible because every new parameter is optional with a safe default. Exhaustive switches must handle the new source and availability enums.
* Font removal only deletes host-owned cache state. Fonts already registered with the Flutter engine remain process-resident until restart.

## 0.3.0

* Rebuilt the reader settings as a compact, reader-owned surface with seven color palettes, six original backgrounds, and expanded typography and spacing controls.
* Added simulated page-curl and cover transitions alongside slide, vertical scroll, and no-animation modes.
* Added session-scoped horizontal and vertical automatic reading with controller commands and observable running state.
* Added an optional read-only comment feed for book, chapter, and paragraph targets, including batched book/chapter summaries, sorting, cursor pagination, and reader-owned loading, empty, error, and retry UI. Paragraph tails use a compact fixed-height comment bubble with the count inside (including zero); tapping opens the read-only list, asynchronous count updates never reflow the text, and paragraph bubbles do not show comment-body previews.
* Deprecated `ReaderExtensions.comments` and `ReaderCommentsCapability`; hosts should register `ReaderExtensions.commentFeed` instead.

Migration notes:

* `ReaderThemePreset` and `ReaderPageAnimation` gained values at the end of their enums, preserving the indices of existing values. Host code with exhaustive switches must add the new cases.
* Hosts that serialize `TextReaderPreferences` must persist `background` and the three comment-visibility fields, using the constructor defaults when older records omit them.
* Automatic reading is session state exposed through `TextReaderController` and `TextReaderSnapshot.isAutoReading`; it must not be persisted as a preference.
* `ReaderCommentTarget` now uses value equality instead of identity equality so equivalent targets work as summary-map keys. Hosts that intentionally stored duplicate equivalent targets as separate `Set` or `Map` entries must migrate those collections.

## 0.2.0

* Added a default book information preview at chapter index `-1`.
* Added direct asynchronous chapter lookup for whole-book progress jumps.
* Limited content caching to the current and next chapter; previous chapters reload on demand.
* Added explicit end-of-book feedback and touch/mouse page dragging.
* Hidden screen-awake settings on unsupported platforms.
* Removed automated test and Golden assets in favor of static syntax checks and manual example validation.

## 0.1.0

* Rebuilt the repository as an Android and Windows Flutter plugin.
* Added asynchronous text reader contracts, semantic progress, bookmarks, and preferences.
* Added horizontal pagination, vertical scrolling, catalog and settings UI.
* Added reference-counted native screen-awake support and a complete example app.
