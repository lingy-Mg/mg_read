import 'dart:async';
import 'dart:collection';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../../api/contracts.dart';
import '../../api/comic_contracts.dart';
import '../../api/comic_controller.dart';
import '../../api/comic_models.dart';
import '../../api/models.dart';
import '../../platform/reader_platform.dart';
import '../../platform/screen_awake_coordinator.dart';
import '../comments/reader_comment_strings.dart';
import '../comments/reader_comment_widgets.dart';
import '../reader_theme.dart';
import 'comic_image_cache.dart';
import 'comic_image_tile.dart';
import 'comic_reader_strings.dart';

/// A vertically scrolling, progressively loaded comic reading surface.
///
/// The host owns networking, files, authentication, and persistent image
/// caching through [ComicReaderDataSource]. This widget retains only the
/// current and neighboring chapter metadata plus a bounded session byte cache.
class ComicReaderView extends StatefulWidget {
  /// Creates an embeddable comic reader connected to host data and state.
  const ComicReaderView({
    super.key,
    required this.bookId,
    required this.dataSource,
    required this.stateStore,
    this.observer,
    this.controller,
    this.commentFeed,
  });

  /// Stable host identifier for the comic.
  final String bookId;

  /// Asynchronous source for catalog, image metadata, and encoded image bytes.
  final ComicReaderDataSource dataSource;

  /// Host-owned persistence for progress, preferences, and bookmarks.
  final ComicReaderStateStore stateStore;

  /// Optional notification sink. Callback failures never block reading.
  final ComicReaderObserver? observer;

  /// Optional host-owned command controller.
  final ComicReaderController? controller;

  /// Optional read-only feed for fixed-overlay comic image comment entries.
  ///
  /// The reader never reserves image layout space when this is null.
  final ReaderCommentFeed? commentFeed;

  @override
  State<ComicReaderView> createState() => _ComicReaderViewState();
}

class _ComicReaderViewState extends State<ComicReaderView> {
  static const Duration _saveDelay = Duration(milliseconds: 800);
  static const int _catalogPageSize = 50;
  static const int _metadataWindowLimit = 3;
  static const int _maxSingleImageBytes = 24 * 1024 * 1024;
  static const double _chapterHeaderExtent = 54;
  static const double _boundaryExtent = 72;
  static const double _defaultAspectRatio = .75;
  static const double _progressProbeFraction = .34;

  final Object _controllerOwner = Object();
  final Object _awakeHolder = Object();
  final FocusNode _focusNode = FocusNode(debugLabel: 'ComicReader');
  final ScrollController _scrollController = ScrollController();
  final ComicDecodedImageBudget _decodeBudget = ComicDecodedImageBudget();
  final List<ComicChapterInfo> _catalog = <ComicChapterInfo>[];
  final Map<String, ComicChapterInfo> _catalogById =
      <String, ComicChapterInfo>{};
  final Map<int, ComicChapterInfo> _catalogByIndex = <int, ComicChapterInfo>{};
  final LinkedHashMap<String, ComicChapterContent> _contentCache =
      LinkedHashMap<String, ComicChapterContent>();
  final Map<String, Future<ComicChapterContent>> _contentLoads =
      <String, Future<ComicChapterContent>>{};
  final Map<int, Future<ComicChapterInfo>> _chapterInfoLoads =
      <int, Future<ComicChapterInfo>>{};
  final Map<String, int> _contentEpochs = <String, int>{};
  final List<_LoadedComicChapter> _window = <_LoadedComicChapter>[];
  final Map<int, ReaderFailure> _boundaryFailures = <int, ReaderFailure>{};
  final Set<int> _boundaryLoads = <int>{};
  final Set<String> _catalogCursors = <String>{};
  int _catalogPageCoverage = 0;
  int? _beforeBoundaryIndex;
  int? _afterBoundaryIndex;

  late ComicReaderController _controller;
  late bool _ownsController;
  late AppLifecycleListener _lifecycleListener;
  late ComicImageByteCache _imageCache;
  Timer? _saveTimer;
  Timer? _snapshotTimer;

