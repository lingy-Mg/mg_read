// GENERATED from tools/content_limits.json by tools/generate_content_limits.mjs. DO NOT EDIT.
/// Shared capacity budgets; values bound allocation and never preallocate memory.
abstract final class ContentLimits {
  static const int inlineBytes = 10485760;
  static const int novelBytes = 10485760;
  static const int novelMetadataBytes = 1048576;
  static const int rpcEnvelopeBytes = 65536;
  static const int catalogItems = 100000;
  static const int mangaPages = 100000;
  static const int labelCharacters = 4096;
  static const int metadataCharacters = 1048576;
  static const int idCharacters = 65536;
  static const int cursorCharacters = 65536;
  static const int resourceTokenCharacters = 262144;
  static const int upstreamUrlCharacters = 65536;
  static const int urlCharacters = 266240;
  static const int httpHeaderBytes = 294912;
  static const int headerValueCharacters = 65536;
  static const int imageBytes = 52428800;
  static const int coverBytes = 52428800;
  static const int hlsBytes = 10485760;
  static const int sourceHtmlBytes = 67108864;
  static const int cacheEntryBytes = 67108864;
  static const int cacheTotalBytes = 1073741824;
  static const int sourceDecodePixels = 100000000;
  static const int novelAttemptSeconds = 90;
  static const int contentTimeoutSeconds = 300;
  static const int readerWaitSeconds = 330;
  static const int localFileBytes = 2147483648;
  static const int localExpandedBytes = 17179869184;
  static const int localEntries = 200000;
  static const int epubContainerBytes = 67108864;
  static const int epubXhtmlBytes = 134217728;
  static const int epubMetadataBytes = 16777216;
  static const int epubResourceBytes = 104857600;
  static const int epubBlocks = 1000000;
  static const int epubDepth = 512;
  static const int epubNodes = 2000000;
  static const int epubTableRows = 100000;
  static const int epubTableColumns = 10000;
  static const int shelfItems = 10000;
  static const int pluginArtifactBytes = 268435456;
  static const int pluginBatchBytes = 2147483648;
  static const int pluginArchiveBytes = 268435456;
  static const int pluginArchiveEntryBytes = 268435456;
  static const int pluginArchiveExpandedBytes = 536870912;
  static const int pluginArchiveEntries = 100000;
}
