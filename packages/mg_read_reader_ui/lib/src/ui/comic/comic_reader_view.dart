/// 漫画阅读器会话视图。
///
/// 职责：
/// - 协调漫画章节窗口、图片缓存、语义进度和阅读器 chrome。
/// - 通过宿主端口获取内容，只向下拼接有限的后续章节资源，并按宿主配置顺序预缓存后续章节。
/// - 为漫画内容提供固定白色底层，并让触控与桌面鼠标共享纵向拖动语义。
///
/// 注意：
/// - 不直接访问网络、文件或数据库；异步结果必须验证会话世代。
/// - 图片缓存、滚动控制器、监听器和常亮资源必须在会话结束时成对释放。
/// - 设备内存快照只调整图片上限；前台周期评估，后台/销毁取消，内存压力立即收缩。
///
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderBox, ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/contracts.dart';
import '../../api/comic_contracts.dart';
import '../../api/comic_controller.dart';
import '../../api/comic_models.dart';
import '../../api/models.dart';
import '../../platform/reader_platform.dart';
import '../../platform/screen_awake_coordinator.dart';
import '../comments/reader_comment_strings.dart';
import '../comments/reader_comment_widgets.dart';
import '../reader_strings.dart';
import '../reader_theme.dart';
import '../reader_source_strip.dart';
import 'comic_image_cache.dart';
import 'comic_chapter_preloader.dart';
import 'comic_image_retry_coordinator.dart';
import 'comic_image_tile.dart';
import 'comic_image_memory_policy.dart';
import 'comic_reader_strings.dart';
import 'comic_scroll_physics.dart';

part 'comic_reader_session.dart';
part 'comic_reader_preferences.dart';
part 'comic_reader_memory.dart';
part 'comic_reader_catalog.dart';
part 'comic_reader_chrome.dart';
part 'comic_reader_page_turning.dart';
part 'comic_reader_sheets.dart';

const Color _comicReaderChromeColor = Color(0xFF17191B);

const _comicReaderImmersiveSystemUiStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemStatusBarContrastEnforced: false,
  systemNavigationBarContrastEnforced: false,
);

const _comicReaderControlsSystemUiStyle = SystemUiOverlayStyle(
  statusBarColor: _comicReaderChromeColor,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: _comicReaderChromeColor,
  systemNavigationBarDividerColor: _comicReaderChromeColor,
  systemNavigationBarIconBrightness: Brightness.light,
  systemStatusBarContrastEnforced: false,
  systemNavigationBarContrastEnforced: false,
);

/// A vertically scrolling, progressively loaded comic reading surface.
///
/// The host owns networking, files, authentication, and persistent image
/// caching through [ComicReaderDataSource]. This widget retains only the
/// current and following chapter metadata plus a bounded session byte cache.
class ComicReaderView extends StatefulWidget {
  /// Creates an embeddable comic reader connected to host data and state.
  const ComicReaderView({
    super.key,
    required this.bookId,
    required this.dataSource,
    required this.stateStore,
    this.chapterPreloadCount = 1,
    this.observer,
    this.controller,
    this.commentFeed,
    this.bookRefreshCapability,
    this.catalogRefreshToken = 0,
  }) : assert(chapterPreloadCount >= 0 && chapterPreloadCount <= 5);

  /// Stable host identifier for the comic.
  final String bookId;

  /// Asynchronous source for catalog, image metadata, and encoded image bytes.
  final ComicReaderDataSource dataSource;

  /// Host-owned persistence for progress, preferences, and bookmarks.
  final ComicReaderStateStore stateStore;

  /// Number of following comic chapters cached after the current chapter.
  ///
  /// The current chapter is always cached. Zero disables only speculative
  /// following-chapter work.
  final int chapterPreloadCount;

  /// Optional notification sink. Callback failures never block reading.
  final ComicReaderObserver? observer;

  /// Optional host-owned command controller.
  final ComicReaderController? controller;

  /// Optional read-only feed for fixed-overlay comic image comment entries.
  ///
  /// The reader never reserves image layout space when this is null.
  final ReaderCommentFeed? commentFeed;

  /// Optional host-owned full book refresh. The action is hidden when absent.
  final ReaderBookRefreshCapability? bookRefreshCapability;

  /// Monotonic host signal for an already-open background catalog append.
  final int catalogRefreshToken;

  @override
  State<ComicReaderView> createState() => _ComicReaderViewState();
}