  ComicBookInfo? _book;
  ComicChapterInfo? _currentChapter;
  ComicReaderProgress? _progress;
  List<ComicReaderBookmark> _bookmarks = const <ComicReaderBookmark>[];
  ComicReaderPreferences _preferences = ComicReaderPreferences.defaults;
  ReaderPlatformCapabilities _platformCapabilities =
      const ReaderPlatformCapabilities();
  ReaderFailure? _failure;
  String? _catalogCursor;
  int _catalogTotal = 0;
  bool _catalogHasMore = false;
  bool _catalogLoading = false;
  bool _loading = true;
  bool _controlsVisible = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _restoring = false;
  bool _preferencesDirty = false;
  bool _preferencesAuthoritative = false;
  double _viewportWidth = 0;
  double _viewportHeight = 0;
  double _topPadding = 0;
  double _horizontalInset = 0;
  int _sessionGeneration = 0;
  int _navigationGeneration = 0;
  ReaderLifecycleState _lifecycleState = ReaderLifecycleState.foreground;
  final Map<_BookStoreKey, Future<void>> _progressWrites =
      <_BookStoreKey, Future<void>>{};
  final HashMap<ComicReaderStateStore, Future<void>> _preferenceWrites =
      HashMap<ComicReaderStateStore, Future<void>>.identity();
  final Map<_BookStoreKey, Future<void>> _bookmarkWrites =
      <_BookStoreKey, Future<void>>{};
  final Map<_BookStoreKey, String> _lastProgressWriteKeys =
      <_BookStoreKey, String>{};
  final HashMap<ComicReaderStateStore, String> _lastPreferenceWriteKeys =
      HashMap<ComicReaderStateStore, String>.identity();
  Future<void>? _exitRequest;
  List<_ComicListEntry> _entryCache = const <_ComicListEntry>[];
  List<double> _entryStarts = const <double>[];
  Map<String, int> _imageEntryIndexes = const <String, int>{};
  int _entryCacheSignature = 0;
  int _sheetGeneration = 0;
  BuildContext? _activeSheetContext;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? ComicReaderController();
    _imageCache = ComicImageByteCache(
      bookId: widget.bookId,
      dataSource: widget.dataSource,
      maxSingleImageBytes: _maxSingleImageBytes,
    );
    _bindController();
    _scrollController.addListener(_handleScroll);
    _lifecycleListener = AppLifecycleListener(onStateChange: _handleLifecycle);
    unawaited(_loadPlatformCapabilities());
    unawaited(_initialize());
  }

  @override
  void didUpdateWidget(covariant ComicReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.unbind(_controllerOwner);
      if (_ownsController) _controller.dispose();
      _ownsController = widget.controller == null;
      _controller = widget.controller ?? ComicReaderController();
      _bindController();
      _publishSnapshot();
    }
    if (!identical(oldWidget.commentFeed, widget.commentFeed)) {
      _dismissSessionSheet();
    }
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.stateStore != widget.stateStore) {
      _dismissSessionSheet();
      final ComicReaderPreferences? preferenceOverride =
          identical(oldWidget.stateStore, widget.stateStore) &&
              _preferencesAuthoritative
          ? _preferences
          : null;
      final ComicReaderProgress? oldProgress = _progress;
      if (oldProgress != null) {
        unawaited(
          _queueProgressSave(
            store: oldWidget.stateStore,
            bookId: oldWidget.bookId,
            progress: oldProgress,
          ),
        );
      }
      if (_preferencesDirty) {
        _preferencesDirty = false;
        unawaited(_savePreferences(_preferences, store: oldWidget.stateStore));
      }
      final ComicReaderObserver oldObserver =
          oldWidget.observer ?? const ComicReaderObserver();
      unawaited(
        _notify(
          () => oldObserver.onSessionEnded(oldWidget.bookId, oldProgress),
        ),
      );
      unawaited(_releaseAwake());
      _imageCache.dispose();
      _imageCache = ComicImageByteCache(
        bookId: widget.bookId,
        dataSource: widget.dataSource,
        maxSingleImageBytes: _maxSingleImageBytes,
      );
      unawaited(_restart(preferenceOverride: preferenceOverride));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionGeneration++;
    _navigationGeneration++;
    _saveTimer?.cancel();
    _snapshotTimer?.cancel();
    if (_preferencesDirty) {
      _preferencesDirty = false;
      unawaited(_savePreferences(_preferences));
    }
    final ComicReaderObserver observer =
        widget.observer ?? const ComicReaderObserver();
    final String bookId = widget.bookId;
    final ComicReaderProgress? progress = _progress;
    _flushProgress();
    unawaited(_releaseAwake());
    unawaited(_notify(() => observer.onSessionEnded(bookId, progress)));
    _lifecycleListener.dispose();
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _focusNode.dispose();
    _imageCache.dispose();
    _dismissSessionSheet();
    _controller.unbind(_controllerOwner);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _bindController() {
    _controller.bind(
      owner: _controllerOwner,
      openChapter: _openChapterById,
      nextChapter: _nextChapter,
      previousChapter: _previousChapter,
      toggleControls: () async => _setControlsVisible(!_controlsVisible),
      showControls: () async => _setControlsVisible(true),
      hideControls: () async => _setControlsVisible(false),
      refresh: _refreshCurrentChapter,
    );
  }

  Future<void> _restart({ComicReaderPreferences? preferenceOverride}) async {
    final int generation = ++_sessionGeneration;
    _navigationGeneration++;
    _saveTimer?.cancel();
    _snapshotTimer?.cancel();
    _contentCache.clear();
    _contentLoads.clear();
    _chapterInfoLoads.clear();
    _contentEpochs.clear();
    _catalog.clear();
    _catalogById.clear();
    _catalogByIndex.clear();
    _window.clear();
    _boundaryFailures.clear();
    _boundaryLoads.clear();
    _catalogCursors.clear();
    _catalogCursor = null;
    _catalogTotal = 0;
    _catalogHasMore = false;
    _catalogLoading = false;
    _catalogPageCoverage = 0;
    _beforeBoundaryIndex = null;
    _afterBoundaryIndex = null;
    _book = null;
    _currentChapter = null;
    _progress = null;
    _preferences = ComicReaderPreferences.defaults;
    _preferencesAuthoritative = false;
    _bookmarks = const <ComicReaderBookmark>[];
    _failure = null;
    _loading = true;
    if (mounted) setState(() {});
    _publishSnapshot();
    await _initialize(
      generation: generation,
      preferenceOverride: preferenceOverride,
    );
  }

  Future<void> _initialize({
    int? generation,
    ComicReaderPreferences? preferenceOverride,
  }) async {
    final int session = generation ?? ++_sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource dataSource = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;

    try {
      if (bookId.trim().isEmpty) {
        throw StateError('Comic book ID must contain visible text.');
      }
      // All five reads start together. State failures are recoverable and do
      // not discard usable book/catalog data.
      final Future<_Result<ComicBookInfo>> bookFuture = _captureCall(
        () => dataSource.loadBookInfo(bookId),
      );
      final Future<_Result<ComicChapterCatalogPage>> catalogFuture =
          _captureCall(
            () => dataSource.loadChapterCatalog(
              bookId,
              pageSize: _catalogPageSize,
            ),
          );
      final _BookStoreKey stateKey = _BookStoreKey(store, bookId);
      final Future<_Result<ComicReaderProgress?>> progressFuture = _captureCall(
        () async {
          await (_progressWrites[stateKey] ?? Future<void>.value());
          return store.loadProgress(bookId);
        },
      );
      final Future<_Result<ComicReaderPreferences?>> preferencesFuture =
          preferenceOverride != null
          ? Future<_Result<ComicReaderPreferences?>>.value(
              _Result<ComicReaderPreferences?>(value: preferenceOverride),
            )
          : _captureCall(() async {
              await (_preferenceWrites[store] ?? Future<void>.value());
              return store.loadPreferences();
            });
      final Future<_Result<List<ComicReaderBookmark>>> bookmarksFuture =
          _captureCall(() async {
            await (_bookmarkWrites[stateKey] ?? Future<void>.value());
            return store.loadBookmarks(bookId);
          });
      final _Result<ComicBookInfo> bookResult = await bookFuture;
      final _Result<ComicChapterCatalogPage> catalogResult =
          await catalogFuture;
      final _Result<ComicReaderProgress?> savedResult = await progressFuture;
      final _Result<ComicReaderPreferences?> preferencesResult =
          await preferencesFuture;
      final _Result<List<ComicReaderBookmark>> bookmarksResult =
          await bookmarksFuture;
      if (!_isSession(session, bookId, dataSource, store)) return;
      if (bookResult.error != null) throw bookResult.error!;
      if (catalogResult.error != null) throw catalogResult.error!;
      final ComicBookInfo book = bookResult.value!;
      final ComicChapterCatalogPage firstPage = catalogResult.value!;
      _validateBook(book, bookId);
      _mergeCatalog(firstPage, requestedCursor: null);
      _book = book;
      _preferences =
          (preferenceOverride ??
                  preferencesResult.value ??
                  ComicReaderPreferences.defaults)
              .normalized();
      _preferencesAuthoritative =
          preferenceOverride != null || preferencesResult.error == null;
      final List<ComicReaderBookmark> loadedBookmarks =
          List<ComicReaderBookmark>.unmodifiable(
            bookmarksResult.value ?? const <ComicReaderBookmark>[],
          );
      try {
        _validateBookmarks(loadedBookmarks, bookId);
        _bookmarks = loadedBookmarks;
      } catch (error) {
        _bookmarks = const <ComicReaderBookmark>[];
        unawaited(_reportFailure(_stateFailure(error)));
      }
      if (savedResult.error != null) {
        unawaited(_reportFailure(_stateFailure(savedResult.error!)));
      }
      if (preferencesResult.error != null && preferenceOverride == null) {
        unawaited(_reportFailure(_stateFailure(preferencesResult.error!)));
      }
      if (bookmarksResult.error != null) {
        unawaited(_reportFailure(_stateFailure(bookmarksResult.error!)));
      }
      if (_catalog.isEmpty) {
        setState(() => _loading = false);
        _publishSnapshot();
        unawaited(
          _notify(
            () => (widget.observer ?? const ComicReaderObserver())
                .onSessionStarted(bookId),
          ),
        );
        return;
      }
      final ComicReaderProgress? saved = savedResult.value;
      ComicChapterInfo target = _catalog.first;
      if (saved != null) {
        final ComicChapterInfo? restored = await _resolveSavedChapter(saved);
        if (restored != null) target = restored;
      }
      if (!_isSession(session, bookId, dataSource, store)) return;
      await _openChapterInfo(
        target,
        restore: saved?.chapterId == target.id ? saved : null,
        replaceWindow: true,
      );
      if (!_isSession(session, bookId, dataSource, store)) return;
      unawaited(
        _notify(
          () => (widget.observer ?? const ComicReaderObserver())
              .onSessionStarted(bookId),
        ),
      );
    } catch (error) {
      if (!_isSession(session, bookId, dataSource, store)) return;
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      setState(() {
        _loading = false;
        _failure = failure;
      });
      _publishSnapshot();
      unawaited(_reportFailure(failure));
    }
  }

  Future<ComicChapterInfo?> _resolveSavedChapter(
    ComicReaderProgress saved,
  ) async {
    if (saved.chapterId.trim().isEmpty ||
        saved.imageId.trim().isEmpty ||
        saved.chapterIndex < 0 ||
        !saved.imageFraction.isFinite ||
        saved.imageFraction < 0 ||
        saved.imageFraction > 1 ||
        !saved.chapterFraction.isFinite ||
        saved.chapterFraction < 0 ||
        saved.chapterFraction > 1 ||
        !saved.bookFraction.isFinite ||
        saved.bookFraction < 0 ||
        saved.bookFraction > 1) {
      unawaited(
        _reportFailure(
          const ReaderFailure(
            ReaderFailureKind.persistence,
            '已保存的漫画进度无效，已从首章开始',
          ),
        ),
      );
      return null;
    }
    final ComicChapterInfo? known = _catalogById[saved.chapterId];
    if (known != null) return known;
    if (saved.chapterIndex < 0 ||
        (_catalogTotal > 0 && saved.chapterIndex >= _catalogTotal)) {
      return null;
    }
    try {
      final ComicChapterInfo info = await _chapterAtIndex(saved.chapterIndex);
      if (info.id != saved.chapterId) return null;
      return info;
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
      return null;
    }
  }

  Future<void> _openChapterById(String chapterId) async {
    final String id = chapterId.trim();
    if (id.isEmpty) return;
    ComicChapterInfo? chapter = _catalogById[id];
    while (chapter == null && _catalogHasMore && !_disposed) {
      final bool loaded = await _loadNextCatalogPage();
      if (!loaded) break;
      chapter = _catalogById[id];
    }
    if (chapter == null) {
      unawaited(
        _reportFailure(
          const ReaderFailure(ReaderFailureKind.data, '找不到指定漫画章节'),
        ),
      );
      return;
    }
    await _openChapterInfo(chapter, replaceWindow: true);
  }

  Future<void> _openChapterInfo(
    ComicChapterInfo info, {
    ComicReaderProgress? restore,
    required bool replaceWindow,
    bool forceRefresh = false,
  }) async {
    final ComicReaderProgress? checkpoint = _progress;
    if (checkpoint != null) {
      unawaited(
        _queueProgressSave(
          store: widget.stateStore,
          bookId: widget.bookId,
          progress: checkpoint,
        ),
      );
    }
    _saveTimer?.cancel();
    final int navigation = ++_navigationGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
        if (replaceWindow) {
          _boundaryLoads.clear();
          _boundaryFailures.clear();
          _beforeBoundaryIndex = null;
          _afterBoundaryIndex = null;
        }
      });
    }
    _publishSnapshot();
    try {
      final ComicChapterContent content = await _loadContent(
        info,
        forceRefresh: forceRefresh,
      );
      if (!_isNavigation(navigation)) return;
      if (replaceWindow) _window.clear();
      _window
        ..removeWhere((item) => item.info.id == info.id)
        ..add(_LoadedComicChapter(info, content))
        ..sort((a, b) => a.info.index.compareTo(b.info.index));
      _trimWindow(aroundIndex: info.index);
      _currentChapter = info;
      final ComicReaderProgress? resolvedRestore = _progressForContent(
        info,
        content,
        restore,
      );
      _progress = resolvedRestore;
      _loading = false;
      _failure = null;
      _restoring = true;
      if (mounted) setState(() {});
      _publishSnapshot();
      unawaited(
        _notify(
          () => (widget.observer ?? const ComicReaderObserver())
              .onChapterChanged(info),
        ),
      );
      unawaited(_syncAwake());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isNavigation(navigation)) return;
        _restorePosition(resolvedRestore);
        _restoring = false;
        unawaited(_loadAdjacent(info.index - 1, before: true));
        unawaited(_loadAdjacent(info.index + 1, before: false));
      });
    } catch (error) {
      if (!_isNavigation(navigation)) return;
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      setState(() {
        _loading = false;
        _failure = failure;
      });
      _publishSnapshot();
      unawaited(_reportFailure(failure));
    }
  }

  ComicReaderProgress? _progressForContent(
    ComicChapterInfo info,
    ComicChapterContent content,
    ComicReaderProgress? requested,
  ) {
    if (content.images.isEmpty) return null;
    int imageIndex = 0;
    double imageFraction = 0;
    if (requested != null && requested.chapterId == info.id) {
      final int requestedIndex = content.images.indexWhere(
        (ComicImageInfo image) => image.id == requested.imageId,
      );
      if (requestedIndex >= 0 &&
          requested.imageFraction.isFinite &&
          requested.imageFraction >= 0 &&
          requested.imageFraction <= 1) {
        imageIndex = requestedIndex;
        imageFraction = requested.imageFraction;
      }
    }
    final double chapterFraction =
        (imageIndex + imageFraction) / content.images.length;
    final int total = _catalogTotal > 0 ? _catalogTotal : info.index + 1;
    return ComicReaderProgress(
      chapterId: info.id,
      imageId: content.images[imageIndex].id,
      imageFraction: imageFraction,
      chapterIndex: info.index,
      chapterFraction: chapterFraction.clamp(0, 1).toDouble(),
      bookFraction: ((info.index + chapterFraction) / total)
          .clamp(0, 1)
          .toDouble(),
    );
  }

  Future<ComicChapterContent> _loadContent(
    ComicChapterInfo info, {
    bool forceRefresh = false,
  }) {
    if (forceRefresh) {
      _contentEpochs[info.id] = (_contentEpochs[info.id] ?? 0) + 1;
      _contentCache.remove(info.id);
      _contentLoads.remove(info.id);
    }
    final ComicChapterContent? cached = _contentCache.remove(info.id);
    if (cached != null) {
      _contentCache[info.id] = cached;
      return Future<ComicChapterContent>.value(cached);
    }
    final Future<ComicChapterContent>? existing = _contentLoads[info.id];
    if (existing != null) return existing;
    final int session = _sessionGeneration;
    final int contentEpoch = _contentEpochs[info.id] ?? 0;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    late final Future<ComicChapterContent> load;
    load = source.loadChapterContent(bookId, info.id).then((
      ComicChapterContent content,
    ) {
      _validateContent(content, info);
      if (_isSessionForSource(session, bookId, source) &&
          contentEpoch == (_contentEpochs[info.id] ?? 0) &&
          identical(_contentLoads[info.id], load)) {
        _contentCache[info.id] = content;
        while (_contentCache.length > _metadataWindowLimit) {
          _contentCache.remove(_contentCache.keys.first);
        }
      }
      return content;
    });
    _contentLoads[info.id] = load;
    load.whenComplete(() {
      if (identical(_contentLoads[info.id], load)) {
        _contentLoads.remove(info.id);
      }
    }).ignore();
    return load;
  }

  Future<void> _loadAdjacent(int index, {required bool before}) async {
    if (_disposed ||
        index < 0 ||
        (_catalogTotal > 0 && index >= _catalogTotal) ||
        !_isBoundaryCursor(index, before: before) ||
        _window.any((chapter) => chapter.info.index == index) ||
        !_boundaryLoads.add(index)) {
      return;
    }
    if (mounted) setState(() => _boundaryFailures.remove(index));
    final int navigation = _navigationGeneration;
    var scanAdvanced = false;
    try {
      final ComicChapterInfo info = await _chapterAtIndex(index);
      final ComicChapterContent content = await _loadContent(info);
      if (!_isNavigation(navigation)) return;
      if (content.images.isEmpty && info.index != _currentChapter?.index) {
        if (!_isBoundaryCursor(index, before: before)) return;
        setState(() {
          if (before) {
            _beforeBoundaryIndex = index - 1;
          } else {
            _afterBoundaryIndex = index + 1;
          }
        });
        scanAdvanced = true;
        return;
      }
      if (!_isBoundaryCursor(index, before: before)) return;
      final double oldOffset = _scrollController.hasClients
          ? _scrollController.offset
          : 0;
      final double insertedExtent = _chapterExtent(content);
      double removedFromTop = 0;
      setState(() {
        if (before) {
          _beforeBoundaryIndex = index - 1;
        } else {
          _afterBoundaryIndex = index + 1;
        }
        _window
          ..add(_LoadedComicChapter(info, content))
          ..sort((a, b) => a.info.index.compareTo(b.info.index));
        removedFromTop = _trimWindow(
          aroundIndex: _currentChapter?.index ?? info.index,
        );
      });
      final double offsetDelta =
          (before ? _beforeInsertionExtent(index, insertedExtent) : 0) -
          removedFromTop;
      if (offsetDelta != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_isNavigation(navigation) || !_scrollController.hasClients) {
            return;
          }
          _restoring = true;
          _scrollController.jumpTo(
            (oldOffset + offsetDelta).clamp(
              0,
              _scrollController.position.maxScrollExtent,
            ),
          );
          _restoring = false;
        });
      }
    } catch (error) {
      if (!_isNavigation(navigation)) return;
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      setState(() => _boundaryFailures[index] = failure);
      unawaited(_reportFailure(failure));
    } finally {
      if (_isNavigation(navigation)) {
        _boundaryLoads.remove(index);
        if (mounted) setState(() {});
        if (scanAdvanced) {
          unawaited(
            _loadAdjacent(before ? index - 1 : index + 1, before: before),
          );
        }
      }
    }
  }

  bool _isBoundaryCursor(int index, {required bool before}) {
    if (_window.isEmpty) return false;
    final int expected = before
        ? (_beforeBoundaryIndex ?? _window.first.info.index - 1)
        : (_afterBoundaryIndex ?? _window.last.info.index + 1);
    return index == expected;
  }

  Future<ComicChapterInfo> _chapterAtIndex(int index) async {
    final ComicChapterInfo? known = _catalogByIndex[index];
    if (known != null) return known;
    final Future<ComicChapterInfo>? existing = _chapterInfoLoads[index];
    if (existing != null) return existing;
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    late final Future<ComicChapterInfo> load;
    load = source.loadChapterAtIndex(bookId, index).then((info) {
      _validateChapterInfo(info, expectedIndex: index);
      if (!_isSessionForSource(session, bookId, source)) {
        throw StateError('Stale comic chapter request.');
      }
      _rememberChapter(info);
      return info;
    });
    _chapterInfoLoads[index] = load;
    load.whenComplete(() {
      if (identical(_chapterInfoLoads[index], load)) {
        _chapterInfoLoads.remove(index);
      }
    }).ignore();
    return load;
  }

  double _trimWindow({required int aroundIndex}) {
    double removedFromTop = 0;
    while (_window.length > _metadataWindowLimit) {
      final int firstDistance = (_window.first.info.index - aroundIndex).abs();
      final int lastDistance = (_window.last.info.index - aroundIndex).abs();
      if (firstDistance > lastDistance) {
        final _LoadedComicChapter removed = _window.first;
        final double oldBoundary = removed.info.index > 0 ? _boundaryExtent : 0;
        _window.removeAt(0);
        _beforeBoundaryIndex = removed.info.index;
        final double newBoundary = _window.first.info.index > 0
            ? _boundaryExtent
            : 0;
        removedFromTop +=
            _chapterExtent(removed.content) + oldBoundary - newBoundary;
      } else {
        final _LoadedComicChapter removed = _window.removeLast();
        _afterBoundaryIndex = removed.info.index;
      }
    }
    final Set<String> retained = _window.map((e) => e.info.id).toSet();
    for (final String id in _contentCache.keys.toList()) {
      if (!retained.contains(id)) _contentCache.remove(id);
    }
    return removedFromTop;
  }

  double _beforeInsertionExtent(int index, double chapterExtent) =>
      chapterExtent + (index > 0 ? _boundaryExtent : 0) - _boundaryExtent;

  Future<void> _nextChapter() async {
    final ComicChapterInfo? current = _currentChapter;
    if (current == null) return;
    final int next = current.index + 1;
    if (_catalogTotal > 0 && next >= _catalogTotal) return;
    try {
      await _openChapterInfo(await _chapterAtIndex(next), replaceWindow: true);
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
    }
  }

  Future<void> _previousChapter() async {
    final ComicChapterInfo? current = _currentChapter;
    if (current == null || current.index <= 0) return;
    try {
      await _openChapterInfo(
        await _chapterAtIndex(current.index - 1),
        replaceWindow: true,
      );
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
    }
  }

  Future<void> _refreshCurrentChapter() async {
    final ComicChapterInfo? current = _currentChapter;
    if (current == null) return;
    _imageCache.removeChapter(current.id);
    await _openChapterInfo(
      current,
      restore: _progress,
      replaceWindow: true,
      forceRefresh: true,
    );
  }

  void _restorePosition(ComicReaderProgress? saved) {
    if (!_scrollController.hasClients || _window.isEmpty) return;
    double anchorOffset = _topPadding;
    bool found = false;
    for (final _ComicListEntry entry in _entries()) {
      if (entry is _ComicImageEntry &&
          saved != null &&
          entry.chapter.info.id == saved.chapterId &&
          entry.image.id == saved.imageId) {
        anchorOffset += entry.imageExtent * saved.imageFraction.clamp(0, 1);
        found = true;
        break;
      }
      if (saved == null &&
          entry is _ComicImageEntry &&
          entry.chapter.info.id == _currentChapter?.id) {
        found = true;
        break;
      }
      anchorOffset += entry.extent;
    }
    if (!found) anchorOffset = _topPadding;
    final double offset =
        anchorOffset - _viewportHeight * _progressProbeFraction;
    _scrollController.jumpTo(
      offset.clamp(0, _scrollController.position.maxScrollExtent),
    );
    _updateProgressFromScroll();
  }

  void _handleScroll() {
    if (_disposed || _restoring || !_scrollController.hasClients) return;
    _updateProgressFromScroll();
    final ScrollPosition position = _scrollController.position;
    final double trigger = position.viewportDimension * 1.5;
    if (position.extentAfter < trigger && _window.isNotEmpty) {
      unawaited(
        _loadAdjacent(
          _afterBoundaryIndex ?? _window.last.info.index + 1,
          before: false,
        ),
      );
    }
    if (position.extentBefore < trigger && _window.isNotEmpty) {
      unawaited(
        _loadAdjacent(
          _beforeBoundaryIndex ?? _window.first.info.index - 1,
          before: true,
        ),
      );
    }
  }

  void _updateProgressFromScroll() {
    if (_window.isEmpty || _viewportWidth <= 0) return;
    final double probe =
        _scrollController.offset + _viewportHeight * _progressProbeFraction;
    final List<_ComicListEntry> entries = _entries();
    final int candidate = _entryIndexAt(probe - _topPadding);
    _ComicImageEntry? selected;
    double fraction = 0;
    for (int index = candidate; index < entries.length; index++) {
      final _ComicListEntry entry = entries[index];
      if (entry is! _ComicImageEntry) continue;
      selected = entry;
      final double start = _entryStarts[index] + _topPadding;
      fraction = ((probe - start) / entry.imageExtent).clamp(0, 1).toDouble();
      break;
    }
    if (selected == null) return;
    final _LoadedComicChapter chapter = selected.chapter;
    final int imageIndex = selected.image.index.clamp(
      0,
      chapter.content.images.length - 1,
    );
    final double chapterFraction = chapter.content.images.isEmpty
        ? 0
        : (imageIndex + fraction) / chapter.content.images.length;
    final int total = _catalogTotal > 0
        ? _catalogTotal
        : _catalogByIndex.keys.fold<int>(1, (max, value) {
            final int count = value + 1;
            return count > max ? count : max;
          });
    final ComicReaderProgress next = ComicReaderProgress(
      chapterId: chapter.info.id,
      imageId: selected.image.id,
      imageFraction: fraction,
      chapterIndex: chapter.info.index,
      chapterFraction: chapterFraction.clamp(0, 1).toDouble(),
      bookFraction: ((chapter.info.index + chapterFraction) / total)
          .clamp(0, 1)
          .toDouble(),
    );
    final bool chapterChanged = _currentChapter?.id != chapter.info.id;
    if (chapterChanged && _progress != null) {
      unawaited(
        _queueProgressSave(
          store: widget.stateStore,
          bookId: widget.bookId,
          progress: _progress!,
        ),
      );
    }
    _progress = next;
    if (chapterChanged) {
      _currentChapter = chapter.info;
      if (mounted) setState(() {});
      unawaited(
        _notify(
          () => (widget.observer ?? const ComicReaderObserver())
              .onChapterChanged(chapter.info),
        ),
      );
    }
    _scheduleProgressSave();
    _scheduleSnapshotPublish();
    _prefetchAround(selected);
  }

  void _prefetchAround(_ComicImageEntry selected) {
    final List<_ComicListEntry> entries = _entries();
    final int index =
        _imageEntryIndexes['${selected.chapter.info.id}\u0000${selected.image.id}'] ??
        -1;
    if (index < 0) return;
    int loaded = 0;
    for (int distance = 1; distance <= 4 && loaded < 3; distance++) {
      for (final int candidate in <int>[index + distance, index - distance]) {
        if (candidate < 0 || candidate >= entries.length) continue;
        final _ComicListEntry entry = entries[candidate];
        if (entry is! _ComicImageEntry) continue;
        _imageCache.prefetch(entry.chapter.info.id, entry.image);
        loaded++;
        if (loaded >= 3) break;
      }
    }
  }

  void _scheduleProgressSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, _flushProgress);
  }

  Future<void> _flushProgress() {
    _saveTimer?.cancel();
    final ComicReaderProgress? progress = _progress;
    if (progress == null) return Future<void>.value();
    return _queueProgressSave(
      store: widget.stateStore,
      bookId: widget.bookId,
      progress: progress,
    );
  }

  Future<void> _queueProgressSave({
    required ComicReaderStateStore store,
    required String bookId,
    required ComicReaderProgress progress,
  }) {
    final _BookStoreKey stateKey = _BookStoreKey(store, bookId);
    final String writeKey =
        '${progress.chapterId}\u0000'
        '${progress.imageId}\u0000${progress.imageFraction}\u0000'
        '${progress.chapterIndex}\u0000${progress.chapterFraction}\u0000'
        '${progress.bookFraction}';
    if (_lastProgressWriteKeys[stateKey] == writeKey) {
      return _progressWrites[stateKey] ?? Future<void>.value();
    }
    _lastProgressWriteKeys[stateKey] = writeKey;
    return _enqueueStoreWrite(
      _progressWrites,
      stateKey,
      () => store.saveProgress(bookId, progress),
      (Object error) {
        if (_lastProgressWriteKeys[stateKey] == writeKey) {
          _lastProgressWriteKeys.remove(stateKey);
        }
        if (!_disposed &&
            identical(store, widget.stateStore) &&
            bookId == widget.bookId) {
          unawaited(_reportFailure(_stateFailure(error)));
        }
      },
    );
  }

  Future<void> _savePreferences(
    ComicReaderPreferences value, {
    ComicReaderStateStore? store,
  }) {
    final ComicReaderPreferences normalized = value.normalized();
    final ComicReaderStateStore targetStore = store ?? widget.stateStore;
    final String writeKey =
        '${normalized.brightness}\u0000${normalized.imageSpacing}\u0000'
        '${normalized.keepScreenOn}\u0000${normalized.immersiveMode}';
    if (_lastPreferenceWriteKeys[targetStore] == writeKey) {
      return _preferenceWrites[targetStore] ?? Future<void>.value();
    }
    _lastPreferenceWriteKeys[targetStore] = writeKey;
    return _enqueueStoreWrite(
      _preferenceWrites,
      targetStore,
      () => targetStore.savePreferences(normalized),
      (Object error) {
        if (_lastPreferenceWriteKeys[targetStore] == writeKey) {
          _lastPreferenceWriteKeys.remove(targetStore);
        }
        if (identical(targetStore, widget.stateStore) &&
            normalized.brightness == _preferences.brightness &&
            normalized.imageSpacing == _preferences.imageSpacing &&
            normalized.keepScreenOn == _preferences.keepScreenOn &&
            normalized.immersiveMode == _preferences.immersiveMode) {
          _preferencesDirty = true;
        }
        if (!_disposed && identical(targetStore, widget.stateStore)) {
          unawaited(_reportFailure(_stateFailure(error)));
        }
      },
    );
  }

  Future<void> _commitPreferences() {
    if (!_preferencesDirty) {
      return _preferenceWrites[widget.stateStore] ?? Future<void>.value();
    }
    _preferencesDirty = false;
    return _savePreferences(_preferences);
  }

  Future<void> _enqueueStoreWrite<K>(
    Map<K, Future<void>> queue,
    K key,
    Future<void> Function() operation,
    void Function(Object error) onError,
  ) {
    final Future<void> previous = queue[key] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .then((_) => Future<void>.sync(operation))
        .catchError((Object error, StackTrace stackTrace) => onError(error))
        .whenComplete(() {
          if (identical(queue[key], next)) queue.remove(key);
        });
    queue[key] = next;
    return next;
  }

  Future<void> _loadPlatformCapabilities() async {
    try {
      final ReaderPlatformCapabilities capabilities = await ReaderPlatform
          .instance
          .capabilities();
      if (_disposed) return;
      setState(() => _platformCapabilities = capabilities);
      unawaited(_syncAwake());
    } catch (error) {
      if (!_disposed) {
        unawaited(
          _reportFailure(_asFailure(error, ReaderFailureKind.platform)),
        );
      }
    }
  }

  void _handleLifecycle(AppLifecycleState state) {
    final ReaderLifecycleState normalized = switch (state) {
      AppLifecycleState.resumed => ReaderLifecycleState.foreground,
      AppLifecycleState.inactive => ReaderLifecycleState.inactive,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused => ReaderLifecycleState.background,
      AppLifecycleState.detached => ReaderLifecycleState.detached,
    };
    if (_lifecycleState == normalized) return;
    _lifecycleState = normalized;
    _foreground = normalized == ReaderLifecycleState.foreground;
    if (_foreground) {
      unawaited(_syncAwake());
    } else {
      unawaited(_releaseAwake());
      unawaited(_flushProgress());
      if (_preferencesDirty) unawaited(_commitPreferences());
    }
    final ComicReaderProgress? progress = _progress;
    unawaited(
      _notify(
        () => (widget.observer ?? const ComicReaderObserver())
            .onLifecycleChanged(normalized, progress),
      ),
    );
  }

  Future<void> _syncAwake() => _reconcileAwake();

  Future<void> _reconcileAwake() async {
    final bool keep =
        _preferences.keepScreenOn && _platformCapabilities.keepScreenOn;
    final bool immersive =
        _preferences.immersiveMode && _platformCapabilities.immersiveMode;
    final bool wanted =
        !_disposed &&
        _foreground &&
        _currentChapter != null &&
        (keep || immersive);
    try {
      if (wanted) {
        await ScreenAwakeCoordinator.instance.acquire(
          _awakeHolder,
          keepScreenOn: keep,
          immersiveMode: immersive,
        );
      } else {
        await ScreenAwakeCoordinator.instance.release(_awakeHolder);
      }
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.platform)));
    }
  }

  Future<void> _releaseAwake() {
    // `release` removes the holder synchronously before its platform Future is
    // returned, so background/dispose never queue behind a hung acquire.
    try {
      return ScreenAwakeCoordinator.instance.release(_awakeHolder).catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        unawaited(
          _reportFailure(_asFailure(error, ReaderFailureKind.platform)),
        );
      });
    } catch (error) {
      unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.platform)));
      return Future<void>.value();
    }
  }

  Future<void> _requestExit() {
    final Future<void>? current = _exitRequest;
    if (current != null) return current;
    final ComicReaderProgress? progress = _progress;
    final ComicReaderObserver observer =
        widget.observer ?? const ComicReaderObserver();
    final Future<void> request = () async {
      unawaited(_flushProgress());
      if (_preferencesDirty) unawaited(_commitPreferences());
      unawaited(_releaseAwake());
      await _notify(() => observer.onExitRequested(progress));
    }();
    _exitRequest = request.whenComplete(() => _exitRequest = null);
    return _exitRequest!;
  }

  void _setControlsVisible(bool value) {
    if (_disposed || _controlsVisible == value) return;
    setState(() => _controlsVisible = value);
    _publishSnapshot();
  }

  void _publishSnapshot() {
    _controller.updateSnapshot(
      ComicReaderSnapshot(
        isReady: _currentChapter != null && _failure == null,
        isLoading: _loading,
        controlsVisible: _controlsVisible,
        book: _book,
        chapter: _currentChapter,
        progress: _progress,
        failure: _failure,
      ),
      owner: _controllerOwner,
    );
  }

  void _scheduleSnapshotPublish() {
    if (_snapshotTimer?.isActive ?? false) return;
    _snapshotTimer = Timer(const Duration(milliseconds: 80), () {
      if (!_disposed) _publishSnapshot();
    });
  }

  Future<bool> _loadNextCatalogPage() async {
    if (_catalogLoading || !_catalogHasMore) return false;
    final String? cursor = _catalogCursor;
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    _catalogLoading = true;
    if (mounted) setState(() {});
    try {
      final ComicChapterCatalogPage page = await source.loadChapterCatalog(
        bookId,
        cursor: cursor,
        pageSize: _catalogPageSize,
      );
      if (!_isSessionForSource(session, bookId, source)) return false;
      _mergeCatalog(page, requestedCursor: cursor);
      return true;
    } catch (error) {
      if (_isSessionForSource(session, bookId, source)) {
        unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
      }
      return false;
    } finally {
      if (_isSessionForSource(session, bookId, source)) {
        _catalogLoading = false;
        if (mounted) setState(() {});
      }
    }
  }

  void _mergeCatalog(
    ComicChapterCatalogPage page, {
    required String? requestedCursor,
  }) {
    if (page.total < 0 ||
        (_catalogTotal > 0 && page.total != _catalogTotal) ||
        (page.hasMore && page.items.isEmpty) ||
        (!page.hasMore && page.nextCursor != null) ||
        (requestedCursor == null &&
            page.total > 0 &&
            (page.items.isEmpty || page.items.first.index != 0)) ||
        (page.hasMore &&
            (page.nextCursor == null ||
                page.nextCursor!.trim().isEmpty ||
                page.nextCursor == requestedCursor ||
                _catalogCursors.contains(page.nextCursor)))) {
      throw StateError('Invalid comic catalog cursor response.');
    }
    final Map<String, ComicChapterInfo> nextById =
        Map<String, ComicChapterInfo>.of(_catalogById);
    final Map<int, ComicChapterInfo> nextByIndex =
        Map<int, ComicChapterInfo>.of(_catalogByIndex);
    var expectedPageIndex = requestedCursor == null ? 0 : _catalogPageCoverage;
    for (final ComicChapterInfo info in page.items) {
      _validateChapterInfo(info);
      if (info.index != expectedPageIndex) {
        throw StateError('Comic catalog page did not advance contiguously.');
      }
      expectedPageIndex++;
      final ComicChapterInfo? byId = nextById[info.id];
      final ComicChapterInfo? byIndex = nextByIndex[info.index];
      if ((byId != null && byId.index != info.index) ||
          (byIndex != null && byIndex.id != info.id)) {
        throw StateError('Comic catalog identifiers are inconsistent.');
      }
      nextById[info.id] = info;
      nextByIndex[info.index] = info;
    }
    final int knownCount = nextByIndex.keys.fold<int>(0, (count, index) {
      final int candidate = index + 1;
      return candidate > count ? candidate : count;
    });
    if (page.total < knownCount) {
      throw StateError(
        'Comic catalog total is smaller than its chapter index.',
      );
    }
    if (!page.hasMore && expectedPageIndex != page.total) {
      throw StateError(
        'Comic catalog ended before all chapters were supplied.',
      );
    }
    _catalogById
      ..clear()
      ..addAll(nextById);
    _catalogByIndex
      ..clear()
      ..addAll(nextByIndex);
    _catalog
      ..clear()
      ..addAll(nextByIndex.values)
      ..sort((a, b) => a.index.compareTo(b.index));
    _catalogTotal = page.total;
    _catalogPageCoverage = expectedPageIndex;
    _catalogHasMore = page.hasMore;
    _catalogCursor = page.nextCursor;
    if (page.nextCursor != null) _catalogCursors.add(page.nextCursor!);
  }

  void _rememberChapter(ComicChapterInfo info) {
    _validateChapterInfo(info);
    final ComicChapterInfo? byId = _catalogById[info.id];
    final ComicChapterInfo? byIndex = _catalogByIndex[info.index];
    if ((byId != null && byId.index != info.index) ||
        (byIndex != null && byIndex.id != info.id)) {
      throw StateError('Comic catalog identifiers are inconsistent.');
    }
    _catalogById[info.id] = info;
    _catalogByIndex[info.index] = info;
    final int existing = _catalog.indexWhere((entry) => entry.id == info.id);
    if (existing < 0) {
      _catalog.add(info);
    } else {
      _catalog[existing] = info;
    }
    _catalog.sort((a, b) => a.index.compareTo(b.index));
  }

  void _validateBook(ComicBookInfo book, String expectedId) {
    if (book.id != expectedId || book.title.trim().isEmpty) {
      throw StateError('Comic book metadata is invalid.');
    }
  }

  void _validateChapterInfo(ComicChapterInfo info, {int? expectedIndex}) {
    if (info.id.trim().isEmpty ||
        info.title.trim().isEmpty ||
        info.index < 0 ||
        (expectedIndex != null && info.index != expectedIndex) ||
        (info.imageCount != null && info.imageCount! < 0)) {
      throw StateError('Comic chapter metadata is invalid.');
    }
  }

  void _validateContent(ComicChapterContent content, ComicChapterInfo info) {
    if (content.chapterId != info.id || content.title.trim().isEmpty) {
      throw StateError(
        'Comic chapter content does not match its catalog item.',
      );
    }
    final Set<String> ids = <String>{};
    for (int index = 0; index < content.images.length; index++) {
      final ComicImageInfo image = content.images[index];
      if (image.id.trim().isEmpty ||
          !ids.add(image.id) ||
          image.index != index ||
          (image.width != null && image.width! <= 0) ||
          (image.height != null && image.height! <= 0) ||
          (image.byteLength != null &&
              (image.byteLength! <= 0 ||
                  image.byteLength! > _maxSingleImageBytes))) {
        throw StateError('Comic image metadata is invalid.');
      }
    }
    if (info.imageCount != null && info.imageCount != content.images.length) {
      throw StateError('Comic chapter image count is inconsistent.');
    }
  }

  void _validateBookmarks(List<ComicReaderBookmark> bookmarks, String bookId) {
    final Set<String> ids = <String>{};
    for (final ComicReaderBookmark bookmark in bookmarks) {
      if (bookmark.id.trim().isEmpty ||
          !ids.add(bookmark.id) ||
          bookmark.bookId != bookId ||
          bookmark.chapterId.trim().isEmpty ||
          bookmark.imageId.trim().isEmpty ||
          !bookmark.imageFraction.isFinite ||
          bookmark.imageFraction < 0 ||
          bookmark.imageFraction > 1) {
        throw StateError('Comic bookmark state is invalid.');
      }
    }
  }

  bool _isSession(
    int generation,
    String bookId,
    ComicReaderDataSource source,
    ComicReaderStateStore store,
  ) =>
      !_disposed &&
      generation == _sessionGeneration &&
      bookId == widget.bookId &&
      identical(source, widget.dataSource) &&
      identical(store, widget.stateStore);

  bool _isSessionForSource(
    int generation,
    String bookId,
    ComicReaderDataSource source,
  ) =>
      !_disposed &&
      generation == _sessionGeneration &&
      bookId == widget.bookId &&
      identical(source, widget.dataSource);

  bool _isNavigation(int generation) =>
      !_disposed && generation == _navigationGeneration;

  ReaderFailure _stateFailure(Object error) => ReaderFailure(
    ReaderFailureKind.persistence,
    ComicReaderStrings.readerProblem,
    cause: error,
  );

  ReaderFailure _asFailure(Object error, ReaderFailureKind kind) =>
      error is ReaderFailure
      ? error
      : ReaderFailure(kind, ComicReaderStrings.readerProblem, cause: error);

  Future<void> _reportFailure(ReaderFailure failure) {
    if (_disposed) return Future<void>.value();
    final ComicReaderObserver observer =
        widget.observer ?? const ComicReaderObserver();
    return _notify(() => observer.onFailure(failure));
  }

  Future<void> _notify(FutureOr<void> Function() callback) =>
      Future<void>.sync(callback).catchError((Object error, StackTrace stack) {
        debugPrint('novel_reader_ui comic observer failed: $error\n$stack');
      });

  Future<_Result<T>> _captureCall<T>(Future<T> Function() operation) async {
    try {
      return _Result<T>(value: await Future<T>.sync(operation));
    } catch (error) {
      return _Result<T>(error: error);
    }
  }

  List<_ComicListEntry> _entries() {
    final int signature = Object.hash(
      _viewportWidth,
      _preferences.imageSpacing,
      Object.hashAll(
        _window.map(
          (item) => Object.hash(item.info.id, identityHashCode(item.content)),
        ),
      ),
      Object.hashAll(_boundaryLoads),
      Object.hashAll(
        _boundaryFailures.entries.map(
          (entry) => Object.hash(entry.key, identityHashCode(entry.value)),
        ),
      ),
      _catalogTotal,
      _beforeBoundaryIndex,
      _afterBoundaryIndex,
    );
    if (signature == _entryCacheSignature) return _entryCache;
    final List<_ComicListEntry> result = <_ComicListEntry>[];
    if (_window.isNotEmpty) {
      final int previousIndex =
          _beforeBoundaryIndex ?? _window.first.info.index - 1;
      if (previousIndex >= 0) {
        result.add(
          _ComicBoundaryEntry(
            index: previousIndex,
            loading: _boundaryLoads.contains(previousIndex),
            failure: _boundaryFailures[previousIndex],
            atEnd: false,
            before: true,
          ),
        );
      }
    }
    for (final _LoadedComicChapter chapter in _window) {
      result.add(_ComicHeaderEntry(chapter));
      for (final ComicImageInfo image in chapter.content.images) {
        result.add(
          _ComicImageEntry(
            chapter,
            image,
            imageExtent: _imageExtent(image),
            spacing: _preferences.imageSpacing,
          ),
        );
      }
    }
    if (_window.isNotEmpty) {
      final int nextIndex = _afterBoundaryIndex ?? _window.last.info.index + 1;
      if (_catalogTotal == 0 || nextIndex <= _catalogTotal) {
        result.add(
          _ComicBoundaryEntry(
            index: nextIndex,
            loading: _boundaryLoads.contains(nextIndex),
            failure: _boundaryFailures[nextIndex],
            atEnd: _catalogTotal > 0 && nextIndex >= _catalogTotal,
            before: false,
          ),
        );
      }
    }
    final List<double> starts = <double>[];
    final Map<String, int> indexes = <String, int>{};
    double cursor = 0;
    for (int index = 0; index < result.length; index++) {
      final _ComicListEntry entry = result[index];
      starts.add(cursor);
      if (entry is _ComicImageEntry) {
        indexes['${entry.chapter.info.id}\u0000${entry.image.id}'] = index;
      }
      cursor += entry.extent;
    }
    _entryCacheSignature = signature;
    _entryCache = List<_ComicListEntry>.unmodifiable(result);
    _entryStarts = List<double>.unmodifiable(starts);
    _imageEntryIndexes = Map<String, int>.unmodifiable(indexes);
    return _entryCache;
  }

  int _entryIndexAt(double contentOffset) {
    if (_entryStarts.isEmpty) return 0;
    int low = 0;
    int high = _entryStarts.length - 1;
    while (low <= high) {
      final int middle = (low + high) >> 1;
      if (_entryStarts[middle] <= contentOffset) {
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return high.clamp(0, _entryStarts.length - 1);
  }

  double _imageExtent(ComicImageInfo image) {
    final double ratio = image.width != null && image.height != null
        ? (image.width! / image.height!).clamp(.02, 20).toDouble()
        : _defaultAspectRatio;
    return _viewportWidth <= 0 ? 600 : _viewportWidth / ratio;
  }

  double _chapterExtent(ComicChapterContent content) =>
      _chapterHeaderExtent +
      content.images.fold<double>(
        0,
        (sum, image) => sum + _imageExtent(image) + _preferences.imageSpacing,
      );

  @override
  Widget build(BuildContext context) {
    final ReaderPalette palette = ReaderPalette.fromPreset(
      ReaderThemePreset.deepNight,
    );
    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, void result) {
        if (!didPop) unawaited(_requestExit());
      },
      child: MediaQuery.withClampedTextScaling(
        minScaleFactor: .85,
        maxScaleFactor: 1.3,
        child: Theme(
          data: ThemeData(
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: palette.accent,
              brightness: Brightness.dark,
              surface: palette.panel,
            ),
            fontFamily: readerDefaultFontFamily,
            fontFamilyFallback: const <String>[
              'PingFang SC',
              'Microsoft YaHei',
              'Noto Sans CJK SC',
              'sans-serif',
            ],
          ),
          child: KeyboardListener(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            child: Scaffold(
              backgroundColor: const Color(0xFF101112),
              body: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints constraints) {
                  final double previousWidth = _viewportWidth;
                  _viewportWidth = constraints.maxWidth > 960
                      ? 960
                      : constraints.maxWidth;
                  _horizontalInset =
                      ((constraints.maxWidth - _viewportWidth) / 2).clamp(
                        0,
                        double.infinity,
                      );
                  _viewportHeight = constraints.maxHeight;
                  _topPadding = MediaQuery.paddingOf(context).top;
                  if (previousWidth > 0 &&
                      (previousWidth - _viewportWidth).abs() > .5 &&
                      _progress != null &&
                      !_restoring) {
                    final ComicReaderProgress anchor = _progress!;
                    _restoring = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_disposed) return;
                      _restorePosition(anchor);
                      _restoring = false;
                    });
                  }
                  return Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      _buildReadingSurface(palette),
                      IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withValues(
                            alpha: 1 - _preferences.brightness,
                          ),
                        ),
                      ),
                      _buildChrome(palette),
                      if (_loading && _window.isEmpty)
                        _buildLoadingOverlay(palette),
                      if (_failure != null && _window.isEmpty)
                        _buildFailureOverlay(palette),
                      if (_failure != null && _window.isNotEmpty)
                        _buildInlineFailure(palette),
                      if (_loading && _window.isNotEmpty)
                        const Align(
                          alignment: Alignment.topCenter,
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReadingSurface(ReaderPalette palette) {
    if (!_loading && _failure == null && _window.isEmpty) {
      return Center(
        child: Text(
          ComicReaderStrings.noChapters,
          style: TextStyle(color: palette.secondaryText),
        ),
      );
    }
    final List<_ComicListEntry> entries = _entries();
    return Listener(
      onPointerSignal: (PointerSignalEvent event) {
        if (event is PointerScrollEvent) _focusNode.requestFocus();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: (_) => _setControlsVisible(!_controlsVisible),
        child: ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(
            _horizontalInset,
            _topPadding,
            _horizontalInset,
            MediaQuery.paddingOf(context).bottom + 48,
          ),
          scrollCacheExtent: const ScrollCacheExtent.viewport(.7),
          itemCount: entries.length,
          itemExtentBuilder: (int index, _) => entries[index].extent,
          itemBuilder: (BuildContext context, int index) {
            final _ComicListEntry entry = entries[index];
            return switch (entry) {
              _ComicHeaderEntry() => _buildChapterHeader(entry, palette),
              _ComicImageEntry() => ComicProgressiveImageTile(
                key: ValueKey<String>(
                  '${entry.chapter.info.id}/${entry.image.id}/'
                  '${_contentEpochs[entry.chapter.info.id] ?? 0}',
                ),
                cache: _imageCache,
                chapterId: entry.chapter.info.id,
                image: entry.image,
                width: _viewportWidth,
                height: entry.imageExtent,
                spacing: entry.spacing,
                palette: palette,
                decodeBudget: _decodeBudget,
                bookId: widget.bookId,
                commentFeed: widget.commentFeed,
                onOpenComments: (ReaderCommentTarget target) =>
                    _showImageComments(target, palette),
                onFailure: (Object error) => unawaited(
                  _reportFailure(_asFailure(error, ReaderFailureKind.data)),
                ),
              ),
              _ComicBoundaryEntry() => _buildBoundary(entry, palette),
            };
          },
        ),
      ),
    );
  }

  Widget _buildChapterHeader(_ComicHeaderEntry entry, ReaderPalette palette) {
    return SizedBox(
      height: _chapterHeaderExtent,
      child: ColoredBox(
        color: const Color(0xFF151719),
        child: Center(
          child: Text(
            entry.chapter.info.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBoundary(_ComicBoundaryEntry entry, ReaderPalette palette) {
    return SizedBox(
      height: _boundaryExtent,
      child: Center(
        child: entry.atEnd
            ? Text(
                ComicReaderStrings.endOfBook,
                style: TextStyle(color: palette.secondaryText),
              )
            : entry.failure != null
            ? TextButton.icon(
                onPressed: () =>
                    unawaited(_loadAdjacent(entry.index, before: entry.before)),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text(ComicReaderStrings.retry),
              )
            : entry.loading
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: () =>
                    unawaited(_loadAdjacent(entry.index, before: entry.before)),
                child: const Text(ComicReaderStrings.loadMore),
              ),
      ),
    );
  }

  Widget _buildChrome(ReaderPalette palette) {
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 180),
        child: Stack(
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: SafeArea(
                bottom: false,
                child: Container(
                  height: 54,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: const BoxDecoration(
                    color: Color(0xE617191B),
                    border: Border(
                      bottom: BorderSide(color: Color(0x243A3D40)),
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      _chromeButton(
                        icon: Icons.arrow_back_rounded,
                        label: ComicReaderStrings.back,
                        onPressed: () => unawaited(_requestExit()),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _currentChapter?.title ?? _book?.title ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: palette.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      _chromeButton(
                        icon: Icons.bookmark_add_outlined,
                        label: ComicReaderStrings.addBookmark,
                        onPressed: () => unawaited(_addBookmark()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                child: Container(
                  height: 70,
                  decoration: const BoxDecoration(
                    color: Color(0xF2181A1C),
                    border: Border(top: BorderSide(color: Color(0x243A3D40))),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: <Widget>[
                      _bottomButton(
                        Icons.list_alt_rounded,
                        ComicReaderStrings.catalog,
                        _showCatalog,
                      ),
                      _bottomButton(
                        Icons.bookmarks_outlined,
                        ComicReaderStrings.bookmarks,
                        _showBookmarks,
                      ),
                      _bottomButton(
                        Icons.tune_rounded,
                        ComicReaderStrings.settings,
                        _showSettings,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chromeButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      tooltip: label,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }

  Widget _bottomButton(IconData icon, String label, VoidCallback onPressed) {
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 86,
          height: 58,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 22),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingOverlay(ReaderPalette palette) {
    return ColoredBox(
      color: const Color(0xFF101112),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(color: palette.accent, strokeWidth: 2),
            const SizedBox(height: 16),
            Text(
              ComicReaderStrings.loading,
              style: TextStyle(color: palette.secondaryText),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFailureOverlay(ReaderPalette palette) {
    return ColoredBox(
      color: const Color(0xFF101112),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.broken_image_outlined, color: palette.secondaryText),
            const SizedBox(height: 12),
            Text(
              ComicReaderStrings.chapterFailed,
              style: TextStyle(color: palette.text),
            ),
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: _currentChapter == null
                  ? () => unawaited(_restart())
                  : () => unawaited(_refreshCurrentChapter()),
              child: const Text(ComicReaderStrings.retry),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInlineFailure(ReaderPalette palette) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          margin: const EdgeInsets.fromLTRB(56, 8, 56, 0),
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(
            color: palette.panel.withValues(alpha: .96),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: palette.divider),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  ComicReaderStrings.chapterFailed,
                  style: TextStyle(color: palette.text, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: () => unawaited(_refreshCurrentChapter()),
                child: const Text(ComicReaderStrings.retry),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      unawaited(_requestExit());
      return;
    }
    if (!_scrollController.hasClients) return;
    final double delta = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => 72,
      LogicalKeyboardKey.arrowUp => -72,
      LogicalKeyboardKey.pageDown => _viewportHeight * .82,
      LogicalKeyboardKey.pageUp => -_viewportHeight * .82,
      _ => 0,
    };
    if (delta == 0) return;
    final double target = (_scrollController.offset + delta).clamp(
      0,
      _scrollController.position.maxScrollExtent,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Future<void> _addBookmark() async {
    final ComicReaderProgress? progress = _progress;
    final ComicChapterInfo? chapter = _currentChapter;
    if (progress == null || chapter == null) return;
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderStateStore store = widget.stateStore;
    final ComicReaderDataSource source = widget.dataSource;
    final DateTime now = DateTime.now();
    final ComicReaderBookmark bookmark = ComicReaderBookmark(
      id:
          '$bookId:${progress.chapterId}:${progress.imageId}:'
          '${now.microsecondsSinceEpoch}',
      bookId: bookId,
      chapterId: progress.chapterId,
      imageId: progress.imageId,
      imageFraction: progress.imageFraction,
      chapterTitle: chapter.title,
      createdAt: now,
    );
    setState(() {
      _bookmarks = List<ComicReaderBookmark>.unmodifiable(<ComicReaderBookmark>[
        ..._bookmarks,
        bookmark,
      ]);
    });
    unawaited(
      _enqueueStoreWrite(
        _bookmarkWrites,
        _BookStoreKey(store, bookId),
        () => store.addBookmark(bookmark),
        (Object error) {
          if (_isSession(session, bookId, source, store)) {
            setState(() {
              _bookmarks = List<ComicReaderBookmark>.unmodifiable(
                _bookmarks.where((item) => item.id != bookmark.id),
              );
            });
            unawaited(_reportFailure(_stateFailure(error)));
          }
        },
      ),
    );
  }

  Future<void> _removeBookmark(ComicReaderBookmark bookmark) async {
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderStateStore store = widget.stateStore;
    final ComicReaderDataSource source = widget.dataSource;
    setState(() {
      _bookmarks = List<ComicReaderBookmark>.unmodifiable(
        _bookmarks.where((item) => item.id != bookmark.id),
      );
    });
    unawaited(
      _enqueueStoreWrite(
        _bookmarkWrites,
        _BookStoreKey(store, bookId),
        () => store.removeBookmark(bookId, bookmark.id),
        (Object error) {
          if (_isSession(session, bookId, source, store)) {
            setState(() {
              if (_bookmarks.every((item) => item.id != bookmark.id)) {
                _bookmarks = List<ComicReaderBookmark>.unmodifiable(
                  <ComicReaderBookmark>[..._bookmarks, bookmark]
                    ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
                );
              }
            });
            unawaited(_reportFailure(_stateFailure(error)));
          }
        },
      ),
    );
  }

  void _showImageComments(ReaderCommentTarget target, ReaderPalette palette) {
    final ReaderCommentFeed? feed = widget.commentFeed;
    if (feed == null ||
        target.bookId != widget.bookId ||
        target.chapterId == null ||
        target.chapterId!.trim().isEmpty ||
        target.imageId == null ||
        target.imageId!.trim().isEmpty ||
        target.paragraphId != null) {
      return;
    }
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    final int sheetGeneration = _beginSheet();
    final Future<void> sheet = showReaderCommentsSheet(
      context: context,
      feed: feed,
      target: target,
      palette: palette,
      title: ReaderCommentStrings.title,
      onLoadError: (Object error) {
        if (_isSession(session, bookId, source, store) &&
            identical(feed, widget.commentFeed)) {
          unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
        }
      },
      onSheetBuilt: (BuildContext context) =>
          _captureSheetContext(context, sheetGeneration),
    );
    unawaited(sheet.whenComplete(() => _finishSheet(sheetGeneration)));
  }

  int _beginSheet() {
    _dismissSessionSheet();
    return ++_sheetGeneration;
  }

  void _captureSheetContext(BuildContext context, int generation) {
    if (generation == _sheetGeneration && !_disposed) {
      _activeSheetContext = context;
      return;
    }
    _popSheetAfterFrame(context);
  }

  void _finishSheet(int generation) {
    if (generation == _sheetGeneration) _activeSheetContext = null;
  }

  void _dismissSessionSheet() {
    _sheetGeneration++;
    final BuildContext? context = _activeSheetContext;
    _activeSheetContext = null;
    if (context != null) _popSheetAfterFrame(context);
  }

  void _popSheetAfterFrame(BuildContext sheetContext) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!sheetContext.mounted) return;
      final ModalRoute<Object?>? route = ModalRoute.of(sheetContext);
      if (route?.isCurrent ?? false) Navigator.of(sheetContext).pop();
    });
  }

  void _showCatalog() {
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    bool isCurrent() => _isSession(session, bookId, source, store);
    final int sheetGeneration = _beginSheet();
    _setControlsVisible(false);
    final Future<void> sheet = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF202326),
      builder: (BuildContext sheetContext) {
        _captureSheetContext(sheetContext, sheetGeneration);
        return StatefulBuilder(
          builder:
              (
                BuildContext context,
                void Function(VoidCallback) sheetSetState,
              ) {
                return _darkSheet(
                  SafeArea(
                    child: SizedBox(
                      height: MediaQuery.sizeOf(context).height * .76,
                      child: Column(
                        children: <Widget>[
                          _sheetHeader(ComicReaderStrings.catalog),
                          Expanded(
                            child: ListView.builder(
                              itemCount:
                                  _catalog.length +
                                  (_catalogHasMore || _catalogLoading ? 1 : 0),
                              itemBuilder: (BuildContext context, int index) {
                                if (index == _catalog.length) {
                                  return SizedBox(
                                    height: 64,
                                    child: Center(
                                      child: _catalogLoading
                                          ? const CircularProgressIndicator(
                                              strokeWidth: 2,
                                            )
                                          : TextButton(
                                              onPressed: () async {
                                                if (!isCurrent()) {
                                                  if (sheetContext.mounted) {
                                                    Navigator.of(
                                                      sheetContext,
                                                    ).pop();
                                                  }
                                                  return;
                                                }
                                                await _loadNextCatalogPage();
                                                if (sheetContext.mounted &&
                                                    isCurrent()) {
                                                  sheetSetState(() {});
                                                }
                                              },
                                              child: const Text(
                                                ComicReaderStrings.loadMore,
                                              ),
                                            ),
                                    ),
                                  );
                                }
                                final ComicChapterInfo chapter =
                                    _catalog[index];
                                return ListTile(
                                  minTileHeight: 52,
                                  selected: chapter.id == _currentChapter?.id,
                                  title: Text(
                                    chapter.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(_chapterStatus(chapter)),
                                  onTap: () {
                                    if (!isCurrent()) {
                                      Navigator.of(context).pop();
                                      return;
                                    }
                                    Navigator.of(context).pop();
                                    unawaited(
                                      _openChapterInfo(
                                        chapter,
                                        replaceWindow: true,
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
        );
      },
    );
    unawaited(sheet.whenComplete(() => _finishSheet(sheetGeneration)));
  }

  String _chapterStatus(ComicChapterInfo chapter) {
    final String count = chapter.imageCount == null
        ? ''
        : ComicReaderStrings.imageCount(chapter.imageCount!);
    final String read = chapter.hasBeenRead
        ? ComicReaderStrings.read
        : ComicReaderStrings.unread;
    final String availability = switch (chapter.availability) {
      ReaderChapterAvailability.downloaded => ComicReaderStrings.cached,
      ReaderChapterAvailability.downloading => ComicReaderStrings.loadingStatus,
      ReaderChapterAvailability.notDownloaded => ComicReaderStrings.notCached,
      ReaderChapterAvailability.failed => ComicReaderStrings.failedStatus,
      ReaderChapterAvailability.unknown => '',
    };
    return <String>[
      count,
      read,
      availability,
    ].where((value) => value.isNotEmpty).join(' · ');
  }

  void _showBookmarks() {
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    bool isCurrent() => _isSession(session, bookId, source, store);
    final int sheetGeneration = _beginSheet();
    _setControlsVisible(false);
    final Future<void> sheet = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF202326),
      builder: (BuildContext context) {
        _captureSheetContext(context, sheetGeneration);
        return _darkSheet(
          SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .7,
              child: Column(
                children: <Widget>[
                  _sheetHeader(ComicReaderStrings.bookmarks),
                  Expanded(
                    child: _bookmarks.isEmpty
                        ? const Center(
                            child: Text(ComicReaderStrings.noBookmarks),
                          )
                        : ListView.builder(
                            itemCount: _bookmarks.length,
                            itemBuilder: (BuildContext context, int index) {
                              final ComicReaderBookmark bookmark =
                                  _bookmarks[index];
                              return ListTile(
                                minTileHeight: 56,
                                title: Text(bookmark.chapterTitle),
                                subtitle: Text(
                                  ComicReaderStrings.imageProgress(
                                    bookmark.imageId,
                                    (bookmark.imageFraction * 100).round(),
                                  ),
                                ),
                                trailing: IconButton(
                                  tooltip: ComicReaderStrings.removeBookmark,
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                  ),
                                  onPressed: () {
                                    if (!isCurrent()) {
                                      Navigator.of(context).pop();
                                      return;
                                    }
                                    Navigator.of(context).pop();
                                    unawaited(_removeBookmark(bookmark));
                                  },
                                ),
                                onTap: () {
                                  if (!isCurrent()) {
                                    Navigator.of(context).pop();
                                    return;
                                  }
                                  Navigator.of(context).pop();
                                  unawaited(_openBookmark(bookmark));
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    unawaited(sheet.whenComplete(() => _finishSheet(sheetGeneration)));
  }

  Future<void> _openBookmark(ComicReaderBookmark bookmark) async {
    ComicChapterInfo? chapter = _catalogById[bookmark.chapterId];
    while (chapter == null && _catalogHasMore && !_disposed) {
      if (!await _loadNextCatalogPage()) break;
      chapter = _catalogById[bookmark.chapterId];
    }
    if (chapter == null) return;
    await _openChapterInfo(
      chapter,
      restore: ComicReaderProgress(
        chapterId: bookmark.chapterId,
        imageId: bookmark.imageId,
        imageFraction: bookmark.imageFraction,
        chapterIndex: chapter.index,
      ),
      replaceWindow: true,
    );
  }

  void _showSettings() {
    final int session = _sessionGeneration;
    final String bookId = widget.bookId;
    final ComicReaderDataSource source = widget.dataSource;
    final ComicReaderStateStore store = widget.stateStore;
    bool isCurrent() => _isSession(session, bookId, source, store);
    final int sheetGeneration = _beginSheet();
    _setControlsVisible(false);
    final Future<void> sheet = showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF202326),
      builder: (BuildContext context) {
        _captureSheetContext(context, sheetGeneration);
        return StatefulBuilder(
          builder:
              (
                BuildContext context,
                void Function(VoidCallback) sheetSetState,
              ) {
                void update(
                  ComicReaderPreferences value, {
                  bool persist = true,
                }) {
                  if (!isCurrent()) {
                    Navigator.of(context).pop();
                    return;
                  }
                  final ComicReaderPreferences normalized = value.normalized();
                  final ComicReaderProgress? anchor = _progress;
                  final bool layoutChanged =
                      normalized.imageSpacing != _preferences.imageSpacing;
                  setState(() {
                    _preferences = normalized;
                    _preferencesAuthoritative = true;
                  });
                  _preferencesDirty = !persist;
                  sheetSetState(() {});
                  if (layoutChanged) {
                    _restoring = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_disposed) return;
                      _restorePosition(anchor);
                      _restoring = false;
                    });
                  }
                  unawaited(_syncAwake());
                  if (persist) {
                    unawaited(_savePreferences(normalized, store: store));
                  }
                }

                void commit() {
                  if (!isCurrent()) return;
                  _preferencesDirty = false;
                  unawaited(_savePreferences(_preferences, store: store));
                }

                return _darkSheet(
                  SafeArea(
                    child: SizedBox(
                      height: MediaQuery.sizeOf(context).height * .55,
                      child: Column(
                        children: <Widget>[
                          _sheetHeader(ComicReaderStrings.settings),
                          Expanded(
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
                              children: <Widget>[
                                _settingSlider(
                                  label: ComicReaderStrings.brightness,
                                  value: _preferences.brightness,
                                  min: .25,
                                  max: 1,
                                  onChanged: (double value) => update(
                                    ComicReaderPreferences(
                                      brightness: value,
                                      keepScreenOn: _preferences.keepScreenOn,
                                      immersiveMode: _preferences.immersiveMode,
                                      imageSpacing: _preferences.imageSpacing,
                                    ),
                                    persist: false,
                                  ),
                                  onChangeEnd: (double value) => commit(),
                                ),
                                _settingSlider(
                                  label: ComicReaderStrings.spacing,
                                  value: _preferences.imageSpacing,
                                  min: 0,
                                  max: 24,
                                  divisions: 6,
                                  onChanged: (double value) => update(
                                    ComicReaderPreferences(
                                      brightness: _preferences.brightness,
                                      keepScreenOn: _preferences.keepScreenOn,
                                      immersiveMode: _preferences.immersiveMode,
                                      imageSpacing: value,
                                    ),
                                    persist: false,
                                  ),
                                  onChangeEnd: (double value) => commit(),
                                ),
                                if (_platformCapabilities.keepScreenOn)
                                  SwitchListTile.adaptive(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text(
                                      ComicReaderStrings.keepAwake,
                                    ),
                                    value: _preferences.keepScreenOn,
                                    onChanged: (bool value) => update(
                                      ComicReaderPreferences(
                                        brightness: _preferences.brightness,
                                        keepScreenOn: value,
                                        immersiveMode:
                                            _preferences.immersiveMode,
                                        imageSpacing: _preferences.imageSpacing,
                                      ),
                                    ),
                                  ),
                                if (_platformCapabilities.immersiveMode)
                                  SwitchListTile.adaptive(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text(
                                      ComicReaderStrings.immersive,
                                    ),
                                    value: _preferences.immersiveMode,
                                    onChanged: (bool value) => update(
                                      ComicReaderPreferences(
                                        brightness: _preferences.brightness,
                                        keepScreenOn: _preferences.keepScreenOn,
                                        immersiveMode: value,
                                        imageSpacing: _preferences.imageSpacing,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
        );
      },
    );
    unawaited(
      sheet.whenComplete(() {
        _finishSheet(sheetGeneration);
        if (isCurrent()) {
          _preferencesDirty = false;
          unawaited(_savePreferences(_preferences, store: store));
        }
      }),
    );
  }

  Widget _settingSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          SizedBox(width: 76, child: Text(label)),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
        ],
      ),
    );
  }

  Widget _darkSheet(Widget child) {
    final ReaderPalette palette = ReaderPalette.fromPreset(
      ReaderThemePreset.deepNight,
    );
    return Theme(
      data: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: Brightness.dark,
          surface: const Color(0xFF202326),
        ),
        scaffoldBackgroundColor: const Color(0xFF202326),
        fontFamily: readerDefaultFontFamily,
        fontFamilyFallback: const <String>[
          'PingFang SC',
          'Microsoft YaHei',
          'Noto Sans CJK SC',
          'sans-serif',
        ],
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: palette.text,
          displayColor: palette.text,
        ),
        iconTheme: IconThemeData(color: palette.text),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: palette.text),
        child: child,
      ),
    );
  }

  Widget _sheetHeader(String title) {
    return SizedBox(
      height: 52,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 20),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 20),
        ],
      ),
    );
  }
}

class _LoadedComicChapter {
  const _LoadedComicChapter(this.info, this.content);
  final ComicChapterInfo info;
  final ComicChapterContent content;
}

sealed class _ComicListEntry {
  const _ComicListEntry();
  double get extent;
}

class _ComicHeaderEntry extends _ComicListEntry {
  const _ComicHeaderEntry(this.chapter);
  final _LoadedComicChapter chapter;
  @override
  double get extent => _ComicReaderViewState._chapterHeaderExtent;
}

class _ComicImageEntry extends _ComicListEntry {
  const _ComicImageEntry(
    this.chapter,
    this.image, {
    required this.imageExtent,
    required this.spacing,
  });
  final _LoadedComicChapter chapter;
  final ComicImageInfo image;
  final double imageExtent;
  final double spacing;
  @override
  double get extent => imageExtent + spacing;
}

class _ComicBoundaryEntry extends _ComicListEntry {
  const _ComicBoundaryEntry({
    required this.index,
    required this.loading,
    required this.failure,
    required this.atEnd,
    required this.before,
  });
  final int index;
  final bool loading;
  final ReaderFailure? failure;
  final bool atEnd;
  final bool before;
  @override
  double get extent => _ComicReaderViewState._boundaryExtent;
}

class _Result<T> {
  const _Result({this.value, this.error});
  final T? value;
  final Object? error;
}

class _BookStoreKey {
  const _BookStoreKey(this.store, this.bookId);

  final ComicReaderStateStore store;
  final String bookId;

  @override
  bool operator ==(Object other) =>
      other is _BookStoreKey &&
      identical(store, other.store) &&
      bookId == other.bookId;

  @override
  int get hashCode => Object.hash(identityHashCode(store), bookId);
}
