import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';

/// Supplies book metadata, catalog pages, and chapter content asynchronously.
abstract interface class TextReaderDataSource {
  /// Loads lightweight metadata for [bookId].
  Future<ReaderBookInfo> loadBookInfo(String bookId);

  /// Loads one cursor-based catalog page for [bookId].
  ///
  /// [cursor] is the opaque continuation token returned by the previous page.
  /// [pageSize] is a request hint and defaults to 100. Returned chapter IDs
  /// and indexes must remain unique across pages, [ChapterCatalogPage.total]
  /// must remain stable, and a page with more data must advance its cursor.
  Future<ChapterCatalogPage> loadChapterCatalog(
    String bookId, {
    String? cursor,
    int pageSize = 100,
  });

  /// Resolves one chapter without scanning catalog pages from the beginning.
  ///
  /// [index] is zero-based and must match [ReaderChapterInfo.index] in the
  /// returned value. This is used for whole-book progress jumps and adjacent
  /// chapter navigation.
  Future<ReaderChapterInfo> loadChapterAtIndex(String bookId, int index);

  /// Loads the complete plain-text content for [chapterId] in [bookId].
  ///
  /// For a remote chapter that is not downloaded, this future is the host's
  /// opportunity to download and cache it before returning. The plugin never
  /// performs network or persistent-cache I/O itself.
  Future<TextChapterContent> loadChapterContent(
    String bookId,
    String chapterId,
  );
}

/// Optional host capability for refreshing mutable text chapter state.
abstract interface class ReaderChapterStateCapability {
  /// Loads current states for the requested stable [chapterIds].
  ///
  /// The returned map may omit unknown chapters. Every key must equal its
  /// value's [ReaderChapterState.chapterId]. Network and cache access belong
  /// entirely to the host.
  Future<Map<String, ReaderChapterState>> loadChapterStates(
    String bookId,
    List<String> chapterIds,
  );

  /// Marks [chapterId] as read in host-owned state.
  ///
  /// This is a semantic notification and must be safe to repeat.
  Future<void> markRead(String bookId, String chapterId);
}

/// Starts one host-owned persistent chapter-cache task.
///
/// The reader only collects bounded user intent. Networking, scheduling,
/// persistence, progress presentation, cancellation, and retries remain owned
/// by the host application.
abstract interface class ReaderChapterCacheCapability {
  /// Starts caching chapters for [bookId] with the requested limits.
  Future<void> startCaching(String bookId, ReaderChapterCacheRequest request);
}

@immutable
/// Immutable user-selected limits for one chapter-cache task.
class ReaderChapterCacheRequest {
  /// Creates a validated host cache request.
  const ReaderChapterCacheRequest({
    required this.chapterCount,
    required this.concurrency,
    required this.delay,
  }) : assert(chapterCount >= 0),
       assert(concurrency > 0);

  /// Number of chapters to cache from the beginning of the catalog.
  final int chapterCount;

  /// Maximum number of chapter requests allowed to run at once.
  final int concurrency;

  /// Delay applied by each worker before it starts another chapter.
  final Duration delay;
}

/// Optional host repository for external reader fonts.
///
/// The plugin never opens descriptor URLs. Implementations own networking,
/// licensing, integrity checks, persistent files, and cache eviction.
abstract interface class ReaderFontRepository {
  /// Loads the descriptors available to the current user and session.
  Future<List<ReaderFontDescriptor>> loadCatalog();

  /// Returns cached font bytes, or null when this font is not installed.
  ///
  /// After [install] completes, every weight declared by the descriptor must
  /// be available through this method. Returned lists may be copied or retained
  /// by the reader and must not be mutated by the repository afterward.
  Future<Uint8List?> loadCachedFontBytes(
    String fontId, {
    String? version,
    int? weight,
  });

  /// Returns cached preview-image bytes, or null when unavailable.
  Future<Uint8List?> loadCachedPreviewBytes(String fontId, {String? version});

