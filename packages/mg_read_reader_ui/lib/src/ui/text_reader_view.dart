import 'dart:async';
import 'dart:collection';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/contracts.dart';
import '../api/controller.dart';
import '../api/models.dart';
import '../core/auto_reading_coordinator.dart';
import '../core/chapter_access_coordinator.dart';
import '../pagination/text_paginator.dart';
import '../platform/reader_platform.dart';
import '../platform/screen_awake_coordinator.dart';
import 'comments/reader_comment_strings.dart';
import 'comments/reader_comment_widgets.dart';
import 'chapter/reader_chapter_state_badge.dart';
import 'effects/reader_page_effect.dart';
import 'fonts/reader_font_controller.dart';
import 'reader_strings.dart';
import 'reader_theme.dart';
import 'settings/reader_settings_sheet.dart';
import 'settings/reader_settings_tokens.dart';

/// A complete, embeddable text reading surface.
///
/// The host supplies content and persistence interfaces. Navigation out of the
/// reader is reported through [ReaderObserver.onExitRequested].
class TextReaderView extends StatefulWidget {
  /// Creates an embeddable reader connected to host data and persistence.
  const TextReaderView({
    super.key,
    required this.bookId,
    required this.dataSource,
    required this.stateStore,
    this.observer,
    this.controller,
    this.extensions = const ReaderExtensions(),
  });

  /// Stable host identifier for the book being read.
  final String bookId;

  /// Asynchronous source for metadata, catalog, and chapter content.
  final TextReaderDataSource dataSource;

  /// Host-owned persistence for progress, preferences, and bookmarks.
  final TextReaderStateStore stateStore;

  /// Optional notification sink for lifecycle, errors, and exit requests.
  final ReaderObserver? observer;

  /// Optional host-owned command controller; internally created when absent.
  final TextReaderController? controller;

  /// Optional capabilities such as the read-only comment feed.
  final ReaderExtensions extensions;

  @override
  State<TextReaderView> createState() => _TextReaderViewState();
}

class _TextReaderViewState extends State<TextReaderView> {
  static const Duration _saveDelay = Duration(milliseconds: 800);
  static const int _chapterCacheLimit = 2;
  static const int _commentSummaryBatchSize = 100;
  static const int _chapterStateBatchSize = 100;
  static const int _paragraphKeyCacheLimit = 256;
  static const int _verticalRestoreMeasureBatchSize = 128;
  static const double _pageFooterBottomInset = 10;
  // TextPainter measures fractional line heights, while RenderParagraph rounds
  // their painted extent to device pixels. Keep a small reserve so a page that
  // exactly fits during pagination cannot overflow by a rounding pixel.
  static const double _horizontalPageLayoutSafety = 30;
  static const double _mouseTapSlop = 18;
  // PointerEvent.buttons uses a bit mask; 1 denotes the primary mouse button.
  static const int _primaryMouseButton = 1;
  static const double _inlineCommentHitSize = 48;
  static const double _inlineCommentVisualSize = 30;

  final TextPaginator _paginator = const TextPaginator();
  final Object _awakeHolder = Object();
  final Object _controllerBindingOwner = Object();
  final FocusNode _focusNode = FocusNode(debugLabel: 'TextReader');
  final ScrollController _verticalController = ScrollController();
  final LinkedHashMap<String, TextChapterContent> _chapterCache =
      LinkedHashMap<String, TextChapterContent>();
  final Map<String, Future<TextChapterContent>> _chapterLoads =
      <String, Future<TextChapterContent>>{};
  final Map<String, GlobalKey> _paragraphKeys = <String, GlobalKey>{};
  final Map<ReaderCommentTarget, ReaderCommentSummary> _commentSummaries =
      <ReaderCommentTarget, ReaderCommentSummary>{};
  List<double?> _verticalItemExtents = const <double?>[];
  TextChapterContent? _verticalExtentContent;
  TextReaderPreferences? _verticalExtentPreferences;
  TextScaler? _verticalExtentTextScaler;
  TextDirection? _verticalExtentTextDirection;
  double _verticalExtentWidth = 0;
  bool _verticalExtentHasParagraphComments = false;
  bool _verticalExtentHasChapterComments = false;
  bool _commentSummariesLoading = false;
  bool _commentSummariesFailed = false;
  ReaderChapterAccessCoordinator? _chapterAccessCoordinator;
  Object? _reportedChapterAccessFailure;
  int _chapterStateRefreshGeneration = 0;

  late TextReaderController _controller;
  late bool _ownsController;
  late AppLifecycleListener _lifecycleListener;
  late final ReaderAutoReadingCoordinator _autoReadingCoordinator;
  final PageController _pageController = PageController(initialPage: 1);
  Timer? _saveTimer;
  Timer? _noticeTimer;
  Timer? _clockTimer;
  Timer? _wheelResetTimer;

  ReaderBookInfo? _book;
  final List<ReaderChapterInfo> _catalog = <ReaderChapterInfo>[];
  final Map<String, ReaderChapterInfo> _catalogById =
      <String, ReaderChapterInfo>{};
  final Map<int, ReaderChapterInfo> _catalogByIndex =
      <int, ReaderChapterInfo>{};
  final Set<String> _catalogPageIds = <String>{};
  String? _catalogCursor;
  int _catalogTotal = 0;
  bool _catalogHasMore = false;
  bool _catalogLoading = false;
  bool _pageTurnAnimating = false;
  TextChapterContent? _content;
  ReaderChapterInfo? _currentChapterInfo;
  List<ReaderPage> _pages = const <ReaderPage>[];
  List<ReaderBookmark> _bookmarks = const <ReaderBookmark>[];
  TextReaderPreferences _preferences = TextReaderPreferences.defaults;
  ReaderProgress? _progress;
  ReaderFailure? _failure;
  Size? _layoutSize;
  TextScaler? _layoutTextScaler;
  int _chapterIndex = -1;
  int _pageIndex = 0;
  int _requestGeneration = 0;
  int _sessionGeneration = 0;
  int _commentGeneration = 0;
  int _navigationGeneration = 0;
  int _verticalRestoreGeneration = 0;
  bool _loading = true;
  bool _controlsVisible = false;
  bool _foreground = true;
  ReaderLifecycleState _lifecycleState = ReaderLifecycleState.foreground;
  ReaderPlatformCapabilities _platformCapabilities =
      const ReaderPlatformCapabilities();
  Future<void> _awakeWrite = Future<void>.value();
  Future<void> _bookmarkWrite = Future<void>.value();
  final Map<TextReaderStateStore, Future<void>> _preferenceWritesByStore =
      Map<TextReaderStateStore, Future<void>>.identity();
  final Map<TextReaderStateStore, Map<String, Future<void>>>
  _progressWritesByStore =
      Map<TextReaderStateStore, Map<String, Future<void>>>.identity();
  Future<void>? _exitRequest;
  TextReaderPreferences? _lastSavedPreferences;
  TextReaderStateStore? _lastPreferenceStore;
  ReaderProgress? _lastSavedProgress;
  TextReaderStateStore? _lastProgressStore;
  String? _lastProgressBookId;
  bool _preferencesPreviewDirty = false;
  bool _changingChapter = false;
  bool _disposed = false;
  bool _autoScrolling = false;
  bool _restoringVerticalAnchor = false;
  bool _restoringHorizontalAnchor = false;
  bool _pageTurnForward = true;
  double _directDragDelta = 0;
  int? _mouseTapPointer;
  Offset? _mouseTapDownPosition;
  bool _mouseTapMoved = false;
  double? _sliderPreview;
  double _wheelDelta = 0;
  String? _noticeMessage;
  DateTime _clock = DateTime.now();
  ReaderAutoReadingPace _autoReadingPace = ReaderAutoReadingPace.normal;
  ReaderThemePreset _lastNonNightTheme = ReaderThemePreset.day;
  TextScaler? _dependencyTextScaler;
  String? _runtimeFontFamily;
  ReaderFontDescriptor? _runtimeFontDescriptor;
  int _fontLoadGeneration = 0;

