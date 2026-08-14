/// Strongly typed, app-owned Content Library facade. UI never sees persistence
/// envelopes, dynamic plugin JSON, database paths, or file-system paths.
library;

export 'src/content_library.dart' hide IngestCatalogEntry, IngestMangaPage;
export 'src/models.dart'
    hide ContentLibraryIngest, JsonObjectFrozen, freezeInternalJson;