  /// Performs any host-owned download, validation, and persistent install.
  Future<void> install(ReaderFontDescriptor descriptor);

  /// Removes host-owned cached files and hides the installed entry.
  ///
  /// Flutter engine fonts already registered in the current process cannot be
  /// unloaded; removing files affects future loads, not existing engine state.
  Future<void> remove(String fontId);
}

/// Persists user-specific reader state without constraining the host database.
abstract interface class TextReaderStateStore {
  /// Loads the last semantic progress for [bookId], or null when none exists.
  Future<ReaderProgress?> loadProgress(String bookId);

  /// Persists the latest semantic [progress] for [bookId].
  Future<void> saveProgress(String bookId, ReaderProgress progress);

  /// Loads reader-owned preferences, or null when none have been saved.
  Future<TextReaderPreferences?> loadPreferences();

  /// Persists reader-owned [preferences] without changing their values.
  Future<void> savePreferences(TextReaderPreferences preferences);

  /// Loads all bookmarks currently available for [bookId].
  Future<List<ReaderBookmark>> loadBookmarks(String bookId);

  /// Persists a reader-generated [bookmark].
  Future<void> addBookmark(ReaderBookmark bookmark);

  /// Removes [bookmarkId] from [bookId] when it exists.
  Future<void> removeBookmark(String bookId, String bookmarkId);
}

/// Optional host notifications for reader session and lifecycle events.
class ReaderObserver {
  /// Creates an observer whose callbacks are no-ops by default.
  const ReaderObserver();

  /// Called after a reading session for [bookId] successfully starts.
  FutureOr<void> onSessionStarted(String bookId) {}

  /// Called as the session ends with its latest semantic [progress].
  FutureOr<void> onSessionEnded(String bookId, ReaderProgress? progress) {}

  /// Called once for each normalized lifecycle [state] transition.
  FutureOr<void> onLifecycleChanged(
    ReaderLifecycleState state,
    ReaderProgress? progress,
  ) {}

  /// Called after the reader commits a change to [chapter].
  FutureOr<void> onChapterChanged(ReaderChapterInfo chapter) {}

  /// Called for a recoverable [failure] that did not crash the reader.
  FutureOr<void> onFailure(ReaderFailure failure) {}

  /// Called exactly once after the first real text frame is presented.
  ///
  /// The notification contains only semantic position and layout metadata;
  /// page numbers and pixel offsets are intentionally not exposed.
  FutureOr<void> onFirstContentPresented(
    ReaderFirstContentPresentation presentation,
  ) {}

  /// Reports bounded adjacent layout and chapter-transition performance.
  ///
  /// Events contain only stable phase/outcome, counts and duration. They do
  /// not expose book, chapter, URL, paragraph text, or raw exceptions.
  FutureOr<void> onChapterPerformance(ReaderChapterPerformanceEvent event) {}

  /// Requests that the host close or otherwise leave the reader.
  ///
  /// The reader never pops the host navigator itself.
  FutureOr<void> onExitRequested(ReaderProgress? progress) {}
}

/// The reader performance operation represented by [ReaderChapterPerformanceEvent].
enum ReaderChapterPerformancePhase {
  /// Incremental idle pagination for one adjacent chapter.
  adjacentPreparation,

  /// A user-visible transition across a chapter boundary.
  chapterTransition,
}

/// Terminal state of a reader performance operation.
enum ReaderChapterPerformanceOutcome {
  /// The operation has started and has no terminal result yet.
  started,

  /// The operation completed successfully.
  success,

  /// The operation failed without exposing raw exception data.
  error,

  /// The operation was invalidated before completion.
  cancelled,
}

/// How work for a chapter performance operation was prepared.
enum ReaderChapterPreparationKind {
  /// Work has started but its eventual preparation path is not known yet.
  pending,

  /// The adjacent chapter is being paginated by bounded idle tasks.
  adjacentIdle,

  /// The visible chapter must be paginated on the foreground path.
  foregroundLayout,

