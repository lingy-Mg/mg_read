/// 数据源内容详情页。
///
/// 职责：
/// - 加载并展示书籍详情、目录和相关推荐，将操作委托给宿主回调。
/// - 详情与目录并行加载、分别呈现，并在路由退出或重试时主动取消旧请求。
/// - 将相关推荐点击委托给宿主重新解析目标作品的书架状态与详情路由。
/// - 已在书架的发现内容提供统一确认后的移出入口，并即时切换本地按钮状态。
///
/// 注意：
/// - 不要在 build() 中执行 Runtime、网络或磁盘 IO。
/// - 异步加载必须由页面状态持有请求世代，并保留稳定 Key 与书架乐观更新语义。
/// - 入架回调同时交付已加载目录，后台预取不得重复请求同一份详情和目录。
/// - 封面作用域必须携带真实插件版本，确保发现页与书架详情命中同一持久化缓存键。
/// - 详情只复用发现页顶部栏，不显示顶级数据源选择。
/// - 横向推荐列表允许触摸、手写笔、触控板和鼠标直接拖动。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/batch_search.dart';
import 'package:mg_read/features/discovery/application/source_content_cover_handoff.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/source_content_detail_variant_picker.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/bookshelf_removal_confirmation.dart';
import 'package:mg_read/shared/presentation/widgets/app_operation_error_dialog.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

part 'source_content_detail_sections.dart';
part 'source_content_detail_catalog.dart';
part 'source_content_detail_loading.dart';
part 'source_content_detail_primitives.dart';
part 'source_content_detail_body.dart';
part 'source_content_detail_deferred.dart';

typedef SourceTextChapterRequested =
    Future<void> Function({
      required PluginContentDetail detail,
      required PluginChaptersResult firstCatalogPage,
      required PluginChapterSummary chapter,
      required List<int>? entryCoverBytes,
    });

typedef SourceComicChapterRequested =
    Future<void> Function({
      required PluginContentDetail detail,
      required PluginChaptersResult firstCatalogPage,
      required PluginChapterSummary chapter,
      required List<int>? entryCoverBytes,
    });

/// Opens a source-owned audio chapter in the independently maintained player.
typedef SourceAudioChapterRequested =
    Future<void> Function({
      required PluginContentDetail detail,
      required PluginChaptersResult firstCatalogPage,
      required PluginChapterSummary chapter,
      required String pluginVersion,
    });

/// Opens a source-owned video episode in the independently maintained player.
typedef SourceVideoEpisodeRequested =
    Future<void> Function({
      required PluginContentDetail detail,
      required PluginChaptersResult firstCatalogPage,
      required PluginChapterSummary chapter,
    });

typedef SourceExternalUrlLauncher = Future<bool> Function(Uri url);

typedef SourceShelfSaveRequested = Future<void> Function(PluginContentDetail detail, PluginChaptersResult catalog);
typedef SourceShelfRemoveRequested = Future<void> Function();

/// Actions available for a book that is already owned by the local shelf.
enum SourceShelfAction { refresh, setPrivate, cancelPrivate, toggleCoverBlur, delete }

typedef SourceShelfActionRequested = Future<void> Function(SourceShelfAction action);
typedef SourceStartReadingRequested = Future<void> Function();
typedef SourceRecommendationRequested = Future<void> Function(PluginContentSummary content);
typedef SourceSearchVariantRequested = Future<void> Function(SourceSearchHit variant);
typedef SourceDetailFailureCopy = Future<void> Function(String payload);

/// Whether this detail is being viewed from discovery or the local shelf.
enum SourceDetailShelfState { canAdd, alreadyAdded, private }

bool _usesReaderOwnedTheme(PluginContentKind contentKind) =>
    contentKind == PluginContentKind.novel || contentKind == PluginContentKind.manga;

