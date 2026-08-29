/// 文本阅读器主视图。
///
/// 职责：
/// - 组合正文排版、章节分页、阅读工具栏与设置入口。
/// - 将章节缓存参数交给宿主能力，并保持网络、持久化和全局任务状态在宿主侧。
/// - 横向翻页时将背景与正文组合成同一页片参与动画。
/// - 将已预排的下一章第一页作为连续页片，动画停止后再提交跨章状态。
/// - 跨章回退时屏蔽 PageView 重建产生的过期页回调，保持上一章真实尾页。
/// - 处理触摸、鼠标、滚轮和键盘的阅读交互。
/// - 目录打开后分批补齐全部章节，并将当前章节定位到可视区域中部。
/// - 将章节状态查询合并进阅读器会话缓存，目录重开只补查尚未覆盖的章节。
/// - 显式跳章操作收起阅读 chrome，未就绪的章节统一在正文层显示加载态。
/// - 隔离工具栏和目录动作 Tooltip 的 OverlayPortal 语义，保持 Windows AXTree 稳定。
///
/// 注意：
/// - 阅读器不拥有网络、数据库或宿主路由；数据和退出请求通过公开契约交互。
/// - 设置弹层打开时，根层输入锁会拦截底层阅读手势；点击正文区域只关闭设置。
///
/// TODO:
/// - 无。
library;

import 'dart:async';
import 'dart:collection';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/contracts.dart';
import '../api/controller.dart';
import '../api/models.dart';
import '../core/auto_reading_coordinator.dart';
import '../core/chapter_access_coordinator.dart';
import '../pagination/text_paginator.dart';
import '../pagination/layout_cache.dart';
import '../platform/reader_platform.dart';
import '../platform/screen_awake_coordinator.dart';
import 'comments/reader_comment_strings.dart';
import 'comments/reader_comment_widgets.dart';
import 'chapter/reader_chapter_state_badge.dart';
import 'effects/reader_page_effect.dart';
import 'fonts/reader_font_controller.dart';
import 'reader_accessible_tooltip.dart';
import 'reader_strings.dart';
import 'reader_theme.dart';
import 'settings/reader_settings_sheet.dart';
import 'settings/reader_settings_tokens.dart';

part 'text_reader_session.dart';
part 'text_reader_pagination.dart';
part 'text_reader_progress_navigation.dart';
part 'text_reader_adjacent_pagination.dart';
part 'text_reader_chapter_prefetch.dart';
part 'text_reader_comments.dart';
part 'text_reader_persistence.dart';
part 'text_reader_content_widgets.dart';
part 'text_reader_vertical_content_widgets.dart';
part 'text_reader_chrome_widgets.dart';
part 'text_reader_cache_dialog.dart';
part 'text_reader_library_sheet.dart';
part 'text_reader_status_widgets.dart';

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