  /// A complete compatible layout was consumed from the bounded cache.
  cachedLayout,
}

/// Immutable, bounded timing notification for adjacent preparation or a turn.
@immutable
class ReaderChapterPerformanceEvent {
  /// Creates an immutable bounded performance event.
  const ReaderChapterPerformanceEvent({
    required this.phase,
    required this.outcome,
    required this.operationId,
    this.duration = Duration.zero,
    this.pageCount = 0,
    this.paragraphCount = 0,
    this.preparationKind = ReaderChapterPreparationKind.pending,
    this.cacheHit = false,
  });

  /// Creates the unique start event for an operation.
  const ReaderChapterPerformanceEvent.started({
    required ReaderChapterPerformancePhase phase,
    required int operationId,
    int paragraphCount = 0,
    ReaderChapterPreparationKind preparationKind =
        ReaderChapterPreparationKind.pending,
  }) : this(
         phase: phase,
         outcome: ReaderChapterPerformanceOutcome.started,
         operationId: operationId,
         paragraphCount: paragraphCount,
         preparationKind: preparationKind,
       );

  /// Creates the successful terminal event for an operation.
  const ReaderChapterPerformanceEvent.success({
    required ReaderChapterPerformancePhase phase,
    required int operationId,
    Duration duration = Duration.zero,
    int pageCount = 0,
    int paragraphCount = 0,
    ReaderChapterPreparationKind preparationKind =
        ReaderChapterPreparationKind.foregroundLayout,
    bool cacheHit = false,
  }) : this(
         phase: phase,
         outcome: ReaderChapterPerformanceOutcome.success,
         operationId: operationId,
         duration: duration,
         pageCount: pageCount,
         paragraphCount: paragraphCount,
         preparationKind: preparationKind,
         cacheHit: cacheHit,
       );

  /// Creates the failed terminal event for an operation.
  const ReaderChapterPerformanceEvent.error({
    required ReaderChapterPerformancePhase phase,
    required int operationId,
    Duration duration = Duration.zero,
    int paragraphCount = 0,
    ReaderChapterPreparationKind preparationKind =
        ReaderChapterPreparationKind.foregroundLayout,
    bool cacheHit = false,
  }) : this(
         phase: phase,
         outcome: ReaderChapterPerformanceOutcome.error,
         operationId: operationId,
         duration: duration,
         paragraphCount: paragraphCount,
         preparationKind: preparationKind,
         cacheHit: cacheHit,
       );

  /// Creates the cancelled terminal event for an operation.
  const ReaderChapterPerformanceEvent.cancelled({
    required ReaderChapterPerformancePhase phase,
    required int operationId,
    Duration duration = Duration.zero,
    ReaderChapterPreparationKind preparationKind =
        ReaderChapterPreparationKind.foregroundLayout,
    bool cacheHit = false,
  }) : this(
         phase: phase,
         outcome: ReaderChapterPerformanceOutcome.cancelled,
         operationId: operationId,
         duration: duration,
         preparationKind: preparationKind,
         cacheHit: cacheHit,
       );

  /// Whether this operation prepares an adjacent layout or changes chapter.
  final ReaderChapterPerformancePhase phase;

  /// Start or the unique terminal outcome of the operation.
  final ReaderChapterPerformanceOutcome outcome;

  /// Session-local correlation identifier; it contains no content identity.
  final int operationId;

  /// Bounded elapsed time reported by a terminal event.
  final Duration duration;

  /// Number of complete pages produced or consumed, when known.
  final int pageCount;

  /// Number of paragraphs considered, when known.
  final int paragraphCount;

  /// Preparation path used by the operation.
  final ReaderChapterPreparationKind preparationKind;

  /// Whether a compatible complete layout was consumed from the cache.
  final bool cacheHit;
}

/// How the first visible text page became available.
enum ReaderPaginationPreparation { firstPage, cachedFirstPage }

