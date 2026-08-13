import 'package:novel_reader_ui/novel_reader_ui.dart';

/// Immutable host-owned inputs required to open one text-reader session.
///
/// Create this request only after the application has resolved the book's
/// stable ID, content data source, and user-specific state store.
class ReaderLaunchRequest {
  /// Creates a request for the reader plugin's public [TextReaderView].
  const ReaderLaunchRequest({
    required this.bookId,
    required this.dataSource,
    required this.stateStore,
    this.observer,
    this.controller,
    this.extensions = const ReaderExtensions(),
  });

  /// Stable identifier owned by the main application.
  final String bookId;

  /// Main-application adapter that supplies book and chapter content.
  final TextReaderDataSource dataSource;

  /// Main-application adapter that persists preferences, progress and marks.
  final TextReaderStateStore stateStore;

  /// Optional host notification sink, including the request to leave reader.
  final ReaderObserver? observer;

  /// Optional imperative controller retained by the host feature.
  final TextReaderController? controller;

  /// Optional independently registered reader capabilities.
  final ReaderExtensions extensions;
}