Future<void> showSourceContentDetailSheet(
  BuildContext context, {
  required SourceContentGateway gateway,
  required String pluginId,
  required String id,
  String pluginVersion = 'unknown',
  PluginContentSummary? initialContent,
  PluginContentDetail? initialDetail,
  PluginChaptersResult? initialCatalog,
  String? initialSourceName,
  Iterable<SourceSearchHit> sourceVariants = const <SourceSearchHit>[],
  SourceSearchVariantRequested? onSourceVariantRequested,
  Iterable<PluginContentSummary> relatedContents = const <PluginContentSummary>[],
  SourceTextChapterRequested? onTextChapterRequested,
  SourceComicChapterRequested? onComicChapterRequested,
  SourceAudioChapterRequested? onAudioChapterRequested,
  SourceVideoEpisodeRequested? onVideoEpisodeRequested,
  SourceShelfSaveRequested? onAddToShelf,
  SourceShelfRemoveRequested? onRemoveFromShelf,
  SourceDetailShelfState shelfState = SourceDetailShelfState.canAdd,
  SourceExternalUrlLauncher? onExternalUrlRequested,
  SourceShelfActionRequested? onShelfAction,
  SourceStartReadingRequested? onStartReading,
  SourceRecommendationRequested? onRecommendationRequested,
  SourceDetailFailureCopy onCopyFailure = _copySourceDetailFailure,
  bool isCoverBlurred = false,
  bool useModalBottomSheet = false,
}) {
  final Widget detail = _SourceDetailScreen(
    gateway: gateway,
    pluginId: pluginId,
    pluginVersion: pluginVersion,
    id: id,
    initialContent: initialContent,
    initialDetail: initialDetail,
    initialCatalog: initialCatalog,
    initialSourceName: initialSourceName,
    sourceVariants: sourceVariants,
    onSourceVariantRequested: onSourceVariantRequested,
    relatedContents: relatedContents,
    onTextChapterRequested: onTextChapterRequested,
    onComicChapterRequested: onComicChapterRequested,
    onAudioChapterRequested: onAudioChapterRequested,
    onVideoEpisodeRequested: onVideoEpisodeRequested,
    onAddToShelf: onAddToShelf,
    onRemoveFromShelf: onRemoveFromShelf,
    shelfState: shelfState,
    onExternalUrlRequested: onExternalUrlRequested ?? _launchSystemBrowser,
    onShelfAction: onShelfAction,
    onStartReading: onStartReading,
    onRecommendationRequested: onRecommendationRequested,
    onCopyFailure: onCopyFailure,
    isCoverBlurred: isCoverBlurred,
    isModalSheet: useModalBottomSheet,
  );
  if (useModalBottomSheet) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.92,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: detail,
        ),
      ),
    );
  }
  return Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => detail));
}