/// Immutable metadata for the first real text frame of a reader session.
@immutable
class ReaderFirstContentPresentation {
  const ReaderFirstContentPresentation({
    required this.anchor,
    required this.paginationPreparation,
    required this.layoutDuration,
  });

  /// Semantic position represented by the first visible content frame.
  final ReaderProgress? anchor;

  /// Whether the first page was measured or came from the bounded cache.
  final ReaderPaginationPreparation paginationPreparation;

  /// Time spent synchronously preparing the first visible page.
  final Duration layoutDuration;

  /// Alias for callers that prefer the explicit semantic terminology.
  ReaderProgress? get semanticAnchor => anchor;

  /// Alias for callers that use readiness terminology.
  ReaderPaginationPreparation get paginationReadiness => paginationPreparation;

  /// Duration in milliseconds for telemetry-oriented callers.
  int get layoutDurationMilliseconds => layoutDuration.inMilliseconds;
}

/// Backward-compatible descriptive alias for first-frame metadata.
typedef ReaderFirstContentPresented = ReaderFirstContentPresentation;

@immutable
/// Optional capabilities that can be registered without changing core data APIs.
class ReaderExtensions {
  /// Creates a set of independently optional reader extensions.
  const ReaderExtensions({
    this.commentFeed,
    this.chapterStateCapability,
    this.chapterCacheCapability,
    this.fontRepository,
    @Deprecated('Use commentFeed for the reader-owned read-only comment UI.')
    this.comments,
  });

  /// Optional read-only comment data source used by reader-owned comment UI.
  final ReaderCommentFeed? commentFeed;

  /// Optional source of mutable download/read state for text chapters.
  final ReaderChapterStateCapability? chapterStateCapability;

  /// Optional host-owned persistent chapter-cache task entry point.
  final ReaderChapterCacheCapability? chapterCacheCapability;

  /// Optional host-owned catalog, installer, and cache for external fonts.
  final ReaderFontRepository? fontRepository;

  /// Legacy host-owned comment entry point.
  @Deprecated('Use commentFeed for the reader-owned read-only comment UI.')
  final ReaderCommentsCapability? comments;
}

/// Legacy host-owned entry point for an external comments experience.
@Deprecated('Use ReaderCommentFeed for reader-owned read-only comment UI.')
abstract interface class ReaderCommentsCapability {
  /// Opens the host-owned experience for [target].
  Future<void> open(ReaderCommentTarget target);
}

/// Supplies optional, read-only comments independently from book content APIs.
///
/// Implementations must not mutate comment state in response to these methods.
/// Errors may be thrown and are converted by the reader into recoverable
/// failures without interrupting reading.
abstract interface class ReaderCommentFeed {
  /// Loads compact summaries for multiple [targets] in one host request.
  ///
  /// The returned map may omit targets that have no comments. Each summary's
  /// [ReaderCommentSummary.topComments] should contain at most [previewLimit]
  /// entries. [previewLimit] defaults to 3 and must be treated as non-negative.
  /// Every map key must equal its summary's [ReaderCommentSummary.target], and
  /// every preview comment must match that same target.
  Future<Map<ReaderCommentTarget, ReaderCommentSummary>> loadSummaries(
    List<ReaderCommentTarget> targets, {
    int previewLimit = 3,
  });

  /// Loads one cursor-based page of comments for [target].
  ///
  /// [sort] defaults to [ReaderCommentSort.hot]. [cursor] is a host-owned
  /// opaque continuation token. [pageSize] defaults to 20 and is a request
  /// hint; the host may return fewer entries.
  ///
  /// Every returned [ReaderComment.target] must equal [target], totals must be
  /// non-negative, and identifiers must be stable and unique within a page.
  /// When [ReaderCommentPage.hasMore] is true, its next cursor must be non-empty
  /// and different from [cursor]; when false, the next cursor must be null.
  Future<ReaderCommentPage> loadComments(
    ReaderCommentTarget target, {
    ReaderCommentSort sort = ReaderCommentSort.hot,
    String? cursor,
    int pageSize = 20,
  });
}