  ReaderObserver get _observer => widget.observer ?? const ReaderObserver();
  ReaderPalette get _palette => ReaderPalette.fromPreset(_preferences.theme);
  ReaderChapterInfo? get _currentChapter => _currentChapterInfo;
  bool get _isBookPreview =>
      !_loading && _failure == null && _progress?.isBookPreview == true;
  TextScaler get _textScaler => MediaQuery.textScalerOf(
    context,
  ).clamp(minScaleFactor: .85, maxScaleFactor: 1.3);
  String _indented(String text) => '${'　' * _preferences.firstLineIndent}$text';

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextReaderController();
    _autoReadingCoordinator = ReaderAutoReadingCoordinator(
      onNextPage: _autoAdvancePage,
      onScrollBy: _autoScrollBy,
      onRunningChanged: (bool running) {
        if (!mounted || _disposed) return;
        setState(() {});
        _publishSnapshot();
      },
      onError: (Object error) => unawaited(
        _reportFailure(_asFailure(error, ReaderFailureKind.unknown)),
      ),
    );
    _configureChapterAccessCoordinator();
    _bindController();
    _verticalController.addListener(_handleVerticalScroll);
    _lifecycleListener = AppLifecycleListener(onStateChange: _handleLifecycle);
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _clock = DateTime.now());
    });
    unawaited(_loadPlatformCapabilities());
    unawaited(_initialize());
  }

  Future<void> _loadPlatformCapabilities() async {
    try {
      final ReaderPlatformCapabilities capabilities = await ReaderPlatform
          .instance
          .capabilities();
      if (_disposed) return;
      setState(() => _platformCapabilities = capabilities);
      await _syncAwake();
    } catch (error) {
      if (_disposed) return;
      await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
    }
  }

  void _configureChapterAccessCoordinator() {
    final ReaderChapterStateCapability? capability =
        widget.extensions.chapterStateCapability;
    final ReaderChapterAccessCoordinator? current = _chapterAccessCoordinator;
    _chapterStateRefreshGeneration++;
    _reportedChapterAccessFailure = null;
    if (capability == null) {
      current
        ?..removeListener(_handleChapterAccessChange)
        ..dispose();
      _chapterAccessCoordinator = null;
      return;
    }
    if (current == null) {
      _chapterAccessCoordinator = ReaderChapterAccessCoordinator(
        bookId: widget.bookId,
        capability: capability,
      )..addListener(_handleChapterAccessChange);
    } else {
      current.rebind(bookId: widget.bookId, capability: capability);
    }
    unawaited(_refreshLoadedChapterStates());
  }

  void _handleChapterAccessChange() {
    if (!mounted || _disposed) return;
    final Object? failure = _chapterAccessCoordinator?.snapshot.failure;
    if (failure == null) {
      _reportedChapterAccessFailure = null;
    } else if (!identical(failure, _reportedChapterAccessFailure)) {
      _reportedChapterAccessFailure = failure;
      unawaited(_reportFailure(_asFailure(failure, ReaderFailureKind.data)));
    }
    setState(() {});
  }

  Future<void> _refreshLoadedChapterStates({String? chapterId}) async {
    final ReaderChapterAccessCoordinator? coordinator =
        _chapterAccessCoordinator;
    if (coordinator == null || _disposed) return;
    final int refreshGeneration = ++_chapterStateRefreshGeneration;
    final List<String> ids = chapterId == null
        ? _catalog.map((ReaderChapterInfo chapter) => chapter.id).toList()
        : <String>[chapterId];
    for (var start = 0; start < ids.length; start += _chapterStateBatchSize) {
      if (_disposed ||
          refreshGeneration != _chapterStateRefreshGeneration ||
          !identical(coordinator, _chapterAccessCoordinator)) {
        return;
      }
      final int end = (start + _chapterStateBatchSize).clamp(0, ids.length);
      await coordinator.refresh(ids.sublist(start, end));
    }
  }

  Future<void> _recordChapterOpened(String chapterId) async {
    final ReaderChapterAccessCoordinator? coordinator =
        _chapterAccessCoordinator;
    if (coordinator == null) return;
    await _refreshLoadedChapterStates(chapterId: chapterId);
    if (_disposed || !identical(coordinator, _chapterAccessCoordinator)) {
      return;
    }
    await coordinator.markRead(chapterId);
  }

  @override
  void didUpdateWidget(covariant TextReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.unbind(_controllerBindingOwner);
      if (_ownsController) _controller.dispose();
      _ownsController = widget.controller == null;
      _controller = widget.controller ?? TextReaderController();
      _bindController();
      _publishSnapshot();
    }
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.dataSource != widget.dataSource ||
        oldWidget.stateStore != widget.stateStore) {
      final List<Future<void>> persistenceBarriers = <Future<void>>[];
      final bool sameStore = identical(oldWidget.stateStore, widget.stateStore);
      final ReaderProgress? previousProgress = _progress;
      if (previousProgress != null) {
        final Future<void> progressSave = _queueProgressSave(
          store: oldWidget.stateStore,
          bookId: oldWidget.bookId,
          progress: previousProgress,
        );
        if (sameStore && oldWidget.bookId == widget.bookId) {
          persistenceBarriers.add(progressSave);
        }
      }
      if (_preferencesPreviewDirty) {
        _preferencesPreviewDirty = false;
        final Future<void> preferenceSave = _queuePreferencesSave(
          store: oldWidget.stateStore,
          preferences: _preferences,
        );
        if (sameStore) persistenceBarriers.add(preferenceSave);
      }
      if (sameStore) {
        final Future<void>? pendingPreferenceWrite =
            _preferenceWritesByStore[oldWidget.stateStore];
        if (pendingPreferenceWrite != null &&
            !persistenceBarriers.contains(pendingPreferenceWrite)) {
          persistenceBarriers.add(pendingPreferenceWrite);
        }
      }
      unawaited(
        _restart(
          persistenceCheckpoint: persistenceBarriers.isEmpty
              ? null
              : Future.wait<void>(persistenceBarriers),
        ),
      );
    }
    if (oldWidget.bookId != widget.bookId ||
        !identical(
          oldWidget.extensions.chapterStateCapability,
          widget.extensions.chapterStateCapability,
        )) {
      _configureChapterAccessCoordinator();
    }
    if (!identical(
      oldWidget.extensions.fontRepository,
      widget.extensions.fontRepository,
    )) {
      _runtimeFontFamily = null;
      _runtimeFontDescriptor = null;
      _layoutSize = null;
      unawaited(_loadPersistedCustomFont());
    }
    if (oldWidget.extensions.commentFeed != widget.extensions.commentFeed) {
      _layoutSize = null;
      if (mounted) setState(() {});
      unawaited(_refreshCommentSummaries());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final TextScaler nextScaler = _textScaler;
    final TextScaler? previousScaler = _dependencyTextScaler;
    _dependencyTextScaler = nextScaler;
    if (previousScaler == null || previousScaler == nextScaler) return;
    _layoutSize = null;
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      _scheduleVerticalRestore(paragraphId: _progress?.paragraphId);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _fontLoadGeneration++;
    _chapterStateRefreshGeneration++;
    _chapterAccessCoordinator
      ?..removeListener(_handleChapterAccessChange)
      ..dispose();
    _stopAutoReading();
    _commitPreferencePreview();
    final ReaderObserver observer = _observer;
    final String bookId = widget.bookId;
    final ReaderProgress? progress = _progress;
    final ReaderProgress? finalProgress = _progress;
    if (finalProgress != null) {
      unawaited(
        _queueProgressSave(
          store: widget.stateStore,
          bookId: widget.bookId,
          progress: finalProgress,
        ),
      );
    }
    _autoReadingCoordinator.dispose();
    _requestGeneration++;
    _sessionGeneration++;
    _navigationGeneration++;
    _saveTimer?.cancel();
    _noticeTimer?.cancel();
    _clockTimer?.cancel();
    _wheelResetTimer?.cancel();
    unawaited(_releaseAwake());
    unawaited(_notify(() => observer.onSessionEnded(bookId, progress)));
    _lifecycleListener.dispose();
    _verticalController
      ..removeListener(_handleVerticalScroll)
      ..dispose();
    _pageController.dispose();
    _focusNode.dispose();
    _controller.unbind(_controllerBindingOwner);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _bindController() {
    _controller.bind(
      owner: _controllerBindingOwner,
      openChapter: (String id) => _openChapter(id),
      nextPage: _nextPage,
      previousPage: _previousPage,
      nextChapter: _nextChapter,
      previousChapter: _previousChapter,
      showBookPreview: _showBookPreview,
      toggleControls: () async => _setControlsVisible(!_controlsVisible),
      showControls: () async => _setControlsVisible(true),
      hideControls: () async => _setControlsVisible(false),
      refresh: () =>
          _openChapter(_content?.chapterId ?? '', forceRefresh: true),
      startAutoReading: _startAutoReading,
      stopAutoReading: () async => _stopAutoReading(),
      toggleAutoReading: _toggleAutoReading,
    );
  }

  Future<void> _restart({Future<void>? persistenceCheckpoint}) async {
    _stopAutoReading();
    _requestGeneration++;
    final int generation = ++_sessionGeneration;
    _navigationGeneration++;
    _commentGeneration++;
    _fontLoadGeneration++;
    _chapterStateRefreshGeneration++;
    _saveTimer?.cancel();
    _chapterCache.clear();
    _chapterLoads.clear();
    _commentSummaries.clear();
    _commentSummariesLoading = false;
    _commentSummariesFailed = false;
    _catalog.clear();
    _catalogById.clear();
    _catalogByIndex.clear();
    _catalogPageIds.clear();
    _book = null;
    _bookmarks = const <ReaderBookmark>[];
    _catalogCursor = null;
    _catalogTotal = 0;
    _catalogHasMore = false;
    _catalogLoading = false;
    _content = null;
    _currentChapterInfo = null;
    _pages = const <ReaderPage>[];
    _progress = null;
    _failure = null;
    _layoutSize = null;
    _layoutTextScaler = null;
    _runtimeFontFamily = null;
    _runtimeFontDescriptor = null;
    _chapterIndex = -1;
    _pageIndex = 0;
    _changingChapter = false;
    _controlsVisible = false;
    _sliderPreview = null;
    _noticeMessage = null;
    _wheelDelta = 0;
    _wheelResetTimer?.cancel();
    _loading = true;
    if (mounted) setState(() {});
    unawaited(_releaseAwake());
    if (persistenceCheckpoint != null) await persistenceCheckpoint;
    if (!_isSessionCurrent(generation)) return;
    await _initialize();
  }

  Future<void> _initialize() async {
    final int generation = ++_sessionGeneration;
    final ReaderObserver observer = _observer;
    final String bookId = widget.bookId;
    if (mounted) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }

    try {
      final Future<ReaderBookInfo> bookFuture = widget.dataSource.loadBookInfo(
        widget.bookId,
      );
      final Future<ChapterCatalogPage> catalogFuture = widget.dataSource
          .loadChapterCatalog(widget.bookId);
      final Future<ReaderProgress?> progressFuture = _safeLoadProgress(
        generation,
        observer,
      );
      final Future<TextReaderPreferences> preferencesFuture =
          _safeLoadPreferences(generation, observer);
      final Future<List<ReaderBookmark>> bookmarksFuture = _safeLoadBookmarks(
        generation,
        observer,
      );

      final List<dynamic> results = await Future.wait<dynamic>(
        <Future<dynamic>>[
          bookFuture,
          catalogFuture,
          progressFuture,
          preferencesFuture,
          bookmarksFuture,
        ],
      );
      if (!_isSessionCurrent(generation)) return;

      _book = results[0] as ReaderBookInfo;
      _mergeCatalog(results[1] as ChapterCatalogPage);
      _progress =
          results[2] as ReaderProgress? ?? const ReaderProgress.bookPreview();
      _preferences = results[3] as TextReaderPreferences;
      unawaited(_loadPersistedCustomFont());
      if (!_isNightTheme(_preferences.theme)) {
        _lastNonNightTheme = _preferences.theme;
      }
      _bookmarks = results[4] as List<ReaderBookmark>;

      if (_progress!.isBookPreview) {
        _content = null;
        _currentChapterInfo = null;
        _chapterIndex = -1;
      } else {
        if (_catalogTotal <= 0) {
          throw const ReaderFailure(
            ReaderFailureKind.data,
            ReaderStrings.savedProgressWithoutChapters,
          );
        }
        ReaderChapterInfo? target = _catalogById[_progress!.chapterId];
        target ??= await _chapterInfoAtIndex(_progress!.chapterIndex);
        if (!_isSessionCurrent(generation)) return;
        await _openChapter(target.id, initial: true);
        if (!_isSessionCurrent(generation)) return;
      }
      _loading = false;
      _failure = null;
      if (mounted) setState(() {});
      await _syncAwake();
      if (!_isSessionCurrent(generation)) return;
      unawaited(_notify(() => observer.onSessionStarted(bookId)));
      _publishSnapshot();
      unawaited(_refreshCommentSummaries());
    } catch (error) {
      if (!_isSessionCurrent(generation)) return;
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      if (mounted) {
        setState(() {
          _loading = false;
          _failure = failure;
        });
      }
      _publishSnapshot();
      await _reportFailure(failure);
    }
  }

  Future<ReaderProgress?> _safeLoadProgress(
    int generation,
    ReaderObserver observer,
  ) async {
    final TextReaderStateStore store = widget.stateStore;
    final String bookId = widget.bookId;
    try {
      return await store.loadProgress(bookId);
    } catch (error) {
      if (_isSessionCurrent(generation)) {
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
      return null;
    }
  }

  Future<TextReaderPreferences> _safeLoadPreferences(
    int generation,
    ReaderObserver observer,
  ) async {
    final TextReaderStateStore store = widget.stateStore;
    try {
      return (await store.loadPreferences() ?? TextReaderPreferences.defaults)
          .normalized();
    } catch (error) {
      if (_isSessionCurrent(generation)) {
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
      return TextReaderPreferences.defaults;
    }
  }

  Future<List<ReaderBookmark>> _safeLoadBookmarks(
    int generation,
    ReaderObserver observer,
  ) async {
    final TextReaderStateStore store = widget.stateStore;
    final String bookId = widget.bookId;
    try {
      return List.unmodifiable(await store.loadBookmarks(bookId));
    } catch (error) {
      if (_isSessionCurrent(generation)) {
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
      return const <ReaderBookmark>[];
    }
  }

  void _mergeCatalog(ChapterCatalogPage page) {
    final bool firstPage = _catalogPageIds.isEmpty && _catalogCursor == null;
    final String? nextCursor = page.nextCursor;
    if (page.total < 0 ||
        page.items.length > page.total ||
        (!firstPage && page.total != _catalogTotal) ||
        (page.hasMore &&
            (page.items.isEmpty ||
                nextCursor == null ||
                nextCursor.trim().isEmpty ||
                nextCursor == _catalogCursor)) ||
        (!page.hasMore && nextCursor != null)) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }

    var expectedIndex = _catalogPageIds.length;
    final Set<String> pageIds = <String>{};
    final Set<int> pageIndexes = <int>{};
    for (final ReaderChapterInfo item in page.items) {
      if (item.id.trim().isEmpty ||
          item.index < 0 ||
          item.index >= page.total ||
          item.index != expectedIndex ||
          !pageIds.add(item.id) ||
          !pageIndexes.add(item.index)) {
        throw const ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.invalidChapterLocation,
        );
      }
      expectedIndex++;
      if (_catalogPageIds.contains(item.id)) {
        throw const ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.invalidChapterLocation,
        );
      }
      final ReaderChapterInfo? sameId = _catalogById[item.id];
      final ReaderChapterInfo? sameIndex = _catalogByIndex[item.index];
      if ((sameId != null && sameId.index != item.index) ||
          (sameIndex != null && sameIndex.id != item.id)) {
        throw const ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.invalidChapterLocation,
        );
      }
    }
    if (!page.hasMore &&
        _catalogPageIds.length + page.items.length != page.total) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }
    _catalog.addAll(page.items);
    for (final ReaderChapterInfo item in page.items) {
      _catalogById[item.id] = item;
      _catalogByIndex[item.index] = item;
    }
    _catalogPageIds.addAll(page.items.map((ReaderChapterInfo item) => item.id));
    _catalogCursor = page.nextCursor;
    _catalogTotal = page.total;
    _catalogHasMore = page.hasMore;
    unawaited(_refreshLoadedChapterStates());
  }

  Future<ReaderChapterInfo> _chapterInfoAtIndex(int index) async {
    if (index < 0 || (_catalogTotal > 0 && index >= _catalogTotal)) {
      throw ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.chapterIndexOutOfRange(index),
      );
    }
    final ReaderChapterInfo? cached = _catalogByIndex[index];
    if (cached != null) return cached;
    final int session = _sessionGeneration;
    final TextReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    final ReaderChapterInfo chapter = await dataSource.loadChapterAtIndex(
      bookId,
      index,
    );
    if (!_isSessionCurrent(session) ||
        !identical(dataSource, widget.dataSource) ||
        bookId != widget.bookId) {
      throw StateError(ReaderStrings.staleSession);
    }
    if (chapter.index != index || chapter.id.trim().isEmpty) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }
    final ReaderChapterInfo? sameId = _catalogById[chapter.id];
    final ReaderChapterInfo? sameIndex = _catalogByIndex[chapter.index];
    if ((sameId != null && sameId.index != chapter.index) ||
        (sameIndex != null && sameIndex.id != chapter.id)) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }
    _catalogById[chapter.id] = chapter;
    _catalogByIndex[chapter.index] = chapter;
    unawaited(_refreshLoadedChapterStates(chapterId: chapter.id));
    return chapter;
  }

  Future<void> _loadMoreCatalog({bool notify = true}) async {
    if (_catalogLoading || !_catalogHasMore) return;
    final int generation = _sessionGeneration;
    final TextReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    final String? cursor = _catalogCursor;
    _catalogLoading = true;
    if (notify && mounted) setState(() {});
    try {
      final ChapterCatalogPage page = await dataSource.loadChapterCatalog(
        bookId,
        cursor: cursor,
      );
      if (!_isCatalogSessionCurrent(generation, dataSource, bookId) ||
          cursor != _catalogCursor) {
        return;
      }
      _mergeCatalog(page);
    } catch (error) {
      if (_isCatalogSessionCurrent(generation, dataSource, bookId) &&
          cursor == _catalogCursor) {
        await _reportFailure(_asFailure(error, ReaderFailureKind.data));
      }
    } finally {
      if (_isCatalogSessionCurrent(generation, dataSource, bookId)) {
        _catalogLoading = false;
        if (notify && mounted) setState(() {});
      }
    }
  }

  bool _isCatalogSessionCurrent(
    int generation,
    TextReaderDataSource dataSource,
    String bookId,
  ) =>
      _isSessionCurrent(generation) &&
      identical(dataSource, widget.dataSource) &&
      bookId == widget.bookId;

  Future<void> _openChapter(
    String chapterId, {
    bool initial = false,
    bool forceRefresh = false,
    bool openAtEnd = false,
    double? targetChapterFraction,
    bool preserveAutoReading = false,
  }) async {
    if (!preserveAutoReading) _stopAutoReading();
    if (chapterId.isEmpty) return;
    final ReaderChapterInfo? targetInfo = _catalogById[chapterId];
    if (targetInfo == null) return;
    final TextChapterContent? previousContent = _content;
    final int previousIndex = _chapterIndex;
    final int navigation = ++_navigationGeneration;
    final int generation = ++_requestGeneration;
    final int session = _sessionGeneration;
    final ReaderObserver observer = _observer;
    final TextReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    _changingChapter = true;
    if (!initial && mounted) setState(() {});
    try {
      TextChapterContent? chapter;
      if (!forceRefresh) chapter = _takeCached(chapterId);
      chapter ??= await _loadChapterContent(
        dataSource,
        bookId,
        chapterId,
        reuseInFlight: !forceRefresh,
      );
      if (!_isCurrent(generation) || navigation != _navigationGeneration) {
        return;
      }
      if (session != _sessionGeneration || chapter.chapterId != chapterId) {
        if (chapter.chapterId != chapterId) {
          throw const ReaderFailure(
            ReaderFailureKind.data,
            ReaderStrings.invalidChapterLocation,
          );
        }
        return;
      }
      _validateChapter(chapter, expectedChapterId: chapterId);
      if (openAtEnd &&
          previousContent != null &&
          previousIndex == targetInfo.index + 1) {
        _chapterCache
          ..clear()
          ..[chapter.chapterId] = chapter
          ..[previousContent.chapterId] = previousContent;
      } else {
        _cacheChapter(chapter);
      }
      _chapterIndex = targetInfo.index;
      _currentChapterInfo = targetInfo;
      _content = chapter;
      _pages = const <ReaderPage>[];
      _layoutSize = null;
      _pageIndex = 0;
      _paragraphKeys.clear();

      final ReaderProgress? saved = _progress;
      final TextParagraph first = chapter.paragraphs.isEmpty
          ? const TextParagraph(id: '', text: '')
          : chapter.paragraphs.first;
      if (initial && saved?.chapterId == chapterId && !saved!.isBookPreview) {
        final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
        _progress = saved.copyWith(
          chapterIndex: targetInfo.index,
          bookFraction: total <= 0
              ? 0
              : ((targetInfo.index + saved.chapterFraction) / total).clamp(
                  0,
                  1,
                ),
        );
      } else {
        final double fraction =
            targetChapterFraction?.clamp(0, 1) ?? (openAtEnd ? 1 : 0);
        final int paragraphIndex = chapter.paragraphs.isEmpty
            ? 0
            : (fraction * chapter.paragraphs.length).floor().clamp(
                0,
                chapter.paragraphs.length - 1,
              );
        final TextParagraph anchor = chapter.paragraphs.isEmpty
            ? first
            : chapter.paragraphs[paragraphIndex];
        final int offset = openAtEnd
            ? anchor.text.length
            : (fraction * anchor.text.length).floor().clamp(
                0,
                anchor.text.length,
              );
        _progress = _progressForAnchor(
          anchor.id,
          offset,
          chapterFraction: fraction,
        );
      }
      _failure = null;
      if (mounted) setState(() {});
      _publishSnapshot();
      unawaited(_notify(() => observer.onChapterChanged(targetInfo)));
      await _syncAwake();
      if (!_isCurrent(generation) || session != _sessionGeneration) return;
      _scheduleProgressSave(immediate: true);
      if (!openAtEnd) unawaited(_prefetchNext(targetInfo.index));
      if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
        _scheduleVerticalRestore();
      }
      unawaited(_refreshCommentSummaries());
      unawaited(_recordChapterOpened(chapterId));
    } catch (error) {
      if (!_isCurrent(generation) || navigation != _navigationGeneration) {
        return;
      }
      _stopAutoReading();
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.data);
      _failure = failure;
      if (mounted) setState(() {});
      await _reportFailure(failure);
      unawaited(_refreshLoadedChapterStates(chapterId: chapterId));
    } finally {
      if (_isCurrent(generation)) {
        _changingChapter = false;
        if (mounted) setState(() {});
      }
    }
  }

  void _validateChapter(
    TextChapterContent chapter, {
    required String expectedChapterId,
  }) {
    if (chapter.chapterId.trim().isEmpty ||
        chapter.chapterId != expectedChapterId) {
      throw const ReaderFailure(
        ReaderFailureKind.data,
        ReaderStrings.invalidChapterLocation,
      );
    }
    final Set<String> paragraphIds = <String>{};
    for (final TextParagraph paragraph in chapter.paragraphs) {
      if (paragraph.id.trim().isEmpty || !paragraphIds.add(paragraph.id)) {
        throw const ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.invalidParagraphIdentifiers,
        );
      }
    }
  }

  TextChapterContent? _takeCached(String id) {
    final TextChapterContent? value = _chapterCache.remove(id);
    if (value != null) _chapterCache[id] = value;
    return value;
  }

  Future<TextChapterContent> _loadChapterContent(
    TextReaderDataSource dataSource,
    String bookId,
    String chapterId, {
    bool reuseInFlight = true,
  }) async {
    final String key = '$bookId\u0000$chapterId';
    final Future<TextChapterContent>? existing = _chapterLoads[key];
    if (reuseInFlight && existing != null) return existing;
    final Future<TextChapterContent> request = dataSource.loadChapterContent(
      bookId,
      chapterId,
    );
    _chapterLoads[key] = request;
    try {
      return await request;
    } finally {
      if (identical(_chapterLoads[key], request)) _chapterLoads.remove(key);
    }
  }

  void _cacheChapter(TextChapterContent chapter) {
    _chapterCache.remove(chapter.chapterId);
    _chapterCache[chapter.chapterId] = chapter;
    while (_chapterCache.length > _chapterCacheLimit) {
      _chapterCache.remove(_chapterCache.keys.first);
    }
  }

  Future<void> _prefetchNext(int currentIndex) async {
    final int nextIndex = currentIndex + 1;
    if (_catalogTotal > 0 && nextIndex >= _catalogTotal) return;
    final int session = _sessionGeneration;
    final TextReaderDataSource dataSource = widget.dataSource;
    final String bookId = widget.bookId;
    try {
      final ReaderChapterInfo next = await _chapterInfoAtIndex(nextIndex);
      if (!_isSessionCurrent(session) ||
          !identical(dataSource, widget.dataSource) ||
          bookId != widget.bookId) {
        return;
      }
      if (_chapterCache.containsKey(next.id)) return;
      final TextChapterContent content = await _loadChapterContent(
        dataSource,
        bookId,
        next.id,
      );
      if (!_isSessionCurrent(session) ||
          !identical(dataSource, widget.dataSource) ||
          bookId != widget.bookId ||
          _chapterIndex != currentIndex) {
        return;
      }
      if (content.chapterId != next.id) return;
      _validateChapter(content, expectedChapterId: next.id);
      _cacheChapter(content);
    } catch (_) {
      // Prefetch is best effort. Foreground loading reports actionable errors.
    }
  }

  bool _isCurrent(int generation) =>
      !_disposed && generation == _requestGeneration;

  bool _isSessionCurrent(int generation) =>
      !_disposed && generation == _sessionGeneration;

  Future<void> _loadPersistedCustomFont() async {
    final int generation = ++_fontLoadGeneration;
    final ReaderFontRepository? repository = widget.extensions.fontRepository;
    final String? fontId = _preferences.customFontId?.trim();
    if (repository == null || fontId == null || fontId.isEmpty) {
      if (!_disposed && generation == _fontLoadGeneration && mounted) {
        setState(() {
          _runtimeFontFamily = null;
          _runtimeFontDescriptor = null;
          _layoutSize = null;
        });
      }
      return;
    }
    try {
      final List<ReaderFontDescriptor> catalog = await repository.loadCatalog();
      final ReaderFontDescriptor descriptor = catalog.firstWhere(
        (ReaderFontDescriptor value) => value.id.trim() == fontId,
        orElse: () => throw StateError(ReaderStrings.externalFontUnavailable),
      );
      final String runtimeFamily = await loadReaderRuntimeFont(
        repository: repository,
        descriptor: descriptor,
      );
      if (_disposed ||
          !mounted ||
          generation != _fontLoadGeneration ||
          !identical(repository, widget.extensions.fontRepository) ||
          _preferences.customFontId?.trim() != fontId) {
        return;
      }
      final ReaderProgress? anchor = _progress;
      setState(() {
        _runtimeFontFamily = runtimeFamily;
        _runtimeFontDescriptor = descriptor;
        _layoutSize = null;
      });
      if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
        _scheduleVerticalRestore(paragraphId: anchor?.paragraphId);
      }
    } catch (error) {
      if (_disposed ||
          generation != _fontLoadGeneration ||
          !identical(repository, widget.extensions.fontRepository) ||
          _preferences.customFontId?.trim() != fontId) {
        return;
      }
      if (mounted) {
        setState(() {
          _runtimeFontFamily = null;
          _runtimeFontDescriptor = null;
          _layoutSize = null;
        });
      }
      await _reportFailure(
        ReaderFailure(
          ReaderFailureKind.data,
          ReaderStrings.externalFontUnavailable,
          cause: error,
        ),
      );
    }
  }

  void _applySelectedCustomFont(
    ReaderFontDescriptor descriptor,
    String runtimeFamily,
  ) {
    if (_disposed || !mounted) return;
    _fontLoadGeneration++;
    final ReaderProgress? anchor = _progress;
    setState(() {
      _runtimeFontFamily = runtimeFamily;
      _runtimeFontDescriptor = descriptor;
      _layoutSize = null;
    });
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      _scheduleVerticalRestore(paragraphId: anchor?.paragraphId);
    }
  }

  void _ensurePagination(Size size) {
    if (_content == null ||
        _preferences.navigationMode != ReaderNavigationMode.horizontalPages ||
        size.isEmpty ||
        (_layoutSize == size && _layoutTextScaler == _textScaler)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          (_layoutSize == size && _layoutTextScaler == _textScaler)) {
        return;
      }
      _paginate(size);
    });
  }

  void _paginate(Size size) {
    final TextChapterContent? content = _content;
    if (content == null) return;
    final EdgeInsets safe = MediaQuery.paddingOf(context);
    final double width = size.width <= 1
        ? size.width
        : (size.width -
                  (_preferences.horizontalPadding * 2).clamp(0, size.width - 1))
              .clamp(1, size.width);
    final double rawHeight =
        size.height -
        safe.top -
        safe.bottom -
        _preferences.topPadding -
        _preferences.bottomPadding -
        _horizontalPageLayoutSafety;
    final double height = size.height <= 1
        ? size.height
        : rawHeight.clamp(1, size.height);
    final TextStyle bodyStyle = _bodyTextStyle;
    try {
      final List<ReaderPage> pages = _paginator.paginate(
        chapter: content,
        width: width,
        height: height,
        titleStyle: _titleTextStyle,
        bodyStyle: bodyStyle,
        paragraphSpacing: _preferences.paragraphSpacing,
        firstLineIndent: _preferences.firstLineIndent,
        textDirection: Directionality.of(context),
        textScaler: _textScaler,
        paragraphTrailingWidth:
            widget.extensions.commentFeed != null &&
                _preferences.showParagraphComments
            ? _inlineCommentHitSize
            : 0,
        paragraphTrailingHeight:
            widget.extensions.commentFeed != null &&
                _preferences.showParagraphComments
            ? _inlineCommentHitSize
            : 0,
        chapterTrailingHeight:
            widget.extensions.commentFeed != null &&
                _preferences.showChapterComments
            ? 168
            : 0,
      );
      final ReaderProgress? anchor = _progress;
      final int pageIndex = anchor == null
          ? 0
          : _paginator.pageIndexForAnchor(
              pages,
              anchor.paragraphId,
              anchor.characterOffset,
            );
      setState(() {
        _layoutSize = size;
        _layoutTextScaler = _textScaler;
        _pages = pages;
        _pageIndex = pageIndex.clamp(0, pages.isEmpty ? 0 : pages.length - 1);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        _restoreHorizontalPageWithoutProgress(_pageIndex + 1);
      });
      _publishSnapshot();
    } catch (error) {
      final ReaderFailure failure = _asFailure(error, ReaderFailureKind.layout);
      setState(() => _failure = failure);
      unawaited(_reportFailure(failure));
    }
  }

  TextStyle get _bodyTextStyle => TextStyle(
    color: _palette.text,
    fontFamily: _activeRuntimeFontFamily ?? readerFontFamily(_preferences.font),
    fontFamilyFallback: readerFontFallback(_preferences.font),
    package: _activeRuntimeFontFamily == null
        ? readerFontPackageFor(_preferences.font)
        : null,
    fontSize: _preferences.fontSize,
    fontWeight: FontWeight(_preferences.fontWeight),
    height: _preferences.lineHeight,
    letterSpacing: _preferences.letterSpacing,
  );

  TextStyle get _titleTextStyle => TextStyle(
    color: _palette.text,
    fontFamily: _activeRuntimeFontFamily ?? readerFontFamily(_preferences.font),
    fontFamilyFallback: readerFontFallback(_preferences.font),
    package: _activeRuntimeFontFamily == null
        ? readerFontPackageFor(_preferences.font)
        : null,
    fontSize: _preferences.fontSize + 7,
    fontWeight: FontWeight.w700,
    height: 1.35,
  );

  String? get _activeRuntimeFontFamily =>
      _runtimeFontDescriptor?.id == _preferences.customFontId
      ? _runtimeFontFamily
      : null;

  Future<void> _nextPage({bool userInitiated = true}) async {
    if (userInitiated) _stopAutoReading();
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      if (_verticalController.hasClients) {
        await _verticalController.animateTo(
          (_verticalController.offset +
                  _verticalController.position.viewportDimension * 0.85)
              .clamp(0, _verticalController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    if (_pageIndex + 1 < _pages.length) {
      await _animateToPage(_pageIndex + 1);
    } else {
      await _nextChapter();
    }
  }

  Future<void> _previousPage({bool userInitiated = true}) async {
    if (userInitiated) _stopAutoReading();
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      if (_verticalController.hasClients) {
        await _verticalController.animateTo(
          (_verticalController.offset -
                  _verticalController.position.viewportDimension * 0.85)
              .clamp(0, _verticalController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    if (_pageIndex > 0) {
      await _animateToPage(_pageIndex - 1);
    } else {
      await _previousChapter();
    }
  }

  void _handleHorizontalTap(Offset localPosition) {
    _stopAutoReading();
    final Size? size = context.size;
    if (size == null || size.width <= 0) return;
    final double fraction = localPosition.dx / size.width;
    if (fraction < 0.3) {
      _pageTurnForward = false;
      unawaited(_previousPage());
    } else if (fraction > 0.7) {
      _pageTurnForward = true;
      unawaited(_nextPage());
    } else {
      _setControlsVisible(!_controlsVisible);
    }
  }

  void _trackMousePointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != _primaryMouseButton) {
      return;
    }
    _stopAutoReading();
    _mouseTapPointer = event.pointer;
    _mouseTapDownPosition = event.localPosition;
    _mouseTapMoved = false;
  }

  void _trackMousePointerMove(PointerMoveEvent event) {
    if (event.pointer != _mouseTapPointer || _mouseTapMoved) return;
    final Offset? downPosition = _mouseTapDownPosition;
    if (downPosition != null &&
        (event.localPosition - downPosition).distance > _mouseTapSlop) {
      _mouseTapMoved = true;
    }
  }

  void _finishMousePointer(PointerEvent event) {
    if (event.pointer != _mouseTapPointer) return;
    final bool isTap = !_mouseTapMoved;
    final Offset? downPosition = _mouseTapDownPosition;
    _mouseTapPointer = null;
    _mouseTapDownPosition = null;
    _mouseTapMoved = false;
    if (isTap && event is PointerUpEvent) {
      _handleHorizontalTap(event.localPosition);
    } else if (_usesDirectPageTurns &&
        event is PointerUpEvent &&
        downPosition != null) {
      final double delta = event.localPosition.dx - downPosition.dx;
      if (delta.abs() >= 36) {
        unawaited(delta < 0 ? _nextPage() : _previousPage());
      }
    }
  }

  Future<void> _animateToPage(int page) async {
    if (!_pageController.hasClients || _pageTurnAnimating) return;
    _pageTurnAnimating = true;
    _pageTurnForward = page > _pageIndex;
    try {
      if (_preferences.pageAnimation == ReaderPageAnimation.none ||
          MediaQuery.disableAnimationsOf(context)) {
        _pageController.jumpToPage(page + 1);
      } else {
        await _pageController.animateToPage(
          page + 1,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    } finally {
      _pageTurnAnimating = false;
    }
  }

  Future<void> _nextChapter() async {
    _stopAutoReading();
    await _nextChapterInternal();
  }

  Future<bool> _nextChapterInternal() async {
    final int navigation = ++_navigationGeneration;
    final int nextIndex = _chapterIndex + 1;
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    if (nextIndex >= total) {
      _restoreCurrentHorizontalPage();
      _showNotice(ReaderStrings.noNextChapter);
      return false;
    }
    try {
      final ReaderChapterInfo next = await _chapterInfoAtIndex(nextIndex);
      if (navigation != _navigationGeneration) return false;
      await _openChapter(next.id, preserveAutoReading: true);
      return _content?.chapterId == next.id && _failure == null;
    } catch (error) {
      if (navigation != _navigationGeneration) return false;
      _restoreCurrentHorizontalPage();
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
      return false;
    }
  }

  Future<void> _previousChapter() async {
    _stopAutoReading();
    final int navigation = ++_navigationGeneration;
    if (_chapterIndex < 0) {
      _showNotice(ReaderStrings.noPreviousChapter);
      return;
    }
    if (_chapterIndex == 0) {
      await _showBookPreview();
      return;
    }
    try {
      final ReaderChapterInfo previous = await _chapterInfoAtIndex(
        _chapterIndex - 1,
      );
      if (navigation != _navigationGeneration) return;
      await _openChapter(previous.id, openAtEnd: true);
    } catch (error) {
      if (navigation != _navigationGeneration) return;
      _restoreCurrentHorizontalPage();
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    }
  }

  Future<void> _showBookPreview() async {
    _stopAutoReading();
    final int navigation = ++_navigationGeneration;
    final int generation = ++_requestGeneration;
    final int session = _sessionGeneration;
    _saveTimer?.cancel();
    await _flushProgress();
    if (!_isCurrent(generation) ||
        session != _sessionGeneration ||
        navigation != _navigationGeneration) {
      return;
    }
    _content = null;
    _chapterCache.clear();
    _currentChapterInfo = null;
    _chapterIndex = -1;
    _pageIndex = 0;
    _pages = const <ReaderPage>[];
    _layoutSize = null;
    _layoutTextScaler = null;
    _paragraphKeys.clear();
    _progress = const ReaderProgress.bookPreview();
    _changingChapter = false;
    _failure = null;
    if (mounted) setState(() {});
    await _releaseAwake();
    _scheduleProgressSave(immediate: true);
    _publishSnapshot();
  }

  void _restoreCurrentHorizontalPage() {
    if (_preferences.navigationMode != ReaderNavigationMode.horizontalPages) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _restoreHorizontalPageWithoutProgress(_pageIndex + 1);
    });
  }

  void _restoreHorizontalPageWithoutProgress(int rawIndex) {
    _restoringHorizontalAnchor = true;
    _pageController.jumpToPage(rawIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoringHorizontalAnchor = false;
    });
  }

  void _showNotice(String message) {
    _noticeTimer?.cancel();
    if (mounted) setState(() => _noticeMessage = message);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _noticeMessage = null);
    });
  }

  void _onHorizontalPageChanged(int rawIndex) {
    if (_changingChapter || _pages.isEmpty) return;
    if (_restoringHorizontalAnchor &&
        rawIndex > 0 &&
        rawIndex < _pages.length + 1) {
      _pageIndex = rawIndex - 1;
      if (mounted) setState(() {});
      return;
    }
    if (rawIndex == 0) {
      unawaited(_previousChapter());
      return;
    }
    if (rawIndex == _pages.length + 1) {
      unawaited(_nextChapter());
      return;
    }
    _pageIndex = rawIndex - 1;
    _updateProgressFromPage();
    if (mounted) setState(() {});
  }

  void _updateProgressFromPage() {
    if (_pages.isEmpty || _pageIndex >= _pages.length) return;
    final ReaderPage page = _pages[_pageIndex];
    if (page.blocks.isEmpty) return;
    final bool hasChapterTrailing = _pages.last.showsChapterTrailing;
    final int bodyPageCount = _pages.length - (hasChapterTrailing ? 1 : 0);
    final int visitedBodyPageCount = (_pageIndex + 1).clamp(0, bodyPageCount);
    _progress = _progressForAnchor(
      page.paragraphId,
      page.characterOffset,
      chapterFraction: bodyPageCount == 0
          ? 0
          : visitedBodyPageCount / bodyPageCount,
    );
    _scheduleProgressSave();
    _publishSnapshot();
  }

  ReaderProgress _progressForAnchor(
    String paragraphId,
    int offset, {
    required double chapterFraction,
  }) {
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    final double bookFraction = total == 0
        ? 0
        : ((_chapterIndex + chapterFraction) / total).clamp(0, 1);
    return ReaderProgress(
      chapterId: _content?.chapterId ?? _currentChapter?.id ?? '',
      paragraphId: paragraphId,
      characterOffset: offset,
      chapterIndex: _chapterIndex,
      chapterFraction: chapterFraction.clamp(0, 1),
      bookFraction: bookFraction,
    );
  }

  void _handleVerticalScroll() {
    if (_restoringVerticalAnchor ||
        !_verticalController.hasClients ||
        _content == null) {
      return;
    }
    final double fraction = _verticalController.position.maxScrollExtent == 0
        ? 0
        : (_verticalController.offset /
                  _verticalController.position.maxScrollExtent)
              .clamp(0, 1);
    String paragraphId = _content!.paragraphs.firstOrNull?.id ?? '';
    var closestBottom = double.infinity;
    for (final MapEntry<String, GlobalKey> entry in _paragraphKeys.entries) {
      final BuildContext? itemContext = entry.value.currentContext;
      if (itemContext == null) continue;
      final RenderBox? box = itemContext.findRenderObject() as RenderBox?;
      if (box != null) {
        final double bottom =
            box.localToGlobal(Offset.zero).dy + box.size.height;
        if (bottom > 0 && bottom < closestBottom) {
          closestBottom = bottom;
          paragraphId = entry.key;
        }
      }
    }
    _progress = _progressForAnchor(paragraphId, 0, chapterFraction: fraction);
    _scheduleProgressSave();
    _publishSnapshot();
  }

  void _scheduleVerticalRestore({String? paragraphId}) {
    final int generation = ++_verticalRestoreGeneration;
    final String? id = paragraphId ?? _progress?.paragraphId;
    if (id == null || id.isEmpty) return;
    _restoringVerticalAnchor = true;
    void restore() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _verticalRestoreGeneration) return;
        if (_preferences.navigationMode !=
            ReaderNavigationMode.verticalScroll) {
          _restoringVerticalAnchor = false;
          return;
        }
        final BuildContext? target = _paragraphKeys[id]?.currentContext;
        if (target != null) {
          unawaited(
            Scrollable.ensureVisible(target, alignment: 0.05).whenComplete(() {
              if (mounted && generation == _verticalRestoreGeneration) {
                _restoringVerticalAnchor = false;
              }
            }),
          );
          return;
        }
        final TextChapterContent? content = _content;
        if (!_verticalController.hasClients ||
            content == null ||
            _verticalItemExtents.isEmpty) {
          restore();
          return;
        }
        final int index = content.paragraphs.indexWhere(
          (TextParagraph paragraph) => paragraph.id == id,
        );
        if (index < 0 || content.paragraphs.isEmpty) {
          _restoringVerticalAnchor = false;
          return;
        }
        _measureVerticalPrefixAndRestore(
          paragraphIndex: index,
          paragraphId: id,
          generation: generation,
        );
      });
    }

    restore();
  }

  void _measureVerticalPrefixAndRestore({
    required int paragraphIndex,
    required String paragraphId,
    required int generation,
    int nextItem = 0,
    double offset = 0,
  }) {
    if (!mounted || generation != _verticalRestoreGeneration) return;
    final int targetItem = paragraphIndex + 1;
    final int end = (nextItem + _verticalRestoreMeasureBatchSize).clamp(
      0,
      targetItem,
    );
    var resolvedOffset = offset;
    for (var item = nextItem; item < end; item++) {
      resolvedOffset += _verticalItemExtent(item);
    }
    if (end < targetItem) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _measureVerticalPrefixAndRestore(
          paragraphIndex: paragraphIndex,
          paragraphId: paragraphId,
          generation: generation,
          nextItem: end,
          offset: resolvedOffset,
        );
      });
      return;
    }
    final double desiredOffset =
        _preferences.topPadding +
        resolvedOffset -
        _verticalController.position.viewportDimension * 0.05;
    _verticalController.jumpTo(desiredOffset.clamp(0, double.infinity));
    _ensureVerticalRestoreTarget(
      paragraphId: paragraphId,
      generation: generation,
    );
  }

  void _ensureVerticalRestoreTarget({
    required String paragraphId,
    required int generation,
    int remainingAttempts = 3,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _verticalRestoreGeneration) return;
      final BuildContext? target = _paragraphKeys[paragraphId]?.currentContext;
      if (target == null) {
        if (remainingAttempts > 0) {
          _ensureVerticalRestoreTarget(
            paragraphId: paragraphId,
            generation: generation,
            remainingAttempts: remainingAttempts - 1,
          );
          return;
        }
        _restoringVerticalAnchor = false;
        unawaited(
          _reportFailure(
            const ReaderFailure(
              ReaderFailureKind.layout,
              ReaderStrings.verticalAnchorRestoreFailed,
            ),
          ),
        );
        return;
      }
      unawaited(
        Scrollable.ensureVisible(target, alignment: 0.05).whenComplete(() {
          if (mounted && generation == _verticalRestoreGeneration) {
            _restoringVerticalAnchor = false;
          }
        }),
      );
    });
  }

  void _prepareVerticalItemExtents({
    required double width,
    required TextDirection textDirection,
    required int itemCount,
    required bool hasParagraphComments,
    required bool hasChapterComments,
  }) {
    if (identical(_verticalExtentContent, _content) &&
        _verticalExtentPreferences == _preferences &&
        _verticalExtentTextScaler == _textScaler &&
        _verticalExtentTextDirection == textDirection &&
        _verticalExtentWidth == width &&
        _verticalExtentHasParagraphComments == hasParagraphComments &&
        _verticalExtentHasChapterComments == hasChapterComments &&
        _verticalItemExtents.length == itemCount) {
      return;
    }
    _verticalExtentContent = _content;
    _verticalExtentPreferences = _preferences;
    _verticalExtentTextScaler = _textScaler;
    _verticalExtentTextDirection = textDirection;
    _verticalExtentWidth = width;
    _verticalExtentHasParagraphComments = hasParagraphComments;
    _verticalExtentHasChapterComments = hasChapterComments;
    _verticalItemExtents = List<double?>.filled(itemCount, null);
  }

  double _verticalItemExtent(int index) {
    final double? cached = _verticalItemExtents[index];
    if (cached != null) return cached;
    final TextChapterContent content = _verticalExtentContent!;
    late final double extent;
    if (index == 0) {
      extent = _measureVerticalText(content.title, _titleTextStyle) + 28;
    } else if (index <= content.paragraphs.length) {
      final String text = _indented(content.paragraphs[index - 1].text);
      extent =
          (_verticalExtentHasParagraphComments
              ? _measureVerticalTextWithTrailing(text, _bodyTextStyle)
              : _measureVerticalText(text, _bodyTextStyle)) +
          _preferences.paragraphSpacing;
    } else if (_verticalExtentHasChapterComments &&
        index == content.paragraphs.length + 1) {
      extent = 168;
    } else {
      extent = 96;
    }
    _verticalItemExtents[index] = extent;
    return extent;
  }

  double _measureVerticalText(String text, TextStyle style) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: _verticalExtentTextDirection,
      textScaler: _verticalExtentTextScaler ?? TextScaler.noScaling,
    )..layout(maxWidth: _verticalExtentWidth);
    return painter.height;
  }

  double _measureVerticalTextWithTrailing(String text, TextStyle style) {
    final TextPainter painter =
        TextPainter(
          text: TextSpan(
            style: style,
            children: <InlineSpan>[
              TextSpan(text: text),
              const WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox.square(dimension: _inlineCommentHitSize),
              ),
            ],
          ),
          textDirection: _verticalExtentTextDirection,
          textScaler: _verticalExtentTextScaler ?? TextScaler.noScaling,
        )..setPlaceholderDimensions(const <PlaceholderDimensions>[
          PlaceholderDimensions(
            size: Size.square(_inlineCommentHitSize),
            alignment: PlaceholderAlignment.middle,
          ),
        ]);
    painter.layout(maxWidth: _verticalExtentWidth);
    return painter.height;
  }

  GlobalKey _paragraphKey(String paragraphId) {
    final GlobalKey? existing = _paragraphKeys[paragraphId];
    if (existing != null) return existing;
    if (_paragraphKeys.length >= _paragraphKeyCacheLimit) {
      _paragraphKeys.removeWhere(
        (String _, GlobalKey key) => key.currentContext == null,
      );
    }
    return _paragraphKeys.putIfAbsent(paragraphId, GlobalKey.new);
  }

  Future<void> _refreshCommentSummaries() async {
    final ReaderCommentFeed? feed = widget.extensions.commentFeed;
    final int generation = ++_commentGeneration;
    if (feed == null) {
      if (mounted) {
        setState(() {
          _commentSummaries.clear();
          _commentSummariesLoading = false;
          _commentSummariesFailed = false;
        });
      }
      return;
    }
    final List<ReaderCommentTarget> targets = <ReaderCommentTarget>[];
    if (_preferences.showBookComments) {
      targets.add(ReaderCommentTarget.book(widget.bookId));
    }
    final TextChapterContent? content = _content;
    if (_preferences.showChapterComments && content != null) {
      targets.add(
        ReaderCommentTarget.chapter(widget.bookId, content.chapterId),
      );
    }
    if (_preferences.showParagraphComments && content != null) {
      targets.addAll(
        content.paragraphs.map(
          (TextParagraph paragraph) => ReaderCommentTarget.paragraph(
            widget.bookId,
            content.chapterId,
            paragraph.id,
          ),
        ),
      );
    }
    if (targets.isEmpty) {
      if (mounted) {
        setState(() {
          _commentSummaries.clear();
          _commentSummariesLoading = false;
          _commentSummariesFailed = false;
        });
      }
      return;
    }
    for (final ReaderCommentTarget target in targets) {
      if (!_isValidCommentTarget(target)) {
        await _reportFailure(
          const ReaderFailure(
            ReaderFailureKind.data,
            ReaderStrings.invalidCommentTarget,
          ),
        );
        return;
      }
    }
    if (mounted) {
      setState(() {
        _commentSummariesLoading = true;
        _commentSummariesFailed = false;
      });
    }
    try {
      final Map<ReaderCommentTarget, ReaderCommentSummary> loaded =
          <ReaderCommentTarget, ReaderCommentSummary>{};
      var nextBatchStart = 0;
      Future<void> loadWorker() async {
        while (nextBatchStart < targets.length) {
          final int start = nextBatchStart;
          nextBatchStart += _commentSummaryBatchSize;
          final int end = (start + _commentSummaryBatchSize).clamp(
            0,
            targets.length,
          );
          final List<ReaderCommentTarget> batch =
              List<ReaderCommentTarget>.unmodifiable(
                targets.sublist(start, end),
              );
          final Map<ReaderCommentTarget, ReaderCommentSummary> response =
              await feed.loadSummaries(batch, previewLimit: 3);
          if (!mounted || generation != _commentGeneration) return;
          final Set<ReaderCommentTarget> requested = batch.toSet();
          for (final MapEntry<ReaderCommentTarget, ReaderCommentSummary> entry
              in response.entries) {
            if (!requested.contains(entry.key) ||
                !_isValidCommentTarget(entry.key) ||
                entry.key != entry.value.target ||
                entry.value.topComments.length > 3 ||
                entry.value.topComments.any(
                  (ReaderComment comment) => comment.target != entry.key,
                )) {
              throw const ReaderFailure(
                ReaderFailureKind.data,
                ReaderStrings.invalidCommentTarget,
              );
            }
          }
          loaded.addAll(response);
        }
      }

      final int batchCount =
          (targets.length + _commentSummaryBatchSize - 1) ~/
          _commentSummaryBatchSize;
      final int workerCount = batchCount.clamp(1, 4);
      await Future.wait<void>(
        List<Future<void>>.generate(workerCount, (_) => loadWorker()),
      );
      if (!mounted || generation != _commentGeneration) return;
      setState(() {
        _commentSummaries
          ..clear()
          ..addEntries(
            targets.map(
              (ReaderCommentTarget target) => MapEntry(
                target,
                loaded[target] ??
                    ReaderCommentSummary(
                      target: target,
                      total: 0,
                      topComments: const <ReaderComment>[],
                    ),
              ),
            ),
          );
        _commentSummariesLoading = false;
        _commentSummariesFailed = false;
      });
    } catch (error) {
      if (!mounted || generation != _commentGeneration) return;
      setState(() {
        _commentSummaries
          ..clear()
          ..addEntries(
            targets.map(
              (ReaderCommentTarget target) => MapEntry(
                target,
                ReaderCommentSummary(
                  target: target,
                  total: 0,
                  topComments: const <ReaderComment>[],
                ),
              ),
            ),
          );
        _commentSummariesLoading = false;
        _commentSummariesFailed = true;
      });
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    }
  }

  bool _isValidCommentTarget(ReaderCommentTarget target) {
    if (target.bookId.trim().isEmpty) return false;
    final String? chapterId = target.chapterId;
    final String? paragraphId = target.paragraphId;
    if (paragraphId != null) {
      return paragraphId.trim().isNotEmpty &&
          chapterId != null &&
          chapterId.trim().isNotEmpty;
    }
    return chapterId == null || chapterId.trim().isNotEmpty;
  }

  ReaderCommentSummary _commentSummary(ReaderCommentTarget target) {
    return _commentSummaries[target] ??
        ReaderCommentSummary(
          target: target,
          total: 0,
          topComments: const <ReaderComment>[],
        );
  }

  Widget _inlineParagraphComment({
    required ReaderCommentTarget target,
    required VoidCallback onPressed,
  }) {
    final ReaderCommentSummary summary = _commentSummary(target);
    final bool loading = _commentSummariesLoading;
    final bool failed = _commentSummariesFailed;
    final String semanticsLabel = loading
        ? ReaderCommentStrings.paragraphLoading
        : failed
        ? ReaderCommentStrings.paragraphLoadFailed
        : ReaderCommentStrings.paragraphCount(summary.total);
    final VoidCallback action = failed
        ? () => unawaited(_refreshCommentSummaries())
        : onPressed;
    return Tooltip(
      message: semanticsLabel,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: semanticsLabel,
        excludeSemantics: true,
        onTap: loading ? null : action,
        child: SizedBox.square(
          dimension: _inlineCommentHitSize,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: loading ? null : action,
              child: Center(
                child: Container(
                  width: _inlineCommentVisualSize,
                  height: _inlineCommentVisualSize,
                  decoration: BoxDecoration(
                    color: _palette.accent.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: loading
                        ? SizedBox.square(
                            dimension: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: _palette.accent,
                            ),
                          )
                        : failed
                        ? Icon(
                            Icons.refresh_rounded,
                            size: 15,
                            color: _palette.accent,
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 11,
                                color: _palette.accent,
                              ),
                              const SizedBox(width: 2),
                              Flexible(
                                child: Text(
                                  ReaderCommentStrings.compactCount(
                                    summary.total,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.clip,
                                  style: TextStyle(
                                    color: _palette.accent,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    height: 1,
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBookCommentSummary({
    required ReaderCommentTarget target,
    required VoidCallback onPressed,
  }) {
    final ReaderCommentSummary summary = _commentSummary(target);
    return SizedBox(
      height: 168,
      child: Material(
        color: _palette.panel.withValues(alpha: .82),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: _palette.divider),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _commentSummariesLoading
              ? null
              : _commentSummariesFailed
              ? () => unawaited(_refreshCommentSummaries())
              : onPressed,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 17,
                      color: _palette.accent,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _commentSummariesLoading
                            ? ReaderCommentStrings.loading
                            : _commentSummariesFailed
                            ? ReaderCommentStrings.loadFailed
                            : '${ReaderCommentStrings.bookTitle} · ${summary.total}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, size: 19),
                  ],
                ),
                const SizedBox(height: 8),
                if (!_commentSummariesLoading &&
                    !_commentSummariesFailed &&
                    summary.topComments.isEmpty)
                  Text(
                    ReaderCommentStrings.empty,
                    style: TextStyle(color: _palette.secondaryText),
                  )
                else if (!_commentSummariesLoading && !_commentSummariesFailed)
                  for (final ReaderComment comment in summary.topComments.take(
                    3,
                  ))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        '${comment.authorName}：${comment.content}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _palette.secondaryText,
                          fontSize: 12,
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showComments(ReaderCommentTarget target, {String? title}) {
    _stopAutoReading();
    final ReaderCommentFeed? feed = widget.extensions.commentFeed;
    final ReaderObserver observer = _observer;
    if (feed == null) return;
    if (!_isValidCommentTarget(target)) {
      unawaited(
        _reportFailure(
          const ReaderFailure(
            ReaderFailureKind.data,
            ReaderStrings.invalidCommentTarget,
          ),
        ),
      );
      return;
    }
    unawaited(
      showReaderCommentsSheet(
        context: context,
        feed: feed,
        target: target,
        palette: _palette,
        title: title ?? ReaderCommentStrings.title,
        onLoadError: (Object error) => unawaited(
          _notify(
            () => observer.onFailure(_asFailure(error, ReaderFailureKind.data)),
          ),
        ),
      ),
    );
  }

  Future<void> _startAutoReading() async {
    if (!_foreground ||
        _content == null ||
        _failure != null ||
        _loading ||
        _changingChapter ||
        (_preferences.navigationMode == ReaderNavigationMode.horizontalPages &&
            _pages.isEmpty)) {
      return;
    }
    _setControlsVisible(false);
    if (_preferences.navigationMode == ReaderNavigationMode.horizontalPages) {
      _autoReadingCoordinator.startHorizontal(pace: _autoReadingPace);
    } else {
      _autoReadingCoordinator.startVertical(pace: _autoReadingPace);
    }
    _publishSnapshot();
  }

  void _stopAutoReading() {
    _autoReadingCoordinator.stop();
  }

  Future<void> _toggleAutoReading() async {
    if (_autoReadingCoordinator.isRunning) {
      _stopAutoReading();
    } else {
      await _startAutoReading();
    }
  }

  Future<bool> _autoAdvancePage() async {
    if (_content == null || _failure != null || _changingChapter) return false;
    if (_pageIndex + 1 < _pages.length) {
      await _animateToPage(_pageIndex + 1);
      return true;
    }
    return _nextChapterInternal();
  }

  Future<bool> _autoScrollBy(double delta) async {
    if (!_verticalController.hasClients || _content == null) return false;
    _autoScrolling = true;
    try {
      final ScrollPosition position = _verticalController.position;
      if (position.pixels + delta < position.maxScrollExtent) {
        _verticalController.jumpTo(position.pixels + delta);
        return true;
      }
      return await _nextChapterInternal();
    } finally {
      _autoScrolling = false;
    }
  }

  void _scheduleProgressSave({bool immediate = false}) {
    _saveTimer?.cancel();
    if (immediate) {
      unawaited(_flushProgress());
    } else {
      _saveTimer = Timer(_saveDelay, () => unawaited(_flushProgress()));
    }
  }

  Future<void> _flushProgress() async {
    _saveTimer?.cancel();
    final ReaderProgress? progress = _progress;
    if (progress == null) return;
    await _queueProgressSave(
      store: widget.stateStore,
      bookId: widget.bookId,
      progress: progress,
    );
  }

  Future<void> _queueProgressSave({
    required TextReaderStateStore store,
    required String bookId,
    required ReaderProgress progress,
  }) {
    final ReaderObserver observer = _observer;
    Future<void> write() async {
      if (identical(_lastProgressStore, store) &&
          _lastProgressBookId == bookId &&
          _lastSavedProgress == progress) {
        return;
      }
      try {
        await store.saveProgress(bookId, progress);
        _lastProgressStore = store;
        _lastProgressBookId = bookId;
        _lastSavedProgress = progress;
      } catch (error) {
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
    }

    final Map<String, Future<void>> writesForStore = _progressWritesByStore
        .putIfAbsent(store, () => <String, Future<void>>{});
    final Future<void> previous =
        writesForStore[bookId] ?? Future<void>.value();
    final Future<void> next = previous.then(
      (_) => write(),
      onError: (_) => write(),
    );
    writesForStore[bookId] = next;
    unawaited(
      next.then<void>(
        (_) => _removeProgressWrite(store, bookId, next),
        onError: (_) => _removeProgressWrite(store, bookId, next),
      ),
    );
    return next;
  }

  void _removeProgressWrite(
    TextReaderStateStore store,
    String bookId,
    Future<void> completed,
  ) {
    final Map<String, Future<void>>? writesForStore =
        _progressWritesByStore[store];
    if (writesForStore == null ||
        !identical(writesForStore[bookId], completed)) {
      return;
    }
    writesForStore.remove(bookId);
    if (writesForStore.isEmpty) _progressWritesByStore.remove(store);
  }

  Future<void> _queuePreferencesSave({
    required TextReaderStateStore store,
    required TextReaderPreferences preferences,
  }) {
    final ReaderObserver observer = _observer;
    Future<void> write() async {
      if (identical(_lastPreferenceStore, store) &&
          _lastSavedPreferences == preferences) {
        return;
      }
      try {
        await store.savePreferences(preferences);
        _lastPreferenceStore = store;
        _lastSavedPreferences = preferences;
      } catch (error) {
        if (identical(store, widget.stateStore) &&
            preferences == _preferences) {
          _preferencesPreviewDirty = true;
        }
        unawaited(
          _notify(
            () => observer.onFailure(
              _asFailure(error, ReaderFailureKind.persistence),
            ),
          ),
        );
      }
    }

    final Future<void> previous =
        _preferenceWritesByStore[store] ?? Future<void>.value();
    final Future<void> next = previous.then(
      (_) => write(),
      onError: (_) => write(),
    );
    _preferenceWritesByStore[store] = next;
    unawaited(
      next.then<void>(
        (_) => _removePreferenceWrite(store, next),
        onError: (_) => _removePreferenceWrite(store, next),
      ),
    );
    return next;
  }

  void _removePreferenceWrite(
    TextReaderStateStore store,
    Future<void> completed,
  ) {
    if (identical(_preferenceWritesByStore[store], completed)) {
      _preferenceWritesByStore.remove(store);
    }
  }

  void _commitPreferencePreview() {
    if (!_preferencesPreviewDirty) return;
    _preferencesPreviewDirty = false;
    unawaited(
      _queuePreferencesSave(
        store: widget.stateStore,
        preferences: _preferences,
      ),
    );
  }

  Future<void> _updatePreferences(TextReaderPreferences value) async {
    await _applyPreferences(value, persist: true);
  }

  Future<void> _applyPreferences(
    TextReaderPreferences value, {
    required bool persist,
  }) async {
    if (_disposed) return;
    final ReaderProgress? anchor = _progress;
    final TextReaderPreferences normalized = value.normalized();
    final bool layoutChanged =
        normalized.font != _preferences.font ||
        normalized.customFontId != _preferences.customFontId ||
        normalized.fontSize != _preferences.fontSize ||
        normalized.fontWeight != _preferences.fontWeight ||
        normalized.letterSpacing != _preferences.letterSpacing ||
        normalized.lineHeight != _preferences.lineHeight ||
        normalized.paragraphSpacing != _preferences.paragraphSpacing ||
        normalized.firstLineIndent != _preferences.firstLineIndent ||
        normalized.horizontalPadding != _preferences.horizontalPadding ||
        normalized.topPadding != _preferences.topPadding ||
        normalized.bottomPadding != _preferences.bottomPadding ||
        normalized.navigationMode != _preferences.navigationMode ||
        normalized.showParagraphComments !=
            _preferences.showParagraphComments ||
        normalized.showChapterComments != _preferences.showChapterComments;
    final bool commentsChanged =
        normalized.showBookComments != _preferences.showBookComments ||
        normalized.showChapterComments != _preferences.showChapterComments ||
        normalized.showParagraphComments != _preferences.showParagraphComments;
    if (!_isNightTheme(normalized.theme)) {
      _lastNonNightTheme = normalized.theme;
    }
    if (normalized.customFontId == null) {
      _fontLoadGeneration++;
      _runtimeFontFamily = null;
      _runtimeFontDescriptor = null;
    }
    setState(() {
      _preferences = normalized;
      if (layoutChanged) _layoutSize = null;
    });
    _preferencesPreviewDirty = !persist;
    final Future<void> awakeUpdate = _syncAwake();
    if (normalized.navigationMode == ReaderNavigationMode.verticalScroll) {
      _scheduleVerticalRestore(paragraphId: anchor?.paragraphId);
    }
    if (persist) {
      await _queuePreferencesSave(
        store: widget.stateStore,
        preferences: normalized,
      );
    }
    await awakeUpdate;
    if (normalized.customFontId != null &&
        normalized.customFontId != _runtimeFontDescriptor?.id) {
      unawaited(_loadPersistedCustomFont());
    }
    if (commentsChanged) unawaited(_refreshCommentSummaries());
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
    final bool foreground = normalized == ReaderLifecycleState.foreground;
    _foreground = foreground;
    if (!foreground) {
      _stopAutoReading();
      _commitPreferencePreview();
      unawaited(_releaseAwake());
      unawaited(_flushProgress());
    } else {
      unawaited(_syncAwake());
    }
    final ReaderObserver observer = _observer;
    final ReaderProgress? progress = _progress;
    unawaited(_notify(() => observer.onLifecycleChanged(normalized, progress)));
  }

  Future<void> _syncAwake() {
    _awakeWrite = _awakeWrite.then(
      (_) => _reconcileAwake(),
      onError: (_) => _reconcileAwake(),
    );
    return _awakeWrite;
  }

  Future<void> _reconcileAwake() async {
    final bool shouldAcquire =
        !_disposed &&
        _foreground &&
        _content != null &&
        ((_preferences.keepScreenOn && _platformCapabilities.keepScreenOn) ||
            (_preferences.immersiveMode &&
                _platformCapabilities.immersiveMode));
    if (shouldAcquire) {
      try {
        await ScreenAwakeCoordinator.instance.acquire(
          _awakeHolder,
          keepScreenOn:
              _preferences.keepScreenOn && _platformCapabilities.keepScreenOn,
          immersiveMode:
              _preferences.immersiveMode && _platformCapabilities.immersiveMode,
        );
        final bool stillDesired =
            !_disposed &&
            _foreground &&
            _content != null &&
            ((_preferences.keepScreenOn &&
                    _platformCapabilities.keepScreenOn) ||
                (_preferences.immersiveMode &&
                    _platformCapabilities.immersiveMode));
        if (!stillDesired) {
          await ScreenAwakeCoordinator.instance.release(_awakeHolder);
        }
      } catch (error) {
        try {
          await ScreenAwakeCoordinator.instance.release(_awakeHolder);
        } catch (_) {
          // The original platform failure is the actionable one.
        }
        await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
      }
    } else {
      await _releaseAwakeNow();
    }
  }

  Future<void> _releaseAwake() {
    _awakeWrite = _awakeWrite.then(
      (_) => _releaseAwakeNow(),
      onError: (_) => _releaseAwakeNow(),
    );
    return _awakeWrite;
  }

  Future<void> _releaseAwakeNow() async {
    try {
      await ScreenAwakeCoordinator.instance.release(_awakeHolder);
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
    }
  }

  void _setControlsVisible(bool value) {
    if (_controlsVisible == value || !mounted) return;
    setState(() => _controlsVisible = value);
    _publishSnapshot();
  }

  void _publishSnapshot() {
    _controller.updateSnapshot(
      TextReaderSnapshot(
        isReady: (_content != null || _isBookPreview) && _failure == null,
        isLoading: _loading || _changingChapter,
        controlsVisible: _controlsVisible,
        isAutoReading: _autoReadingCoordinator.isRunning,
        book: _book,
        chapter: _currentChapter,
        progress: _progress,
        failure: _failure,
      ),
      owner: _controllerBindingOwner,
    );
  }

  ReaderFailure _asFailure(Object error, ReaderFailureKind fallbackKind) {
    if (error is ReaderFailure) return error;
    return ReaderFailure(
      fallbackKind,
      ReaderStrings.readerProblem,
      cause: error,
    );
  }

  Future<void> _reportFailure(ReaderFailure failure) {
    final ReaderObserver observer = _observer;
    unawaited(_notify(() => observer.onFailure(failure)));
    return Future<void>.value();
  }

  Future<void> _notify(FutureOr<void> Function() callback) {
    return Future<void>.sync(callback).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      debugPrint('novel_reader_ui observer error: $error\n$stackTrace');
    });
  }

  Future<void> _requestExit() {
    final Future<void>? pending = _exitRequest;
    if (pending != null) return pending;
    final Future<void> request = _performExit();
    _exitRequest = request;
    return request.whenComplete(() {
      if (identical(_exitRequest, request)) _exitRequest = null;
    });
  }

  Future<void> _performExit() async {
    _stopAutoReading();
    _commitPreferencePreview();
    final ReaderObserver observer = _observer;
    final ReaderProgress? progress = _progress;
    final int session = _sessionGeneration;
    await (_preferenceWritesByStore[widget.stateStore] ?? Future<void>.value());
    await _flushProgress();
    if (!_isSessionCurrent(session)) return;
    await _notify(() => observer.onExitRequested(progress));
  }

  @override
  Widget build(BuildContext context) {
    final ReaderPalette palette = _palette;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: palette.systemBrightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: Theme(
        data: _readerMaterialTheme(palette),
        child: PopScope<void>(
          canPop: false,
          onPopInvokedWithResult: (bool didPop, void result) {
            if (!didPop) unawaited(_requestExit());
          },
          child: Material(
            color: palette.background,
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                    unawaited(_nextPage()),
                const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                    unawaited(_nextPage()),
                const SingleActivator(LogicalKeyboardKey.space): () =>
                    unawaited(_nextPage()),
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                    unawaited(_previousPage()),
                const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                    unawaited(_previousPage()),
                const SingleActivator(
                  LogicalKeyboardKey.space,
                  shift: true,
                ): () =>
                    unawaited(_previousPage()),
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    unawaited(_requestExit()),
              },
              child: Focus(
                focusNode: _focusNode,
                autofocus: true,
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    _ensurePagination(constraints.biggest);
                    return ScrollConfiguration(
                      behavior: const _ReaderScrollBehavior(),
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          ReaderBackgroundSurface(
                            preset: _preferences.background,
                            palette: palette,
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                _buildContent(),
                                IgnorePointer(
                                  child: ColoredBox(
                                    color: Colors.black.withValues(
                                      alpha:
                                          (1 - _preferences.brightness) * 0.65,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_content != null) _buildChrome(),
                          if (_noticeMessage != null)
                            _ReaderNotice(message: _noticeMessage!),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  ThemeData _readerMaterialTheme(ReaderPalette palette) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: palette.systemBrightness,
        ).copyWith(
          primary: palette.accent,
          surface: palette.panel,
          onSurface: palette.text,
          outline: palette.divider,
        );
    return ThemeData(
      useMaterial3: true,
      brightness: palette.systemBrightness,
      colorScheme: scheme,
      fontFamily: _preferences.font == ReaderFontPreset.system
          ? readerPackageFontFamily
          : readerFontFamily(_preferences.font),
      fontFamilyFallback: readerFontFallback(_preferences.font),
      scaffoldBackgroundColor: palette.background,
      dividerColor: palette.divider,
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size.square(48)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        minTileHeight: 52,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Widget _buildContent() {
    if (_loading && _content == null) {
      return _CenteredStatus(
        color: _palette.secondaryText,
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox.square(
              dimension: 30,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(height: 12),
            Text(ReaderStrings.loading),
          ],
        ),
      );
    }
    if (_failure != null && _content == null) {
      return _CenteredStatus(
        color: _palette.secondaryText,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.refresh_rounded, size: 34, color: _palette.accent),
            const SizedBox(height: 10),
            const Text(ReaderStrings.loadFailed),
            const SizedBox(height: 10),
            FilledButton.tonal(
              onPressed: _initialize,
              child: const Text(ReaderStrings.retry),
            ),
          ],
        ),
      );
    }
    if (_isBookPreview) return _buildBookPreview();
    if (_content == null) return const SizedBox.shrink();
    return _preferences.navigationMode == ReaderNavigationMode.horizontalPages
        ? _buildHorizontalReader()
        : _buildVerticalReader();
  }

  Widget _buildBookPreview() {
    final ReaderBookInfo? book = _book;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    tooltip: ReaderStrings.back,
                    onPressed: _requestExit,
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Container(
                    width: 108,
                    height: 144,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          _palette.accent.withValues(alpha: 0.92),
                          _palette.text.withValues(alpha: 0.78),
                        ],
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.menu_book_rounded,
                      size: 42,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  book?.title ?? ReaderStrings.bookPreview,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _palette.text,
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (book?.author?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    book!.author!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _palette.secondaryText),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(
                      Icons.format_list_numbered_rounded,
                      size: 18,
                      color: _palette.secondaryText,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      ReaderStrings.chapterCount(_catalogTotal),
                      style: TextStyle(color: _palette.secondaryText),
                    ),
                  ],
                ),
                if (book?.description?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(
                      color: _palette.panel.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _palette.divider),
                    ),
                    child: Text(
                      book!.description!,
                      style: TextStyle(
                        color: _palette.text,
                        fontSize: 15,
                        height: 1.65,
                      ),
                    ),
                  ),
                ],
                if (widget.extensions.commentFeed != null &&
                    _preferences.showBookComments) ...<Widget>[
                  const SizedBox(height: 14),
                  _buildBookCommentSummary(
                    target: ReaderCommentTarget.book(widget.bookId),
                    onPressed: () => _showComments(
                      ReaderCommentTarget.book(widget.bookId),
                      title: ReaderCommentStrings.bookTitle,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Center(
                  child: SizedBox(
                    width: 220,
                    child: FilledButton.icon(
                      onPressed: _catalogTotal > 0 ? _nextChapter : null,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 19),
                      label: const Text(ReaderStrings.startReading),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontalReader() {
    if (_pages.isEmpty) {
      return Center(
        child: Text(
          _content!.paragraphs.isEmpty
              ? ReaderStrings.emptyChapter
              : ReaderStrings.loading,
          style: TextStyle(color: _palette.secondaryText),
        ),
      );
    }
    final ScrollBehavior horizontalPageScrollBehavior =
        ScrollConfiguration.of(context).copyWith(
          // Flutter excludes mouse drags from scrollables by default. This
          // restores PageView's native, position-following drag behavior.
          dragDevices: <PointerDeviceKind>{
            ...ScrollConfiguration.of(context).dragDevices,
            PointerDeviceKind.mouse,
          },
        );
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      supportedDevices: const <PointerDeviceKind>{
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      },
      onTapUp: (TapUpDetails details) =>
          _handleHorizontalTap(details.localPosition),
      onHorizontalDragStart: _usesDirectPageTurns
          ? (_) {
              _stopAutoReading();
              _directDragDelta = 0;
            }
          : null,
      onHorizontalDragUpdate: _usesDirectPageTurns
          ? (DragUpdateDetails details) {
              _directDragDelta += details.primaryDelta ?? 0;
            }
          : null,
      onHorizontalDragEnd: _usesDirectPageTurns
          ? (_) {
              final double delta = _directDragDelta;
              _directDragDelta = 0;
              if (delta.abs() < 36) return;
              if (delta < 0) {
                unawaited(_nextPage());
              } else {
                unawaited(_previousPage());
              }
            }
          : null,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerSignal: _handlePointerSignal,
        onPointerDown: _trackMousePointerDown,
        onPointerMove: _trackMousePointerMove,
        onPointerUp: _finishMousePointer,
        onPointerCancel: _finishMousePointer,
        child: ScrollConfiguration(
          behavior: horizontalPageScrollBehavior,
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: (ScrollUpdateNotification notification) {
              if (notification.dragDetails != null) _stopAutoReading();
              final double? page = _pageController.hasClients
                  ? _pageController.page
                  : null;
              if (page != null && notification.scrollDelta != null) {
                _pageTurnForward = notification.scrollDelta! > 0;
              }
              return false;
            },
            child: PageView.builder(
              controller: _pageController,
              physics: _usesDirectPageTurns
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              itemCount: _pages.length + 2,
              onPageChanged: _onHorizontalPageChanged,
              itemBuilder: (BuildContext context, int index) {
                final Widget page = index == 0
                    ? _chapterBoundary(ReaderStrings.previousChapter)
                    : index == _pages.length + 1
                    ? _chapterBoundary(ReaderStrings.nextChapter)
                    : _buildPage(_pages[index - 1], index - 1);
                return _buildPageEffect(index, page);
              },
            ),
          ),
        ),
      ),
    );
  }

  bool get _usesDirectPageTurns =>
      _preferences.pageAnimation == ReaderPageAnimation.none ||
      MediaQuery.disableAnimationsOf(context);

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _changingChapter) return;
    final double delta =
        event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    _wheelDelta += delta;
    _wheelResetTimer?.cancel();
    _wheelResetTimer = Timer(const Duration(milliseconds: 140), () {
      _wheelDelta = 0;
    });
    if (_wheelDelta.abs() < 36) return;
    final bool forward = _wheelDelta > 0;
    _wheelDelta = 0;
    if (forward) {
      unawaited(_nextPage());
    } else {
      unawaited(_previousPage());
    }
  }

  Widget _chapterBoundary(String label) {
    return Center(
      child: _changingChapter
          ? const CircularProgressIndicator(strokeWidth: 2)
          : Text(label, style: TextStyle(color: _palette.secondaryText)),
    );
  }

  Widget _buildPageEffect(int rawIndex, Widget child) {
    if (_preferences.pageAnimation == ReaderPageAnimation.slide) return child;
    final Widget effectChild =
        _preferences.pageAnimation == ReaderPageAnimation.cover
        ? ReaderBackgroundSurface(
            preset: _preferences.background,
            palette: _palette,
            child: child,
          )
        : child;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return AnimatedBuilder(
          animation: _pageController,
          child: effectChild,
          builder: (BuildContext context, Widget? child) {
            final double page = _pageController.hasClients
                ? (_pageController.page ??
                      _pageController.initialPage.toDouble())
                : _pageController.initialPage.toDouble();
            final double distance = (rawIndex - page)
                .abs()
                .clamp(0, 1)
                .toDouble();
            final bool entering = _pageTurnForward
                ? rawIndex > page
                : rawIndex < page;
            return Transform.translate(
              offset: Offset((page - rawIndex) * constraints.maxWidth, 0),
              child: ReaderPageEffect(
                animation: _preferences.pageAnimation,
                progress: entering ? 1 - distance : distance,
                entering: entering,
                forward: _pageTurnForward,
                reduceMotion: MediaQuery.disableAnimationsOf(context),
                child: child!,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildPage(ReaderPage page, int index) {
    return SafeArea(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                _preferences.horizontalPadding,
                _preferences.topPadding,
                _preferences.horizontalPadding,
                _preferences.bottomPadding,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (page.showsTitle) ...<Widget>[
                    Text(
                      _content!.title,
                      style: _titleTextStyle,
                      textScaler: _textScaler,
                    ),
                    const SizedBox(height: 28),
                  ],
                  for (final ReaderPageBlock block in page.blocks) ...<Widget>[
                    if (block.text.isNotEmpty || block.hasParagraphTrailing)
                      Text.rich(
                        TextSpan(
                          style: _bodyTextStyle,
                          children: <InlineSpan>[
                            TextSpan(
                              text: block.text.isEmpty
                                  ? ''
                                  : block.isParagraphStart
                                  ? _indented(block.text)
                                  : block.text,
                            ),
                            if (block.hasParagraphTrailing &&
                                _preferences.showParagraphComments)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: _inlineParagraphComment(
                                  target: ReaderCommentTarget.paragraph(
                                    widget.bookId,
                                    _content!.chapterId,
                                    block.paragraphId,
                                  ),
                                  onPressed: () => _showComments(
                                    ReaderCommentTarget.paragraph(
                                      widget.bookId,
                                      _content!.chapterId,
                                      block.paragraphId,
                                    ),
                                    title: ReaderCommentStrings.paragraphTitle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        textScaler: _textScaler,
                      ),
                    if (block.isParagraphEnd)
                      SizedBox(height: _preferences.paragraphSpacing),
                  ],
                  if (page.showsChapterTrailing)
                    _buildChapterCommentSummary(
                      height: page.chapterTrailingHeight,
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            key: const ValueKey<String>('reader-page-footer'),
            left: _preferences.horizontalPadding,
            right: _preferences.horizontalPadding,
            bottom: _pageFooterBottomInset,
            child: IgnorePointer(
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _content!.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _palette.secondaryText,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Text(
                    '${((_progress?.bookFraction ?? 0) * 100).toStringAsFixed(1)}% · ${index + 1}/${_pages.length}',
                    style: TextStyle(
                      color: _palette.secondaryText,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _clockLabel,
                    style: TextStyle(
                      color: _palette.secondaryText,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterCommentSummary({double height = 168}) {
    final TextChapterContent? content = _content;
    if (content == null || widget.extensions.commentFeed == null) {
      return const SizedBox.shrink();
    }
    final ReaderCommentTarget target = ReaderCommentTarget.chapter(
      widget.bookId,
      content.chapterId,
    );
    final ReaderCommentSummary summary = _commentSummary(target);
    final bool loading = _commentSummariesLoading;
    final bool failed = _commentSummariesFailed;
    final double resolvedHeight = height.clamp(0, 168).toDouble();
    return SizedBox(
      height: resolvedHeight,
      child: Material(
        color: _palette.panel.withValues(alpha: .82),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: _palette.divider),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: loading
              ? null
              : failed
              ? () => unawaited(_refreshCommentSummaries())
              : () => _showComments(
                  target,
                  title: ReaderCommentStrings.chapterTitle,
                ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 17,
                      color: _palette.accent,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        loading
                            ? ReaderCommentStrings.chapterLoading
                            : failed
                            ? ReaderCommentStrings.chapterLoadFailed
                            : ReaderCommentStrings.chapterSummary(
                                summary.total,
                              ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, size: 19),
                  ],
                ),
                const SizedBox(height: 8),
                if (!loading && !failed && summary.topComments.isEmpty)
                  Text(
                    ReaderCommentStrings.empty,
                    style: TextStyle(color: _palette.secondaryText),
                  )
                else if (!loading && !failed)
                  for (final ReaderComment comment in summary.topComments.take(
                    3,
                  ))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        '${comment.authorName}：${comment.content}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _palette.secondaryText,
                          fontSize: 12,
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVerticalReader() {
    final List<TextParagraph> paragraphs = _content!.paragraphs;
    final bool showChapterComments =
        widget.extensions.commentFeed != null &&
        _preferences.showChapterComments;
    final bool showParagraphComments =
        widget.extensions.commentFeed != null &&
        _preferences.showParagraphComments;
    final int chapterSummaryIndex = paragraphs.length + 1;
    final int nextChapterIndex =
        chapterSummaryIndex + (showChapterComments ? 1 : 0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapUp: (_) {
        _stopAutoReading();
        _setControlsVisible(!_controlsVisible);
      },
      child: SafeArea(
        child: NotificationListener<UserScrollNotification>(
          onNotification: (UserScrollNotification notification) {
            if (!_autoScrolling &&
                notification.direction != ScrollDirection.idle) {
              _stopAutoReading();
            }
            return false;
          },
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double contentWidth =
                  (constraints.maxWidth - _preferences.horizontalPadding * 2)
                      .clamp(1, constraints.maxWidth.clamp(1, double.infinity));
              _prepareVerticalItemExtents(
                width: contentWidth,
                textDirection: Directionality.of(context),
                itemCount: nextChapterIndex + 1,
                hasParagraphComments: showParagraphComments,
                hasChapterComments: showChapterComments,
              );
              return ListView.builder(
                controller: _verticalController,
                padding: EdgeInsets.fromLTRB(
                  _preferences.horizontalPadding,
                  _preferences.topPadding,
                  _preferences.horizontalPadding,
                  _preferences.bottomPadding,
                ),
                itemCount: nextChapterIndex + 1,
                itemExtentBuilder: (int index, _) => _verticalItemExtent(index),
                itemBuilder: (BuildContext context, int index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 28),
                      child: Text(
                        _content!.title,
                        style: _titleTextStyle,
                        textScaler: _textScaler,
                      ),
                    );
                  }
                  if (index <= paragraphs.length) {
                    final TextParagraph paragraph = paragraphs[index - 1];
                    final ReaderCommentTarget target =
                        ReaderCommentTarget.paragraph(
                          widget.bookId,
                          _content!.chapterId,
                          paragraph.id,
                        );
                    return Column(
                      key: _paragraphKey(paragraph.id),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: _preferences.paragraphSpacing,
                          ),
                          child: Text.rich(
                            TextSpan(
                              style: _bodyTextStyle,
                              children: <InlineSpan>[
                                TextSpan(text: _indented(paragraph.text)),
                                if (showParagraphComments)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: _inlineParagraphComment(
                                      target: target,
                                      onPressed: () => _showComments(
                                        target,
                                        title:
                                            ReaderCommentStrings.paragraphTitle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            textScaler: _textScaler,
                          ),
                        ),
                      ],
                    );
                  }
                  if (showChapterComments && index == chapterSummaryIndex) {
                    return _buildChapterCommentSummary();
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: OutlinedButton(
                      onPressed: _nextChapter,
                      child: const Text(ReaderStrings.nextChapter),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildChrome() {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: Stack(
          children: <Widget>[
            Align(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[_buildTopBar(), _buildSourceInfoBar()],
              ),
            ),
            Align(alignment: Alignment.bottomCenter, child: _buildBottomBar()),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Material(
      color: _palette.panel,
      elevation: 0,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: 54,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: _palette.divider)),
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: ReaderStrings.back,
                onPressed: _requestExit,
                icon: const Icon(Icons.arrow_back_ios_new_rounded),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _book?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      _content?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _palette.secondaryText,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _isCurrentBookmarked
                    ? ReaderStrings.removeBookmark
                    : ReaderStrings.addBookmark,
                onPressed: _toggleBookmark,
                icon: Icon(
                  _isCurrentBookmarked
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  color: _isCurrentBookmarked ? _palette.accent : null,
                ),
              ),
              IconButton(
                tooltip: ReaderStrings.refreshChapter,
                onPressed: _content == null
                    ? null
                    : () => unawaited(_refreshCurrentChapter()),
                icon: const Icon(Icons.refresh_rounded, size: 21),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSourceInfoBar() {
    final String sourceName = _sourceDisplayName;
    final String? chapterUrl = _currentChapterUrl;
    final Uri? chapterUri = _currentChapterUri;
    final Widget chapterUrlLabel = Row(
      children: <Widget>[
        Icon(
          Icons.open_in_new_rounded,
          size: 16,
          color: chapterUri == null ? _palette.secondaryText : _palette.accent,
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            chapterUrl ?? ReaderStrings.chapterUrlUnavailable,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: chapterUri == null
                  ? _palette.secondaryText
                  : _palette.text,
              fontSize: 12,
              decoration: chapterUri == null ? null : TextDecoration.underline,
              decorationColor: _palette.accent,
            ),
          ),
        ),
      ],
    );

    final Widget chapterUrlAction = chapterUri == null
        ? SizedBox(height: 48, child: chapterUrlLabel)
        : Tooltip(
            message: chapterUrl!,
            child: Semantics(
              button: true,
              link: true,
              label: '${ReaderStrings.openChapterUrl}: $chapterUrl',
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => unawaited(_openCurrentChapterUrl()),
                child: SizedBox(height: 48, child: chapterUrlLabel),
              ),
            ),
          );

    return Material(
      color: _palette.panel.withValues(alpha: 0.92),
      child: Container(
        height: 48,
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: _palette.divider)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 2,
              child: Text(
                '${ReaderStrings.source}: $sourceName',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _palette.secondaryText, fontSize: 12),
              ),
            ),
            Container(width: 1, height: 16, color: _palette.divider),
            const SizedBox(width: 9),
            Expanded(
              flex: 3,
              child: Semantics(
                label: ReaderStrings.chapterUrl,
                child: chapterUrlAction,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _refreshCurrentChapter() async {
    final String? chapterId = _content?.chapterId;
    if (chapterId == null) return;
    await _openChapter(chapterId, forceRefresh: true);
  }

  String get _sourceDisplayName {
    final String? sourceName = _book?.sourceName?.trim();
    return sourceName == null || sourceName.isEmpty
        ? ReaderStrings.sourceUnavailable
        : sourceName;
  }

  String? get _currentChapterUrl {
    final String? chapterUrl = _content?.chapterUrl?.trim();
    return chapterUrl == null || chapterUrl.isEmpty ? null : chapterUrl;
  }

  Uri? get _currentChapterUri {
    final String? chapterUrl = _currentChapterUrl;
    final Uri? uri = chapterUrl == null ? null : Uri.tryParse(chapterUrl);
    if (uri == null || uri.host.isEmpty) return null;
    return switch (uri.scheme) {
      'http' || 'https' => uri,
      _ => null,
    };
  }

  Future<void> _openCurrentChapterUrl() async {
    final Uri? uri = _currentChapterUri;
    if (uri == null) {
      await _reportFailure(
        const ReaderFailure(
          ReaderFailureKind.platform,
          ReaderStrings.chapterUrlInvalid,
        ),
      );
      return;
    }
    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw StateError(ReaderStrings.chapterUrlOpenFailed);
      }
    } catch (error) {
      await _reportFailure(_asFailure(error, ReaderFailureKind.platform));
    }
  }

  Widget _buildBottomBar() {
    final double progress = _sliderPreview ?? _progress?.bookFraction ?? 0;
    return Material(
      color: _palette.panel,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: _palette.divider)),
          ),
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(58, 44),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    onPressed: _previousChapter,
                    child: const Text(ReaderStrings.previousChapter),
                  ),
                  Expanded(
                    child: Slider(
                      value: progress.clamp(0, 1),
                      onChanged: (double value) =>
                          setState(() => _sliderPreview = value),
                      onChangeEnd: _jumpToBookFraction,
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(58, 44),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                    onPressed: _nextChapter,
                    child: const Text(ReaderStrings.nextChapter),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  _barAction(
                    Icons.menu_book_outlined,
                    ReaderStrings.catalog,
                    () => _showLibrarySheet(initialIndex: 1),
                  ),
                  _barAction(
                    _isNightTheme(_preferences.theme)
                        ? Icons.nightlight_rounded
                        : Icons.nightlight_outlined,
                    ReaderStrings.night,
                    _toggleNightTheme,
                  ),
                  _barAction(
                    Icons.tune_rounded,
                    ReaderStrings.settings,
                    _showSettingsSheet,
                  ),
                  _barAction(
                    Icons.bookmarks_outlined,
                    ReaderStrings.bookmarks,
                    () => _showLibrarySheet(initialIndex: 2),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barAction(IconData icon, String label, VoidCallback action) {
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: action,
            child: SizedBox(
              height: 50,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(icon, size: 21),
                  const SizedBox(height: 2),
                  Text(label, style: const TextStyle(fontSize: 10.5)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _clockLabel {
    final String hour = _clock.hour.toString().padLeft(2, '0');
    final String minute = _clock.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _jumpToBookFraction(double value) async {
    setState(() => _sliderPreview = null);
    final int navigation = ++_navigationGeneration;
    final int session = _sessionGeneration;
    if (value <= 0) {
      await _showBookPreview();
      return;
    }
    final int total = _catalogTotal > 0 ? _catalogTotal : _catalog.length;
    if (total <= 0) return;
    final double exact = (value.clamp(0, 1) * total)
        .clamp(0, total - 0.000001)
        .toDouble();
    final int index = exact.floor().clamp(0, total - 1);
    final double chapterFraction = exact - index;
    try {
      final ReaderChapterInfo chapter = await _chapterInfoAtIndex(index);
      if (!_isSessionCurrent(session) || navigation != _navigationGeneration) {
        return;
      }
      await _openChapter(chapter.id, targetChapterFraction: chapterFraction);
    } catch (error) {
      if (!_isSessionCurrent(session) || navigation != _navigationGeneration) {
        return;
      }
      await _reportFailure(_asFailure(error, ReaderFailureKind.data));
    }
  }

  bool get _isCurrentBookmarked {
    final ReaderProgress? progress = _progress;
    if (progress == null) return false;
    return _bookmarks.any(
      (bookmark) =>
          bookmark.chapterId == progress.chapterId &&
          bookmark.paragraphId == progress.paragraphId,
    );
  }

  Future<void> _toggleBookmark() {
    _stopAutoReading();
    final int session = _sessionGeneration;
    return _queueBookmarkMutation(() async {
      if (!_isSessionCurrent(session)) return;
      await _performToggleBookmark(session);
    });
  }

  Future<void> _performToggleBookmark(int session) async {
    final ReaderProgress? progress = _progress;
    final TextChapterContent? content = _content;
    if (progress == null || content == null || content.paragraphs.isEmpty) {
      return;
    }
    final int existing = _bookmarks.indexWhere(
      (bookmark) =>
          bookmark.chapterId == progress.chapterId &&
          bookmark.paragraphId == progress.paragraphId,
    );
    final TextReaderStateStore store = widget.stateStore;
    final String bookId = widget.bookId;
    final int session = _sessionGeneration;
    try {
      if (existing >= 0) {
        final ReaderBookmark bookmark = _bookmarks[existing];
        await store.removeBookmark(bookId, bookmark.id);
        if (!mounted ||
            session != _sessionGeneration ||
            bookId != widget.bookId ||
            !identical(store, widget.stateStore)) {
          return;
        }
        setState(() {
          _bookmarks = List.unmodifiable(
            _bookmarks.where((item) => item.id != bookmark.id),
          );
        });
      } else {
        final TextParagraph paragraph = content.paragraphs.firstWhere(
          (item) => item.id == progress.paragraphId,
          orElse: () => content.paragraphs.first,
        );
        final ReaderBookmark bookmark = ReaderBookmark(
          id: '${widget.bookId}-${DateTime.now().microsecondsSinceEpoch}',
          bookId: widget.bookId,
          chapterId: progress.chapterId,
          paragraphId: progress.paragraphId,
          characterOffset: progress.characterOffset,
          chapterTitle: content.title,
          excerpt: paragraph.text.length > 48
              ? '${paragraph.text.substring(0, 48)}…'
              : paragraph.text,
          createdAt: DateTime.now(),
        );
        await store.addBookmark(bookmark);
        if (!mounted ||
            session != _sessionGeneration ||
            bookId != widget.bookId ||
            !identical(store, widget.stateStore)) {
          return;
        }
        setState(
          () => _bookmarks = List.unmodifiable(<ReaderBookmark>[
            ..._bookmarks,
            bookmark,
          ]),
        );
      }
    } catch (error) {
      if (_isSessionCurrent(session)) {
        await _reportFailure(_asFailure(error, ReaderFailureKind.persistence));
      }
    }
  }

  Future<void> _queueBookmarkMutation(Future<void> Function() mutation) {
    final Future<void> next = _bookmarkWrite.then(
      (_) => mutation(),
      onError: (_) => mutation(),
    );
    _bookmarkWrite = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  bool _isRouteSessionCurrent(
    int session,
    String bookId, {
    TextReaderStateStore? store,
  }) =>
      mounted &&
      !_disposed &&
      session == _sessionGeneration &&
      bookId == widget.bookId &&
      (store == null || identical(store, widget.stateStore));

  void _showLibrarySheet({int initialIndex = 1}) {
    _stopAutoReading();
    unawaited(_refreshLoadedChapterStates());
    final int routeSession = _sessionGeneration;
    final String routeBookId = widget.bookId;
    final TextReaderStateStore routeStore = widget.stateStore;
    bool sheetRefreshStarted = false;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      backgroundColor: Colors.transparent,
      barrierColor: ReaderSettingsTokens.sheetBarrier(_palette),
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            if (!sheetRefreshStarted) {
              sheetRefreshStarted = true;
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                if (!_isRouteSessionCurrent(
                  routeSession,
                  routeBookId,
                  store: routeStore,
                )) {
                  return;
                }
                await _refreshCommentSummaries();
                if (sheetContext.mounted &&
                    _isRouteSessionCurrent(
                      routeSession,
                      routeBookId,
                      store: routeStore,
                    )) {
                  setSheetState(() {});
                }
              });
            }
            final MediaQueryData mediaQuery = MediaQuery.of(context);
            final double sheetHeight = (mediaQuery.size.height * 0.74)
                .clamp(0, 640)
                .toDouble();
            return MediaQuery(
              data: mediaQuery.copyWith(
                textScaler: mediaQuery.textScaler.clamp(maxScaleFactor: 1.3),
              ),
              // Limit the route child to the visible panel so the uncovered
              // reader area remains the tappable modal barrier.
              child: SizedBox(
                width: double.infinity,
                height: sheetHeight,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: SizedBox(
                      height: sheetHeight,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(20),
                        ),
                        child: Material(
                          color: _palette.panel,
                          child: SafeArea(
                            top: false,
                            child: DefaultTabController(
                              length: 3,
                              initialIndex: initialIndex,
                              child: Column(
                                children: <Widget>[
                                  const SizedBox(height: 8),
                                  Container(
                                    width: 34,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: _palette.divider,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  const TabBar(
                                    dividerHeight: 1,
                                    labelStyle: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    tabs: <Widget>[
                                      Tab(text: ReaderStrings.bookDetails),
                                      Tab(text: ReaderStrings.catalog),
                                      Tab(text: ReaderStrings.bookmarks),
                                    ],
                                  ),
                                  Expanded(
                                    child: TabBarView(
                                      children: <Widget>[
                                        _buildBookDetailTab(
                                          routeSession,
                                          routeBookId,
                                        ),
                                        _buildCatalogList(
                                          sheetContext,
                                          routeSession,
                                          routeBookId,
                                          routeStore,
                                        ),
                                        _buildBookmarkList(
                                          sheetContext,
                                          routeSession,
                                          routeBookId,
                                          routeStore,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBookDetailTab(int routeSession, String routeBookId) {
    final ReaderBookInfo? book = _book;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  book?.title ?? ReaderStrings.bookPreview,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (book?.author?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    book!.author!,
                    style: TextStyle(
                      color: _palette.secondaryText,
                      fontSize: 13,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.format_list_numbered_rounded,
                      size: 16,
                      color: _palette.secondaryText,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      ReaderStrings.chapterCount(_catalogTotal),
                      style: TextStyle(
                        color: _palette.secondaryText,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                if (book?.description?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 14),
                  Text(
                    book!.description!,
                    style: const TextStyle(fontSize: 14, height: 1.6),
                  ),
                ],
                if (widget.extensions.commentFeed != null &&
                    _preferences.showBookComments) ...<Widget>[
                  const SizedBox(height: 16),
                  _buildBookCommentSummary(
                    target: ReaderCommentTarget.book(routeBookId),
                    onPressed: () {
                      if (!_isRouteSessionCurrent(routeSession, routeBookId)) {
                        return;
                      }
                      _showComments(
                        ReaderCommentTarget.book(routeBookId),
                        title: ReaderCommentStrings.bookTitle,
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCatalogList(
    BuildContext sheetContext,
    int routeSession,
    String routeBookId,
    TextReaderStateStore routeStore,
  ) {
    Widget buildList() => StatefulBuilder(
      builder: (BuildContext context, StateSetter setSheetState) {
        if (_catalog.isEmpty && !_catalogHasMore && !_catalogLoading) {
          return _ReaderEmptyState(
            icon: Icons.menu_book_outlined,
            message: ReaderStrings.noChapters,
            color: _palette.secondaryText,
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
          itemCount: _catalog.length + (_catalogHasMore ? 1 : 0),
          itemBuilder: (BuildContext context, int index) {
            if (index == _catalog.length) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton(
                  onPressed: _catalogLoading
                      ? null
                      : () async {
                          if (!_isRouteSessionCurrent(
                            routeSession,
                            routeBookId,
                            store: routeStore,
                          )) {
                            return;
                          }
                          await _loadMoreCatalog();
                          if (!sheetContext.mounted ||
                              !_isRouteSessionCurrent(
                                routeSession,
                                routeBookId,
                                store: routeStore,
                              )) {
                            return;
                          }
                          setSheetState(() {});
                        },
                  child: Text(
                    _catalogLoading
                        ? ReaderStrings.loading
                        : ReaderStrings.loadMoreChapters,
                  ),
                ),
              );
            }
            final ReaderChapterInfo chapter = _catalog[index];
            final ReaderChapterState? refreshedState =
                _chapterAccessCoordinator?.snapshot.states[chapter.id];
            final ReaderChapterAvailability availability =
                refreshedState == null
                ? chapter.availability
                : refreshedState.availability;
            final int? wordCount = refreshedState == null
                ? chapter.wordCount
                : refreshedState.wordCount;
            final bool hasBeenRead = refreshedState == null
                ? chapter.hasBeenRead
                : refreshedState.hasBeenRead;
            final bool isLocal =
                _book?.sourceKind == ReaderBookSourceKind.local;
            final bool stateLoading =
                _chapterAccessCoordinator?.snapshot.loading == true;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListTile(
                  selected: chapter.id == _content?.chapterId,
                  selectedColor: _palette.accent,
                  selectedTileColor: _palette.accent.withValues(alpha: .08),
                  leading: SizedBox(
                    width: 34,
                    child: Text(
                      '${chapter.index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: chapter.id == _content?.chapterId
                            ? _palette.accent
                            : _palette.secondaryText,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  title: Text(
                    chapter.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle:
                      !isLocal &&
                          !stateLoading &&
                          availability == ReaderChapterAvailability.unknown
                      ? ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              hasBeenRead
                                  ? '${ReaderStrings.chapterStateUnknown} · ${ReaderChapterStateStrings.read}'
                                  : ReaderStrings.chapterStateUnknown,
                              style: TextStyle(
                                color: _palette.secondaryText,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        )
                      : ReaderChapterStateBadge(
                          availability: isLocal
                              ? ReaderChapterAvailability.unknown
                              : availability,
                          wordCount:
                              isLocal ||
                                  availability ==
                                      ReaderChapterAvailability.downloaded
                              ? wordCount
                              : null,
                          hasBeenRead: hasBeenRead,
                          loading:
                              !isLocal &&
                              stateLoading &&
                              refreshedState == null,
                          palette: _palette,
                          onRetry:
                              availability == ReaderChapterAvailability.failed
                              ? () => unawaited(
                                  _refreshLoadedChapterStates(
                                    chapterId: chapter.id,
                                  ),
                                )
                              : null,
                        ),
                  onTap: () {
                    if (!_isRouteSessionCurrent(
                      routeSession,
                      routeBookId,
                      store: routeStore,
                    )) {
                      return;
                    }
                    Navigator.of(sheetContext).pop();
                    unawaited(_openChapter(chapter.id));
                  },
                ),
              ),
            );
          },
        );
      },
    );
    final ReaderChapterAccessCoordinator? coordinator =
        _chapterAccessCoordinator;
    if (coordinator == null) return buildList();
    return AnimatedBuilder(
      animation: coordinator,
      builder: (BuildContext context, Widget? child) => buildList(),
    );
  }

  Widget _buildBookmarkList(
    BuildContext sheetContext,
    int routeSession,
    String routeBookId,
    TextReaderStateStore routeStore,
  ) {
    if (_bookmarks.isEmpty) {
      return _ReaderEmptyState(
        icon: Icons.bookmark_border_rounded,
        message: ReaderStrings.noBookmarks,
        color: _palette.secondaryText,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      itemCount: _bookmarks.length,
      itemBuilder: (BuildContext context, int index) {
        final ReaderBookmark bookmark = _bookmarks[index];
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: Icon(
                Icons.bookmark_outline_rounded,
                size: 20,
                color: _palette.accent,
              ),
              title: Text(bookmark.chapterTitle),
              subtitle: Text(
                bookmark.excerpt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: ReaderStrings.removeBookmark,
                icon: const Icon(Icons.close_rounded, size: 19),
                onPressed: () async {
                  await _queueBookmarkMutation(() async {
                    if (!_isRouteSessionCurrent(
                          routeSession,
                          routeBookId,
                          store: routeStore,
                        ) ||
                        _bookmarks.every((item) => item.id != bookmark.id)) {
                      return;
                    }
                    try {
                      await routeStore.removeBookmark(routeBookId, bookmark.id);
                    } catch (error) {
                      if (_isRouteSessionCurrent(
                        routeSession,
                        routeBookId,
                        store: routeStore,
                      )) {
                        await _reportFailure(
                          _asFailure(error, ReaderFailureKind.persistence),
                        );
                      }
                      return;
                    }
                    if (!sheetContext.mounted ||
                        !_isRouteSessionCurrent(
                          routeSession,
                          routeBookId,
                          store: routeStore,
                        )) {
                      return;
                    }
                    setState(() {
                      _bookmarks = List.unmodifiable(
                        _bookmarks.where((item) => item.id != bookmark.id),
                      );
                    });
                    Navigator.of(sheetContext).pop();
                  });
                },
              ),
              onTap: () {
                if (!_isRouteSessionCurrent(
                      routeSession,
                      routeBookId,
                      store: routeStore,
                    ) ||
                    bookmark.bookId != routeBookId) {
                  return;
                }
                _progress = ReaderProgress(
                  chapterId: bookmark.chapterId,
                  paragraphId: bookmark.paragraphId,
                  characterOffset: bookmark.characterOffset,
                );
                Navigator.of(sheetContext).pop();
                unawaited(_openChapter(bookmark.chapterId, initial: true));
              },
            ),
          ),
        );
      },
    );
  }

  void _showSettingsSheet() {
    _stopAutoReading();
    final int routeSession = _sessionGeneration;
    final String routeBookId = widget.bookId;
    final TextReaderStateStore routeStore = widget.stateStore;
    bool routeIsCurrent() =>
        _isRouteSessionCurrent(routeSession, routeBookId, store: routeStore);
    unawaited(
      showReaderSettingsSheet(
        context: context,
        preferences: _preferences,
        palette: _palette,
        platformCapabilities: _platformCapabilities,
        commentsAvailable: widget.extensions.commentFeed != null,
        autoReading: _autoReadingCoordinator.isRunning,
        autoReadingPace: _autoReadingPace,
        lastNonNightTheme: _lastNonNightTheme,
        fontRepository: widget.extensions.fontRepository,
        onCustomFontSelected:
            (ReaderFontDescriptor descriptor, String runtimeFamily) {
              if (!routeIsCurrent()) return;
              _applySelectedCustomFont(descriptor, runtimeFamily);
            },
        onFontError: (Object error) {
          if (!routeIsCurrent()) return;
          unawaited(_reportFailure(_asFailure(error, ReaderFailureKind.data)));
        },
        onPreferencesPreview: (TextReaderPreferences preferences) {
          if (!routeIsCurrent()) return;
          unawaited(_applyPreferences(preferences, persist: false));
        },
        onPreferencesCommit: (TextReaderPreferences preferences) {
          if (!routeIsCurrent()) return;
          unawaited(_updatePreferences(preferences));
        },
        onAutoReadingChanged: (bool enabled) {
          if (!routeIsCurrent()) return;
          if (enabled) {
            Navigator.of(context).pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (routeIsCurrent()) unawaited(_startAutoReading());
            });
          } else {
            _stopAutoReading();
          }
        },
        onAutoReadingPaceChanged: (ReaderAutoReadingPace pace) {
          if (!routeIsCurrent()) return;
          _autoReadingPace = pace;
          if (_autoReadingCoordinator.isRunning) {
            unawaited(_startAutoReading());
          }
        },
        onCatalogPressed: () {
          if (!routeIsCurrent()) return;
          Navigator.of(context).pop();
          _showLibrarySheet(initialIndex: 1);
        },
        onBookmarksPressed: () {
          if (!routeIsCurrent()) return;
          Navigator.of(context).pop();
          _showLibrarySheet(initialIndex: 2);
        },
        onDismissed: () {
          if (routeIsCurrent()) _commitPreferencePreview();
        },
      ),
    );
  }

  void _toggleNightTheme() {
    _stopAutoReading();
    final ReaderThemePreset next = _isNightTheme(_preferences.theme)
        ? _lastNonNightTheme
        : ReaderThemePreset.night;
    unawaited(_updatePreferences(_preferences.copyWith(theme: next)));
  }

  bool _isNightTheme(ReaderThemePreset theme) =>
      theme == ReaderThemePreset.night ||
      theme == ReaderThemePreset.deepNight ||
      theme == ReaderThemePreset.charcoal;
}

class _CenteredStatus extends StatelessWidget {
  const _CenteredStatus({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DefaultTextStyle(
      style: TextStyle(color: color, fontSize: 15),
      child: Center(child: child),
    );
  }
}

class _ReaderEmptyState extends StatelessWidget {
  const _ReaderEmptyState({
    required this.icon,
    required this.message,
    required this.color,
  });

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 32, color: color),
          const SizedBox(height: 10),
          Text(message, style: TextStyle(color: color, fontSize: 14)),
        ],
      ),
    );
  }
}

class _ReaderNotice extends StatelessWidget {
  const _ReaderNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SafeArea(
        child: Align(
          alignment: const Alignment(0, 0.72),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xE62A2926),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                message,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReaderScrollBehavior extends MaterialScrollBehavior {
  const _ReaderScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
  };
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
