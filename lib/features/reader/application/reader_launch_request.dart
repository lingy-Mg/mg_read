import 'package:novel_reader_ui/novel_reader_ui.dart';

/// Optional app-owned lifecycle for reader data sources that hold session
/// resources such as reusable HTTP clients.
abstract interface class DisposableReaderDataSource {
  /// Releases resources owned by this reader session.
  ///
  /// Implementations must be idempotent and must not close dependencies that
  /// were supplied by the caller without an explicit ownership transfer.
  Future<void> dispose();
}

/// Stable preparation path categories used by bounded performance diagnostics.
enum ReaderLaunchPreparationKind {
  memory('memory'),
  persistent('persistent'),
  network('network');

  const ReaderLaunchPreparationKind(this.wireValue);

  final String wireValue;
}

/// Immutable host-owned inputs common to every reader session.
sealed class ReaderLaunchRequest {
  const ReaderLaunchRequest._({
    required this.bookId,
    this.entryCoverBytes,
    this.estimatedWarmBytes = 0,
    this.preparationKind = ReaderLaunchPreparationKind.persistent,
    this.networkPreparationElapsed = Duration.zero,
  });

  /// Stable identifier owned by the main application.
  final String bookId;

  /// Cover bytes already available in the host before the reader route opens.
  /// The entry transition and reader detail render this local payload and
  /// never fetch its source URL again.
  final List<int>? entryCoverBytes;

  /// Bounded estimate used only by the process-local shelf warm LRU.
  final int estimatedWarmBytes;

  /// Whether the target body came from memory, durable local data, or network.
  final ReaderLaunchPreparationKind preparationKind;

  /// Network-only preparation duration; always zero for local paths.
  final Duration networkPreparationElapsed;
}

/// Typed launch inputs for a text reader session.
final class NovelReaderLaunchRequest extends ReaderLaunchRequest {
  const NovelReaderLaunchRequest({
    required super.bookId,
    required this.dataSource,
    required this.stateStore,
    this.seed,
    super.entryCoverBytes,
    this.chapterPreloadCount = 1,
    this.observer,
    this.controller,
    this.extensions = const ReaderExtensions(),
    super.estimatedWarmBytes,
    super.preparationKind,
    super.networkPreparationElapsed,
  }) : assert(chapterPreloadCount >= 0 && chapterPreloadCount <= 5),
       super._();

  final TextReaderDataSource dataSource;
  final TextReaderStateStore stateStore;
  final ReaderSessionSeed? seed;

  /// Number of following novel chapters the reader may load speculatively.
  final int chapterPreloadCount;

  final ReaderObserver? observer;
  final TextReaderController? controller;
  final ReaderExtensions extensions;

  /// Rebinds route-lifetime text-reader callbacks without rebuilding data.
  NovelReaderLaunchRequest withObserver(ReaderObserver? observer) => NovelReaderLaunchRequest(
    bookId: bookId,
    dataSource: dataSource,
    stateStore: stateStore,
    seed: seed,
    entryCoverBytes: entryCoverBytes,
    chapterPreloadCount: chapterPreloadCount,
    observer: observer,
    controller: controller,
    extensions: extensions,
    estimatedWarmBytes: estimatedWarmBytes,
    preparationKind: preparationKind,
    networkPreparationElapsed: networkPreparationElapsed,
  );

  /// Adds bytes resolved by an app-owned cache without changing the session.
  NovelReaderLaunchRequest withEntryCoverBytes(List<int>? bytes) => NovelReaderLaunchRequest(
    bookId: bookId,
    dataSource: dataSource,
    stateStore: stateStore,
    seed: seed,
    entryCoverBytes: bytes,
    chapterPreloadCount: chapterPreloadCount,
    observer: observer,
    controller: controller,
    extensions: extensions,
    estimatedWarmBytes: estimatedWarmBytes,
    preparationKind: preparationKind,
    networkPreparationElapsed: networkPreparationElapsed,
  );
}

/// Typed launch inputs for a comic reader session.
final class ComicReaderLaunchRequest extends ReaderLaunchRequest {
  const ComicReaderLaunchRequest({
    required super.bookId,
    required this.dataSource,
    required this.stateStore,
    super.entryCoverBytes,
    this.chapterPreloadCount = 1,
    this.observer,
    this.controller,
    this.commentFeed,
    this.bookRefreshCapability,
    super.estimatedWarmBytes,
    super.preparationKind,
    super.networkPreparationElapsed,
  }) : assert(chapterPreloadCount >= 0 && chapterPreloadCount <= 5),
       super._();

  final ComicReaderDataSource dataSource;
  final ComicReaderStateStore stateStore;

  /// Number of following comic chapters the reader may cache speculatively.
  final int chapterPreloadCount;

  final ComicReaderObserver? observer;
  final ComicReaderController? controller;
  final ReaderCommentFeed? commentFeed;
  final ReaderBookRefreshCapability? bookRefreshCapability;

  /// Rebinds route-lifetime comic-reader callbacks without rebuilding data.
  ComicReaderLaunchRequest withObserver(ComicReaderObserver? observer) => ComicReaderLaunchRequest(
    bookId: bookId,
    dataSource: dataSource,
    stateStore: stateStore,
    entryCoverBytes: entryCoverBytes,
    chapterPreloadCount: chapterPreloadCount,
    observer: observer,
    controller: controller,
    commentFeed: commentFeed,
    bookRefreshCapability: bookRefreshCapability,
    estimatedWarmBytes: estimatedWarmBytes,
    preparationKind: preparationKind,
    networkPreparationElapsed: networkPreparationElapsed,
  );
}