Future<bool> _launchSystemBrowser(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

Future<void> _copySourceDetailFailure(String payload) => Clipboard.setData(ClipboardData(text: payload));

Future<_SourceDetailBundle> _loadDetail(
  SourceContentGateway gateway,
  String pluginId,
  String id, {
  PluginContentSummary? coverFallback,
  ValueChanged<PluginContentDetail>? onDetailLoaded,
  ValueChanged<PluginChaptersResult>? onChaptersLoaded,
}) async {
  final results = await Future.wait<Object>(<Future<Object>>[
    _loadDetailPart('source.getDetail.v1', gateway.getDetail(pluginId: pluginId, id: id)).then((detail) {
      // Runtime details cannot carry host-local cover bytes. Merge the entry
      // summary before publishing this partial result or the visible cover and
      // the later reader/player transition will both regress to a placeholder.
      final coveredDetail = preserveSourceContentCover(detail: detail, fallbackSummary: coverFallback);
      onDetailLoaded?.call(coveredDetail);
      return coveredDetail;
    }),
    _loadDetailPart('source.getChapters.v1', gateway.getChapters(pluginId: pluginId, id: id)).then((chapters) {
      onChaptersLoaded?.call(chapters);
      return chapters;
    }),
  ]);
  final detail = results[0] as PluginContentDetail;
  final chapters = results[1] as PluginChaptersResult;
  return _SourceDetailBundle(detail: detail, chapters: chapters);
}

Future<T> _loadDetailPart<T>(String capability, Future<T> request) async {
  try {
    return await request;
  } on Object catch (error, stackTrace) {
    Error.throwWithStackTrace(_SourceDetailLoadFailure(capability: capability, error: AppError.fromUnknown(error)), stackTrace);
  }
}

final class _SourceDetailLoadFailure implements Exception {
  const _SourceDetailLoadFailure({required this.capability, required this.error});

  final String capability;
  final AppError error;
}

final class _SourceDetailBundle {
  const _SourceDetailBundle({required this.detail, required this.chapters});
  final PluginContentDetail detail;
  final PluginChaptersResult chapters;
}

PluginContentDetail _previewDetail({required String pluginId, required PluginContentSummary content, required String? sourceName}) =>
    PluginContentDetail(
      pluginId: pluginId,
      sourceName: sourceName ?? '当前来源',
      summary: content,
      aliases: const <String>[],
      catalogUrl: content.url,
    );

PluginChaptersResult _emptyChapters({required String pluginId, required String? sourceName}) =>
    PluginChaptersResult(pluginId: pluginId, sourceName: sourceName ?? '当前来源', items: const <PluginChapterSummary>[]);

class _SourceDetailScreen extends StatefulWidget {
  _SourceDetailScreen({
    required this.gateway,
    required this.pluginId,
    required this.pluginVersion,
    required this.id,
    required this.initialContent,
    required this.initialDetail,
    required this.initialCatalog,
    required this.initialSourceName,
    required Iterable<SourceSearchHit> sourceVariants,
    required this.onSourceVariantRequested,
    required this.relatedContents,
    required this.onTextChapterRequested,
    required this.onComicChapterRequested,
    required this.onAudioChapterRequested,
    required this.onVideoEpisodeRequested,
    required this.onAddToShelf,
    required this.onRemoveFromShelf,
    required this.shelfState,
    required this.onExternalUrlRequested,
    required this.onShelfAction,
    required this.onStartReading,
    this.onRecommendationRequested,
    this.onCopyFailure = _copySourceDetailFailure,
    this.isCoverBlurred = false,
    required this.isModalSheet,
  }) : sourceVariants = List<SourceSearchHit>.unmodifiable(sourceVariants);
  final SourceContentGateway gateway;
  final String pluginId;
  final String pluginVersion;
  final String id;
  final PluginContentSummary? initialContent;
  final PluginContentDetail? initialDetail;
  final PluginChaptersResult? initialCatalog;
  final String? initialSourceName;
  final Iterable<PluginContentSummary> relatedContents;
  final List<SourceSearchHit> sourceVariants;
  final SourceSearchVariantRequested? onSourceVariantRequested;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceComicChapterRequested? onComicChapterRequested;
  final SourceAudioChapterRequested? onAudioChapterRequested;
  final SourceVideoEpisodeRequested? onVideoEpisodeRequested;
  final SourceShelfSaveRequested? onAddToShelf;
  final SourceShelfRemoveRequested? onRemoveFromShelf;
  final SourceDetailShelfState shelfState;
  final SourceExternalUrlLauncher onExternalUrlRequested;

  final SourceShelfActionRequested? onShelfAction;
  final SourceStartReadingRequested? onStartReading;
  final SourceRecommendationRequested? onRecommendationRequested;
  final SourceDetailFailureCopy onCopyFailure;
  final bool isCoverBlurred;
  final bool isModalSheet;

  @override
  State<_SourceDetailScreen> createState() => _SourceDetailScreenState();
}

class _SourceDetailScreenState extends State<_SourceDetailScreen> {
  late Future<_SourceDetailBundle> _detailFuture;
  PluginContentDetail? _loadedDetail;
  PluginChaptersResult? _loadedChapters;
  PluginInvocationCancellation? _cancellation;
  int _loadGeneration = 0;

  PluginContentDetail? get _coveredInitialDetail {
    final detail = widget.initialDetail;
    if (detail == null) return null;
    // Some callers own both a persisted detail and a newer visible summary.
    // Merge those two entry projections before choosing the refresh fallback.
    return preserveSourceContentCover(detail: detail, fallbackSummary: widget.initialContent);
  }

  PluginContentSummary? get _entryCoverFallback => _coveredInitialDetail?.summary ?? widget.initialContent;

  @override
  void initState() {
    super.initState();
    // Start the request after the route is mounted so FutureBuilder attaches
    // its error handler before a synchronous source failure can surface as an
    // uncaught framework error.
    _detailFuture = _startDetailLoad();
  }

  void _retryDetail() {
    final gateway = widget.gateway;
    if (gateway is SourceChapterGroupGateway) (gateway as SourceChapterGroupGateway).invalidateChapterGroups(widget.pluginId, widget.id);
    setState(() {
      _detailFuture = _startDetailLoad();
    });
  }

  Future<_SourceDetailBundle> _startDetailLoad() {
    final generation = ++_loadGeneration;
    _cancellation?.cancel();
    final cancellation = PluginInvocationCancellation();
    _cancellation = cancellation;
    return runCancellableSourceRequest(
      widget.gateway,
      cancellation,
      () => _loadDetail(
        widget.gateway,
        widget.pluginId,
        widget.id,
        coverFallback: _entryCoverFallback,
        onDetailLoaded: (detail) {
          if (!mounted || generation != _loadGeneration) return;
          setState(() => _loadedDetail = detail);
        },
        onChaptersLoaded: (chapters) {
          if (!mounted || generation != _loadGeneration) return;
          setState(() => _loadedChapters = chapters);
        },
      ),
    );
  }

  @override
  void dispose() {
    ++_loadGeneration;
    _cancellation?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final previewDetail =
        _loadedDetail ??
        _coveredInitialDetail ??
        (widget.initialContent == null
            ? null
            : _previewDetail(pluginId: widget.pluginId, content: widget.initialContent!, sourceName: widget.initialSourceName));
    final _SourceDetailBundle? previewBundle = previewDetail == null
        ? null
        : _SourceDetailBundle(
            detail: previewDetail,
            chapters:
                _loadedChapters ?? widget.initialCatalog ?? _emptyChapters(pluginId: widget.pluginId, sourceName: widget.initialSourceName),
          );
    final bool readerOwnedTheme = previewDetail != null && _usesReaderOwnedTheme(previewDetail.summary.contentKind);
    final Widget detailScreen = BookCoverSourceScope(
      pluginId: widget.pluginId,
      pluginVersion: widget.pluginVersion,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: <Widget>[
              if (widget.isModalSheet)
                const Padding(
                  padding: EdgeInsets.only(top: 10, bottom: 2),
                  child: SizedBox(
                    width: 42,
                    height: 5,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.all(Radius.circular(99))),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpacing.discoveryPagePadding,
                  AppSpacing.pageHeaderTopPaddingFor(context),
                  AppSpacing.discoveryPagePadding,
                  AppSpacing.pageHeaderTopPadding,
                ),
                child: _DetailHeader(isModalSheet: widget.isModalSheet, readerOwnedTheme: readerOwnedTheme),
              ),
              Expanded(
                child: FutureBuilder<_SourceDetailBundle>(
                  future: _detailFuture,
                  initialData: previewBundle,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      final loadingBundle = previewBundle;
                      if (loadingBundle != null) {
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: _SourceDetailView(
                            key: const ValueKey<String>('source-detail-preview'),
                            bundle: loadingBundle,
                            gateway: widget.gateway,
                            relatedContents: widget.relatedContents,
                            sourceVariants: widget.sourceVariants,
                            onSourceVariantRequested: widget.onSourceVariantRequested,
                            isRefreshing: true,
                            hasLoadFailure: false,
                            onTextChapterRequested: widget.onTextChapterRequested,
                            onComicChapterRequested: widget.onComicChapterRequested,
                            onAudioChapterRequested: widget.onAudioChapterRequested,
                            onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
                            onAddToShelf: widget.onAddToShelf,
                            onRemoveFromShelf: widget.onRemoveFromShelf,
                            shelfState: widget.shelfState,
                            onShelfAction: widget.onShelfAction == null ? null : _handleShelfAction,
                            onStartReading: widget.onStartReading,
                            isCoverBlurred: widget.isCoverBlurred,
                            onRecommendationRequested: widget.onRecommendationRequested,
                            onExternalUrlRequested: widget.onExternalUrlRequested,
                          ),
                        );
                      }
                      return _SourceDetailLoadingView(
                        initialContent: widget.initialContent,
                        shelfState: widget.shelfState,
                        onShelfAction: widget.onShelfAction == null ? null : _handleShelfAction,
                        onStartReading: widget.onStartReading,
                        isCoverBlurred: widget.isCoverBlurred,
                      );
                    }
                    if (snapshot.hasError) {
                      final failure = snapshot.error is _SourceDetailLoadFailure
                          ? snapshot.error! as _SourceDetailLoadFailure
                          : _SourceDetailLoadFailure(
                              capability: 'source.getDetail.v1 / source.getChapters.v1',
                              error: AppError.fromUnknown(snapshot.error!),
                            );
                      if (previewBundle != null) {
                        return Column(
                          key: const ValueKey<String>('source-detail-preview-error'),
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                AppSpacing.discoveryPagePadding,
                                0,
                                AppSpacing.discoveryPagePadding,
                                AppSpacing.regular,
                              ),
                              child: _DetailFailure(
                                error: failure.error,
                                capability: failure.capability,
                                hasRetainedData: true,
                                sourceName: previewBundle.detail.sourceName,
                                pluginId: widget.pluginId,
                                pluginVersion: widget.pluginVersion,
                                contentId: widget.id,
                                onCopy: widget.onCopyFailure,
                                onRetry: _retryDetail,
                              ),
                            ),
                            Expanded(
                              child: _SourceDetailView(
                                bundle: previewBundle,
                                gateway: widget.gateway,
                                relatedContents: widget.relatedContents,
                                sourceVariants: widget.sourceVariants,
                                onSourceVariantRequested: widget.onSourceVariantRequested,
                                isRefreshing: false,
                                hasLoadFailure: true,
                                onTextChapterRequested: widget.onTextChapterRequested,
                                onComicChapterRequested: widget.onComicChapterRequested,
                                onAudioChapterRequested: widget.onAudioChapterRequested,
                                onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
                                onAddToShelf: widget.onAddToShelf,
                                onRemoveFromShelf: widget.onRemoveFromShelf,
                                shelfState: widget.shelfState,
                                onShelfAction: widget.onShelfAction == null ? null : _handleShelfAction,
                                onStartReading: widget.onStartReading,
                                isCoverBlurred: widget.isCoverBlurred,
                                onRecommendationRequested: widget.onRecommendationRequested,
                                onExternalUrlRequested: widget.onExternalUrlRequested,
                              ),
                            ),
                          ],
                        );
                      }
                      return _DetailFailure(
                        error: failure.error,
                        capability: failure.capability,
                        sourceName: previewBundle?.detail.sourceName ?? widget.initialSourceName,
                        pluginId: widget.pluginId,
                        pluginVersion: widget.pluginVersion,
                        contentId: widget.id,
                        onCopy: widget.onCopyFailure,
                        onRetry: _retryDetail,
                      );
                    }
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: _SourceDetailView(
                        key: const ValueKey<String>('source-detail-loaded'),
                        bundle: snapshot.requireData,
                        gateway: widget.gateway,
                        relatedContents: widget.relatedContents,
                        sourceVariants: widget.sourceVariants,
                        onSourceVariantRequested: widget.onSourceVariantRequested,
                        isRefreshing: false,
                        hasLoadFailure: false,
                        onTextChapterRequested: widget.onTextChapterRequested,
                        onComicChapterRequested: widget.onComicChapterRequested,
                        onAudioChapterRequested: widget.onAudioChapterRequested,
                        onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
                        onAddToShelf: widget.onAddToShelf,
                        onRemoveFromShelf: widget.onRemoveFromShelf,
                        shelfState: widget.shelfState,
                        onShelfAction: widget.onShelfAction == null ? null : _handleShelfAction,
                        onStartReading: widget.onStartReading,
                        isCoverBlurred: widget.isCoverBlurred,
                        onRecommendationRequested: widget.onRecommendationRequested,
                        onExternalUrlRequested: widget.onExternalUrlRequested,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return readerOwnedTheme ? Theme(data: AppTheme.novelReader(), child: detailScreen) : detailScreen;
  }
}