class _TextReaderViewState extends State<TextReaderView>
    with WidgetsBindingObserver {
  static const Duration _saveDelay = Duration(milliseconds: 800);
  static const int _chapterCacheLimit = 2;
  static const int _commentSummaryBatchSize = 100;
  static const int _chapterStateBatchSize = 100;
  static const int _catalogCompletionPageSize = 500;
  static const int _paragraphKeyCacheLimit = 256;
  static const int _verticalRestoreMeasureBatchSize = 128;
  static const int _progressiveParagraphBatchSize = 8;
  static const double _pageFooterBottomInset = 10;
  // TextPainter measures fractional line heights, while RenderParagraph rounds
  // their painted extent to device pixels. Keep a small reserve so a page that
  // exactly fits during pagination cannot overflow by a rounding pixel.
  static const double _horizontalPageLayoutSafety = 2;
  static const double _mouseTapSlop = 18;
  // PointerEvent.buttons uses a bit mask; 1 denotes the primary mouse button.
  static const int _primaryMouseButton = 1;
  static const double _inlineCommentHitSize = 48;
  static const double _inlineCommentVisualSize = 30;
  static final Expando<int> _contentLayoutIdentities = Expando<int>(
    'reader-content-layout-identity',
  );
  static int _nextContentLayoutIdentity = 1;

  final TextPaginator _paginator = const TextPaginator();
  static final ReaderLayoutLru _layoutCache = ReaderLayoutLru();
  final Object _awakeHolder = Object();
  final Object _controllerBindingOwner = Object();
  final FocusNode _focusNode = FocusNode(debugLabel: 'TextReader');
  final ScrollController _verticalController = ScrollController();
  final ScrollController _catalogScrollController = ScrollController(
    keepScrollOffset: false,
  );
  final ValueNotifier<int> _catalogRevision = ValueNotifier<int>(0);
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
  PageController _pageController = PageController(initialPage: 1);
  final Set<PageController> _retiredPageControllers = <PageController>{};
  final GlobalKey<PopupMenuButtonState<_ReaderOverflowAction>>
  _readerOverflowMenuKey =
      GlobalKey<PopupMenuButtonState<_ReaderOverflowAction>>(
        debugLabel: 'reader-overflow-menu',
      );
  Timer? _saveTimer;
  Timer? _noticeTimer;
  Timer? _clockTimer;
  Timer? _wheelResetTimer;
  Future<void>? _catalogCompletion;

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
  String? _centeredCatalogChapterId;
  int _catalogCenterRetryCount = 0;
  bool _pageTurnAnimating = false;
  TextChapterContent? _content;
  ReaderChapterInfo? _currentChapterInfo;
  List<ReaderPage> _pages = const <ReaderPage>[];
  List<ReaderBookmark> _bookmarks = const <ReaderBookmark>[];
  TextReaderPreferences _preferences = TextReaderPreferences.defaults;
  ReaderProgress? _progress;
  ReaderFailure? _failure;
  ReaderLayoutFingerprint? _layoutFingerprint;
  int _chapterIndex = -1;
  int _pageIndex = 0;
  int _requestGeneration = 0;
  int _sessionGeneration = 0;
  int _commentGeneration = 0;
  int _navigationGeneration = 0;
  int _verticalRestoreGeneration = 0;
  bool _loading = true;
  bool _controlsVisible = false;
  bool _readerSettingsVisible = false;
  bool _readerOverflowMenuExpanded = false;
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
  bool _chapterLoadingOverlayVisible = false;
  bool _awaitingPreviousChapterTail = false;
  bool _disposed = false;
  bool _autoScrolling = false;
  bool _restoringVerticalAnchor = false;
  bool _restoringHorizontalAnchor = false;
  int? _restoringHorizontalRawIndex;
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
  int _paginationGeneration = 0;
  int _contentEpoch = 0;
  bool _currentPaginationComplete = false;
  int _adjacentPreparationGeneration = 0;
  int _adjacentLayoutGeneration = 0;
  int _adjacentOperationId = 0;
  int _chapterTransitionOperationId = 0;
  bool _adjacentPreparationActive = false;
  int _adjacentActiveOperation = 0;
  Stopwatch? _adjacentPreparationStopwatch;
  _AdjacentPreparationTarget? _adjacentPreparationTarget;
  _AdjacentPreparationTarget? _adjacentSuppressedTarget;
  _AdjacentPreparationStage _adjacentPreparationStage =
      _AdjacentPreparationStage.pending;
  int? _pendingChapterTransitionOperation;
  Stopwatch? _chapterTransitionStopwatch;
  int _progressiveParagraphCursor = 0;
  List<ReaderPage> _progressivePages = const <ReaderPage>[];
  ReaderPageContinuation? _progressiveContinuation;
  bool _firstContentNotificationScheduled = false;
  bool _firstContentNotificationSent = false;
  Duration _firstContentLayoutDuration = Duration.zero;
  ReaderPaginationPreparation _firstContentPreparation =
      ReaderPaginationPreparation.firstPage;

  ReaderObserver get _observer => widget.observer ?? const ReaderObserver();
  ReaderPalette get _palette => ReaderPalette.fromPreset(_preferences.theme);
  ReaderChapterInfo? get _currentChapter => _currentChapterInfo;
  bool get _isBookPreview =>
      !_loading && _failure == null && _progress?.isBookPreview == true;
  ReaderProgress _defaultChapterProgress() {
    final ReaderChapterInfo? firstChapter =
        _catalogByIndex[0] ?? (_catalog.isEmpty ? null : _catalog.first);
    if (firstChapter == null) return const ReaderProgress.bookPreview();
    return ReaderProgress(
      chapterId: firstChapter.id,
      paragraphId: '',
      chapterIndex: firstChapter.index,
    );
  }

  TextScaler get _textScaler => MediaQuery.textScalerOf(
    context,
  ).clamp(minScaleFactor: .85, maxScaleFactor: 1.3);
  String _indented(String text) => '${'　' * _preferences.firstLineIndent}$text';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  Future<void> _refreshLoadedChapterStates({
    String? chapterId,
    bool force = false,
  }) async {
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
      await coordinator.refresh(ids.sublist(start, end), force: force);
    }
  }

  Future<void> _recordChapterOpened(String chapterId) async {
    final ReaderChapterAccessCoordinator? coordinator =
        _chapterAccessCoordinator;
    if (coordinator == null) return;
    await _refreshLoadedChapterStates(chapterId: chapterId, force: true);
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
      unawaited(_loadPersistedCustomFont());
    }
    if (oldWidget.extensions.commentFeed != widget.extensions.commentFeed) {
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
    _cancelAdjacentPreparation();
    if (_preferences.navigationMode == ReaderNavigationMode.verticalScroll) {
      _scheduleVerticalRestore(paragraphId: _progress?.paragraphId);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _completeChapterTransition(ReaderChapterPerformanceOutcome.cancelled);
    _cancelAdjacentPreparation();
    WidgetsBinding.instance.removeObserver(this);
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
    _catalogScrollController.dispose();
    _catalogRevision.dispose();
    for (final PageController controller in _retiredPageControllers) {
      controller.dispose();
    }
    _retiredPageControllers.clear();
    _pageController.dispose();
    _focusNode.dispose();
    _controller.unbind(_controllerBindingOwner);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    _cancelAdjacentPreparation();
    _layoutCache.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _layoutCache.clear();
      _cancelAdjacentPreparation();
    }
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
          canPop: true,
          onPopInvokedWithResult: (bool didPop, void result) {
            if (didPop) unawaited(_requestExit());
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
                          if (_controlsVisible && !_readerSettingsVisible)
                            _buildControlsInteractionLock(),
                          if (_content != null) _buildChrome(),
                          if (_readerSettingsVisible)
                            _buildSettingsInteractionLock(),
                          if (_awaitingPreviousChapterTail)
                            _PreviousChapterTailMask(palette: palette),
                          if (_chapterLoadingOverlayVisible)
                            _ChapterLoadingMask(palette: palette),
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

  void _showSettingsSheet() {
    if (_readerSettingsVisible) return;
    _stopAutoReading();
    _setReaderSettingsVisible(true);
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
          _setReaderSettingsVisible(false);
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
    unawaited(_updatePreferences(_preferences.co