class _ComicReaderViewState extends State<ComicReaderView>
    with WidgetsBindingObserver {
  static const Duration _saveDelay = Duration(milliseconds: 800);
  static const int _catalogPageSize = 50;
  static const int _metadataWindowLimit = 3;
  static const int _maxSingleImageBytes = 8 * 1024 * 1024;
  static const double _chapterHeaderExtent = 54;
  static const double _boundaryExtent = 72;
  static const double _defaultAspectRatio = .75;
  static const double _progressProbeFraction = .34;

  final Object _controllerOwner = Object();
  final Object _awakeHolder = Object();
  final FocusNode _focusNode = FocusNode(debugLabel: 'ComicReader');
  StreamSubscription<ReaderVolumeKey>? _volumeKeySubscription;
  final ScrollController _scrollController = ScrollController();
  final ComicDecodedImageBudget _decodeBudget = ComicDecodedImageBudget();
  ComicImageMemoryPolicy _imageMemoryPolicy = ComicImageMemoryPolicy.fallback;
  Timer? _memoryBudgetTimer;
  Timer? _memoryProbeTimer;
  Completer<ReaderDeviceMemoryInfo?>? _memoryProbeStop;
  int _memoryBudgetGeneration = 0;
  bool _memoryInfoSupported = false;
  final ComicImageRetryCoordinator _imageRetryCoordinator =
      ComicImageRetryCoordinator();
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
  final Map<int, int> _boundaryLoadOwners = <int, int>{};
  final Set<String> _catalogCursors = <String>{};
  int _catalogPageCoverage = 0;
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
  ComicChapterInfo? _pendingChapter;
  String? _catalogCursor;
  int _catalogTotal = 0;
  bool _catalogHasMore = false;
  bool _catalogLoading = false;
  bool _loading = true;
  bool _controlsVisible = false;
  bool _bookRefreshLoading = false;
  bool _settingsVisible = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _restoring = false;
  bool _preferencesDirty = false;
  bool _preferencesAuthoritative = false;
  bool _firstContentPresented = false;
  ComicChapterPreloader? _preloader;
  ValueNotifier<int>? _activeCatalogRevision;
  bool _dimensionsUpdateScheduled = false;
  double _viewportWidth = 0;
  double _viewportHeight = 0;
  double _topPadding = 0;
  double _horizontalInset = 0;
  int _sessionGeneration = 0;
  int _navigationGeneration = 0;
  int _nextBoundaryLoadOwner = 0;
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
  Future<void> _awakeWrite = Future<void>.value();
  List<_ComicListEntry> _entryCache = const <_ComicListEntry>[];
  List<double> _entryStarts = const <double>[];
  final GlobalKey _readingSurfaceKey = GlobalKey(
    debugLabel: 'ComicReaderContentSurface',
  );
  final Map<String, GlobalKey> _imageKeys = <String, GlobalKey>{};
  final GlobalKey<PopupMenuButtonState<_ComicOverflowAction>>
  _comicOverflowMenuKey = GlobalKey<PopupMenuButtonState<_ComicOverflowAction>>(
    debugLabel: 'comic-reader-overflow-menu',
  );
  int _entryCacheSignature = 0;
  int _layoutDimensionsRevision = 0;
  double _layoutCorrection = 0;
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
      maxBytes: _imageMemoryPolicy.encodedCacheBytes,
      onDimensionsChanged: _scheduleDimensionsUpdate,
    );
    _bindController();
    _volumeKeySubscription = ReaderPlatform.volumeKeyEvents.listen(
      _handleVolumeKey,
    );
    _scrollController.addListener(_handleScroll);
    WidgetsBinding.instance.addObserver(this);
    _lifecycleListener = AppLifecycleListener(onStateChange: _handleLifecycle);
    unawaited(_loadPlatformCapabilities());
    unawaited(_refreshMemoryBudget());
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
      _preloader?.cancel();
      _preloader = null;
      _imageCache.dispose();
      _imageCache = ComicImageByteCache(
        bookId: widget.bookId,
        dataSource: widget.dataSource,
        maxSingleImageBytes: _maxSingleImageBytes,
        maxBytes: _imageMemoryPolicy.encodedCacheBytes,
        onDimensionsChanged: _scheduleDimensionsUpdate,
      );
      unawaited(_restart(preferenceOverride: preferenceOverride));
    } else if (oldWidget.chapterPreloadCount != widget.chapterPreloadCount) {
      _preloader?.cancel();
      _startChapterPreload();
    }
    if (oldWidget.catalogRefreshToken != widget.catalogRefreshToken &&
        oldWidget.bookId == widget.bookId &&
        identical(oldWidget.dataSource, widget.dataSource)) {
      unawaited(_refreshCatalogFromHost());
    }
  }

  @override
  void didHaveMemoryPressure() {
    _stopMemoryBudgetRefresh();
    _applyImageMemoryPolicy(ComicImageMemoryPolicy.pressure);
    _preloader?.cancel();
    _imageCache.handleMemoryPressure();
    _scheduleMemoryBudgetRefresh(force: true);
  }

  @override
  void dispose() {
    _stopMemoryBudgetRefresh();
    _preloader?.cancel();
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
    WidgetsBinding.instance.removeObserver(this);
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _imageRetryCoordinator.dispose();
    _focusNode.dispose();
    _volumeKeySubscription?.cancel();
    unawaited(_disableVolumeKeyHandling());
    _imageCache.dispose();
    _dismissSessionSheet();
    _controller.unbind(_controllerOwner);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ReaderPalette palette = ReaderPalette.fromPreset(
      ReaderThemePreset.deepNight,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _controlsVisible
          ? _comicReaderControlsSystemUiStyle
          : _comicReaderImmersiveSystemUiStyle,
      child: PopScope<void>(
        canPop: true,
        onPopInvokedWithResult: (bool didPop, void result) {
          if (didPop) unawaited(_requestExit());
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
                backgroundColor: Colors.white,
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
                        ColoredBox(
                          color: Colors.white,
                          child: _buildReadingSurface(palette),
                        ),
                        IgnorePointer(
                          child: ColoredBox(
                            color: Colors.black.withValues(
                              alpha: 1 - _preferences.brightness,
                            ),
                          ),
                        ),
                        if (_controlsVisible) _buildControlsInteractionLock(),
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
                            child: LinearProgressIndicator(
                              key: ValueKey<String>(
                                'comic-reader-chapter-loading',
                              ),
                              minHeight: 2,
                            ),
                          ),
                      ],
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
    required this.placeholderExtent,
  });
  final _LoadedComicChapter chapter;
  final ComicImageInfo image;
  final double placeholderExtent;
  @override
  double get extent => placeholderExtent;
}

class _ComicBoundaryEntry extends _ComicListEntry {
  const _ComicBoundaryEntry({
    required this.index,
    required this.loading,
    required this.failure,
    required this.atEnd,
  });
  final int index;
  final bool loading;
  final ReaderFailure? failure;
  final bool atEnd;
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