class _SourceDetailView extends StatefulWidget {
  const _SourceDetailView({
    required this.bundle,
    required this.gateway,
    required this.relatedContents,
    required this.sourceVariants,
    required this.onSourceVariantRequested,
    required this.isRefreshing,
    required this.hasLoadFailure,
    required this.onTextChapterRequested,
    required this.onComicChapterRequested,
    required this.onAudioChapterRequested,
    required this.onVideoEpisodeRequested,
    required this.onAddToShelf,
    required this.onRemoveFromShelf,
    required this.shelfState,
    required this.onShelfAction,
    required this.onStartReading,
    required this.onRecommendationRequested,
    required this.onExternalUrlRequested,
    this.isCoverBlurred = false,
    super.key,
  });
  final _SourceDetailBundle bundle;
  final SourceContentGateway gateway;
  final Iterable<PluginContentSummary> relatedContents;
  final List<SourceSearchHit> sourceVariants;
  final SourceSearchVariantRequested? onSourceVariantRequested;
  final bool isRefreshing;
  final bool hasLoadFailure;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceComicChapterRequested? onComicChapterRequested;
  final SourceAudioChapterRequested? onAudioChapterRequested;
  final SourceVideoEpisodeRequested? onVideoEpisodeRequested;
  final SourceShelfSaveRequested? onAddToShelf;
  final SourceShelfRemoveRequested? onRemoveFromShelf;
  final SourceDetailShelfState shelfState;
  final SourceShelfActionRequested? onShelfAction;
  final SourceStartReadingRequested? onStartReading;
  final SourceRecommendationRequested? onRecommendationRequested;
  final bool isCoverBlurred;
  final SourceExternalUrlLauncher onExternalUrlRequested;

  @override
  State<_SourceDetailView> createState() => _SourceDetailViewState();
}

class _SourceDetailViewState extends State<_SourceDetailView> {
  late final List<PluginChapterSummary> _chapters;
  late SourceDetailShelfState _shelfState;
  var _visibleChapterCount = 20;
  bool _isSavingToShelf = false;
  bool _isRemovingFromShelf = false;

  @override
  void initState() {
    super.initState();
    _chapters = List<PluginChapterSummary>.of(widget.bundle.chapters.items);
    _shelfState = widget.shelfState;
  }

  @override
  void didUpdateWidget(covariant _SourceDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isSavingToShelf &&
        !_isRemovingFromShelf &&
        oldWidget.shelfState != widget.shelfState &&
        widget.shelfState != SourceDetailShelfState.canAdd) {
      _shelfState = widget.shelfState;
    }
  }

  Future<void> _saveToShelf(PluginContentDetail detail) async {
    final save = widget.onAddToShelf;
    if (save == null || _isSavingToShelf || _shelfState != SourceDetailShelfState.canAdd) {
      return;
    }
    setState(() => _isSavingToShelf = true);
    try {
      await save(detail, widget.bundle.chapters);
      if (!mounted) return;
      setState(() {
        _isSavingToShelf = false;
        _shelfState = SourceDetailShelfState.alreadyAdded;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已加入书架。')));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _isSavingToShelf = false);
      final message = error is BookshelfCapacityExceededException ? '书架已满，请先清理书籍。' : '暂时无法加入书架，请稍后重试。';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _removeFromShelf(PluginContentSummary content) async {
    final remove = widget.onRemoveFromShelf;
    if (remove == null || _isSavingToShelf || _isRemovingFromShelf || _shelfState == SourceDetailShelfState.canAdd) return;
    final confirmed = await showBookshelfRemovalConfirmation(context, title: content.title);
    if (!mounted || !confirmed) return;
    setState(() => _isRemovingFromShelf = true);
    try {
      await remove();
      if (!mounted) return;
      setState(() {
        _isRemovingFromShelf = false;
        _shelfState = SourceDetailShelfState.canAdd;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已从书架移出《${content.title}》')));
    } on Object {
      if (!mounted) return;
      setState(() => _isRemovingFromShelf = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('移出书架失败，请稍后重试。')));
    }
  }

  void _loadMore() {
    setState(() {
      _visibleChapterCount = math.min(_visibleChapterCount + 20, _chapters.length);
    });
  }

  @override
  Widget build(BuildContext context) => _SourceDetailBody(
    bundle: _SourceDetailBundle(
      detail: widget.bundle.detail,
      chapters: PluginChaptersResult(
        pluginId: widget.bundle.chapters.pluginId,
        sourceName: widget.bundle.chapters.sourceName,
        items: _chapters,
        groups: widget.bundle.chapters.groups,
      ),
    ),
    gateway: widget.gateway,
    relatedContents: widget.relatedContents,
    sourceVariants: widget.sourceVariants,
    onSourceVariantRequested: widget.onSourceVariantRequested,
    isRefreshing: widget.isRefreshing,
    hasLoadFailure: widget.hasLoadFailure,
    onTextChapterRequested: widget.onTextChapterRequested,
    onComicChapterRequested: widget.onComicChapterRequested,
    onAudioChapterRequested: widget.onAudioChapterRequested,
    onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
    onAddToShelf: widget.onAddToShelf,
    onRemoveFromShelf: widget.onRemoveFromShelf,
    shelfState: _shelfState,
    onShelfAction: widget.onShelfAction,
    onStartReading: widget.onStartReading,
    isCoverBlurred: widget.isCoverBlurred,
    onRecommendationRequested: widget.onRecommendationRequested,
    isSavingToShelf: _isSavingToShelf,
    isRemovingFromShelf: _isRemovingFromShelf,
    onSaveToShelf: _saveToShelf,
    onRemoveFromShelfRequested: _removeFromShelf,
    onExternalUrlRequested: widget.onExternalUrlRequested,
    visibleChapterCount: _visibleChapterCount,
    onLoadMore: _visibleChapterCount < _chapters.length ? _loadMore : null,
  );
}
