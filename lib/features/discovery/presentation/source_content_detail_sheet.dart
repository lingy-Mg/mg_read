/// 数据源内容详情页。
///
/// 职责：
/// - 加载并展示书籍详情、目录和相关推荐，将操作委托给宿主回调。
/// - 将相关推荐点击委托给宿主重新解析目标作品的书架状态与详情路由。
/// - 已在书架的发现内容提供统一确认后的移出入口，并即时切换本地按钮状态。
///
/// 注意：
/// - 不要在 build() 中执行 Runtime、网络或磁盘 IO。
/// - 异步加载必须由页面状态持有请求世代，并保留稳定 Key 与书架乐观更新语义。
/// - 封面作用域必须携带真实插件版本，确保发现页与书架详情命中同一持久化缓存键。
/// - 详情只复用发现页顶部栏，不显示顶级数据源选择。
/// - 横向推荐列表允许触摸、手写笔、触控板和鼠标直接拖动。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/content_library/content_library.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/discovery_page.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';
import 'package:mg_read/features/library/presentation/widgets/bookshelf_removal_confirmation.dart';
import 'package:mg_read/shared/presentation/widgets/async_book_cover_loader.dart';

part 'source_content_detail_sections.dart';
part 'source_content_detail_loading.dart';
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
    });

/// Opens a source-owned video episode in the independently maintained player.
typedef SourceVideoEpisodeRequested =
    Future<void> Function({
      required PluginContentDetail detail,
      required PluginChaptersResult firstCatalogPage,
      required PluginChapterSummary chapter,
    });

typedef SourceExternalUrlLauncher = Future<bool> Function(Uri url);

typedef SourceShelfSaveRequested = Future<void> Function(PluginContentDetail detail);
typedef SourceShelfRemoveRequested = Future<void> Function();

/// Actions available for a book that is already owned by the local shelf.
enum SourceShelfAction { refresh, setPrivate, cancelPrivate, delete }

typedef SourceShelfActionRequested = Future<void> Function(SourceShelfAction action);
typedef SourceStartReadingRequested = Future<void> Function();
typedef SourceRecommendationRequested = Future<void> Function(PluginContentSummary content);

/// Whether this detail is being viewed from discovery or the local shelf.
enum SourceDetailShelfState { canAdd, alreadyAdded, private }

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

Future<_SourceDetailBundle> _loadDetail(SourceContentGateway gateway, String pluginId, String id) async {
  final results = await Future.wait<Object>(<Future<Object>>[
    gateway.getDetail(pluginId: pluginId, id: id),
    gateway.getChapters(pluginId: pluginId, id: id),
  ]);
  final detail = results[0] as PluginContentDetail;
  final chapters = results[1] as PluginChaptersResult;
  return _SourceDetailBundle(detail: detail, chapters: chapters);
}

final class _SourceDetailBundle {
  const _SourceDetailBundle({required this.detail, required this.chapters});
  final PluginContentDetail detail;
  final PluginChaptersResult chapters;
}

class _AdaptiveSingleLineText extends StatelessWidget {
  const _AdaptiveSingleLineText({
    required this.text,
    required this.style,
    required this.minFontSize,
    this.textAlign,
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
  });

  final String text;
  final TextStyle style;
  final double minFontSize;
  final TextAlign? textAlign;
  final int maxLines;
  final TextOverflow overflow;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final baseFontSize = style.fontSize ?? 16;
        final minScale = minFontSize / baseFontSize;
        if (constraints.maxWidth <= 0) {
          return Text(
            text,
            style: style.copyWith(fontSize: baseFontSize * minScale),
            maxLines: maxLines,
            overflow: overflow,
            softWrap: false,
            textAlign: textAlign,
          );
        }

        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: double.infinity);

        final neededScale = painter.width <= 0 ? 1 : constraints.maxWidth / painter.width;
        final effectiveScale = neededScale.clamp(minScale, 1.0);
        return Text(
          text,
          textAlign: textAlign,
          maxLines: maxLines,
          overflow: overflow,
          softWrap: false,
          style: style.copyWith(fontSize: baseFontSize * effectiveScale),
        );
      },
    );
  }
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
  const _SourceDetailScreen({
    required this.gateway,
    required this.pluginId,
    required this.pluginVersion,
    required this.id,
    required this.initialContent,
    required this.initialDetail,
    required this.initialCatalog,
    required this.initialSourceName,
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
    required this.isModalSheet,
  });
  final SourceContentGateway gateway;
  final String pluginId;
  final String pluginVersion;
  final String id;
  final PluginContentSummary? initialContent;
  final PluginContentDetail? initialDetail;
  final PluginChaptersResult? initialCatalog;
  final String? initialSourceName;
  final Iterable<PluginContentSummary> relatedContents;
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
  final bool isModalSheet;

  @override
  State<_SourceDetailScreen> createState() => _SourceDetailScreenState();
}

class _SourceDetailScreenState extends State<_SourceDetailScreen> {
  late final Future<_SourceDetailBundle> _detailFuture;

  @override
  void initState() {
    super.initState();
    // Start the request after the route is mounted so FutureBuilder attaches
    // its error handler before a synchronous source failure can surface as an
    // uncaught framework error.
    _detailFuture = _loadDetail(widget.gateway, widget.pluginId, widget.id);
  }

  @override
  Widget build(BuildContext context) {
    final previewDetail =
        widget.initialDetail ??
        (widget.initialContent == null
            ? null
            : _previewDetail(pluginId: widget.pluginId, content: widget.initialContent!, sourceName: widget.initialSourceName));
    final _SourceDetailBundle? previewBundle = previewDetail == null
        ? null
        : _SourceDetailBundle(
            detail: previewDetail,
            chapters: widget.initialCatalog ?? _emptyChapters(pluginId: widget.pluginId, sourceName: widget.initialSourceName),
          );
    return BookCoverSourceScope(
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
                child: _DetailHeader(isModalSheet: widget.isModalSheet),
              ),
              Expanded(
                child: FutureBuilder<_SourceDetailBundle>(
                  future: _detailFuture,
                  initialData: previewBundle,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      if (snapshot.hasData) {
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          child: _SourceDetailView(
                            key: const ValueKey<String>('source-detail-preview'),
                            bundle: snapshot.requireData,
                            gateway: widget.gateway,
                            relatedContents: widget.relatedContents,
                            isRefreshing: true,
                            onTextChapterRequested: widget.onTextChapterRequested,
                            onComicChapterRequested: widget.onComicChapterRequested,
                            onAudioChapterRequested: widget.onAudioChapterRequested,
                            onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
                            onAddToShelf: widget.onAddToShelf,
                            onRemoveFromShelf: widget.onRemoveFromShelf,
                            shelfState: widget.shelfState,
                            onShelfAction: widget.onShelfAction,
                            onStartReading: widget.onStartReading,
                            onRecommendationRequested: widget.onRecommendationRequested,
                            onExternalUrlRequested: widget.onExternalUrlRequested,
                          ),
                        );
                      }
                      return _SourceDetailLoadingView(
                        initialContent: widget.initialContent,
                        shelfState: widget.shelfState,
                        onShelfAction: widget.onShelfAction,
                        onStartReading: widget.onStartReading,
                      );
                    }
                    if (snapshot.hasError) {
                      if (previewBundle != null) {
                        return _SourceDetailView(
                          key: const ValueKey<String>('source-detail-preview-error'),
                          bundle: previewBundle,
                          gateway: widget.gateway,
                          relatedContents: widget.relatedContents,
                          isRefreshing: false,
                          onTextChapterRequested: widget.onTextChapterRequested,
                          onComicChapterRequested: widget.onComicChapterRequested,
                          onAudioChapterRequested: widget.onAudioChapterRequested,
                          onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
                          onAddToShelf: widget.onAddToShelf,
                          onRemoveFromShelf: widget.onRemoveFromShelf,
                          shelfState: widget.shelfState,
                          onShelfAction: widget.onShelfAction,
                          onStartReading: widget.onStartReading,
                          onRecommendationRequested: widget.onRecommendationRequested,
                          onExternalUrlRequested: widget.onExternalUrlRequested,
                        );
                      }
                      return _DetailFailure(error: AppError.fromUnknown(snapshot.error!));
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
                        isRefreshing: false,
                        onTextChapterRequested: widget.onTextChapterRequested,
                        onComicChapterRequested: widget.onComicChapterRequested,
                        onAudioChapterRequested: widget.onAudioChapterRequested,
                        onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
                        onAddToShelf: widget.onAddToShelf,
                        onRemoveFromShelf: widget.onRemoveFromShelf,
                        shelfState: widget.shelfState,
                        onShelfAction: widget.onShelfAction,
                        onStartReading: widget.onStartReading,
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
  }
}

class _SourceDetailView extends StatefulWidget {
  const _SourceDetailView({
    required this.bundle,
    required this.gateway,
    required this.relatedContents,
    required this.isRefreshing,
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
    super.key,
  });
  final _SourceDetailBundle bundle;
  final SourceContentGateway gateway;
  final Iterable<PluginContentSummary> relatedContents;
  final bool isRefreshing;
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
      await save(detail);
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
      ),
    ),
    gateway: widget.gateway,
    relatedContents: widget.relatedContents,
    isRefreshing: widget.isRefreshing,
    onTextChapterRequested: widget.onTextChapterRequested,
    onComicChapterRequested: widget.onComicChapterRequested,
    onAudioChapterRequested: widget.onAudioChapterRequested,
    onVideoEpisodeRequested: widget.onVideoEpisodeRequested,
    onAddToShelf: widget.onAddToShelf,
    onRemoveFromShelf: widget.onRemoveFromShelf,
    shelfState: _shelfState,
    onShelfAction: widget.onShelfAction,
    onStartReading: widget.onStartReading,
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

class _SourceDetailBody extends StatelessWidget {
  const _SourceDetailBody({
    required this.bundle,
    required this.gateway,
    required this.relatedContents,
    required this.isRefreshing,
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
    required this.isSavingToShelf,
    required this.isRemovingFromShelf,
    required this.onSaveToShelf,
    required this.onRemoveFromShelfRequested,
    required this.onExternalUrlRequested,
    required this.visibleChapterCount,
    required this.onLoadMore,
  });

  final _SourceDetailBundle bundle;
  final SourceContentGateway gateway;
  final Iterable<PluginContentSummary> relatedContents;
  final bool isRefreshing;
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
  final bool isSavingToShelf;
  final bool isRemovingFromShelf;
  final ValueChanged<PluginContentDetail> onSaveToShelf;
  final ValueChanged<PluginContentSummary> onRemoveFromShelfRequested;
  final SourceExternalUrlLauncher onExternalUrlRequested;
  final int visibleChapterCount;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final detail = bundle.detail;
    final content = detail.summary;
    final tokens = AppThemeTokens.of(context);
    final theme = Theme.of(context);
    final firstChapter = bundle.chapters.items.isEmpty ? null : bundle.chapters.items.first;
    final labels = <String>{...content.categories, ...content.tags}.take(3).toList(growable: false);
    final attributes = _displayAttributes(content.attributes).toList(growable: false);
    final chapterTotal = _chapterTotal(detailTotal: content.chapterCount, loadedCount: bundle.chapters.items.length);
    final recommendationCandidates = _recommendationCandidates(relatedContents, excludedId: content.id);
    return ListView(
      key: const Key('source-content-detail-sheet'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.discoveryPagePadding,
        AppSpacing.regular,
        AppSpacing.discoveryPagePadding,
        AppSpacing.page,
      ),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InkWell(
              key: const Key('source-detail-open-cover-url'),
              onTap: content.coverUrl == null ? null : () => unawaited(_openUrl(context, content.coverUrl)),
              borderRadius: AppRadii.discoveryCover,
              child: DiscoveryBookCover(
                key: const Key('source-detail-cover'),
                title: content.title,
                coverBytes: content.coverBytes,
                remoteContentId: content.id,
                coverUrl: content.coverUrl,
                variant: _coverVariant(content.id),
                width: 112,
                presentation: content.contentKind == PluginContentKind.video
                    ? DiscoveryCoverPresentation.landscape
                    : DiscoveryCoverPresentation.portrait,
                height: content.contentKind == PluginContentKind.video ? 74 : 174,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: double.infinity,
                    child: _AdaptiveSingleLineText(
                      text: content.title,
                      style:
                          theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.15) ??
                          const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.15),
                      minFontSize: 18,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.left,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Text('作者:', style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText)),
                      const SizedBox(width: AppSpacing.unit),
                      Expanded(
                        child: Text(
                          content.author ?? '作者未知',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText),
                        ),
                      ),
                    ],
                  ),
                  if (labels.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 14),
                    Wrap(spacing: 6, runSpacing: 4, children: labels.map((value) => _DetailTag(label: value)).toList(growable: false)),
                  ],
                  const SizedBox(height: 14),
                  Divider(color: tokens.divider, height: 1),
                  _DetailStats(content: content),
                  Divider(color: tokens.divider, height: 1),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.section),
        if (shelfState != SourceDetailShelfState.canAdd &&
            onShelfAction != null &&
            onStartReading != null &&
            (content.contentKind == PluginContentKind.novel || content.contentKind == PluginContentKind.manga))
          _ShelfActionBar(title: content.title, shelfState: shelfState, onAction: onShelfAction!, onStartReading: onStartReading!)
        else
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('source-detail-add-shelf'),
                  onPressed: shelfState != SourceDetailShelfState.canAdd
                      ? onRemoveFromShelf == null
                            ? () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('移出书架功能暂不可用。')))
                            : isRemovingFromShelf
                            ? null
                            : () => onRemoveFromShelfRequested(content)
                      : onAddToShelf == null
                      ? () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('书架保存功能尚未接入此数据源。')))
                      : isSavingToShelf
                      ? null
                      : () => onSaveToShelf(detail),
                  icon: Icon(
                    shelfState != SourceDetailShelfState.canAdd
                        ? isRemovingFromShelf
                              ? Icons.hourglass_top_rounded
                              : Icons.bookmark_remove_outlined
                        : isSavingToShelf
                        ? Icons.hourglass_top_rounded
                        : Icons.library_add_outlined,
                  ),
                  label: Text(
                    shelfState != SourceDetailShelfState.canAdd
                        ? isRemovingFromShelf
                              ? '正在移出…'
                              : '已在书架 · 移出'
                        : isSavingToShelf
                        ? '正在加入…'
                        : '加入书架',
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    foregroundColor: tokens.accent,
                    side: BorderSide(color: tokens.accent),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: FilledButton(
                  key: const Key('source-detail-start-reading'),
                  onPressed: isRefreshing || firstChapter == null
                      ? null
                      : () => unawaited(
                          _openTextChapter(
                            context,
                            gateway: gateway,
                            detail: detail,
                            firstCatalogPage: bundle.chapters,
                            chapter: firstChapter,
                            onTextChapterRequested: onTextChapterRequested,
                            onComicChapterRequested: onComicChapterRequested,
                            onAudioChapterRequested: onAudioChapterRequested,
                            onVideoEpisodeRequested: onVideoEpisodeRequested,
                          ),
                        ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    backgroundColor: tokens.accent,
                    disabledBackgroundColor: tokens.accent,
                    disabledForegroundColor: tokens.surface,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  child: isRefreshing
                      ? const _DetailLoadingButtonLabel()
                      : Text(switch (content.contentKind) {
                          PluginContentKind.audio || PluginContentKind.video => '开始播放',
                          _ => '开始阅读',
                        }),
                ),
              ),
            ],
          ),
        const SizedBox(height: AppSpacing.section),
        Divider(color: tokens.divider, height: 1),
        const SizedBox(height: AppSpacing.comfortable),
        Text('简介', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.compact),
        if (isRefreshing && content.description == null)
          const _DetailShimmerBlock(height: 68)
        else
          Text(
            content.description ?? '暂无作品简介',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText, height: 1.65),
          ),
        if (attributes.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Wrap(spacing: 10, runSpacing: 6, children: attributes.map((value) => _DetailTag(label: value.value)).toList(growable: false)),
        ],
        const SizedBox(height: AppSpacing.section),
        Divider(color: tokens.divider, height: 1),
        if (content.latestChapter != null)
          _ExternalRow(
            key: const Key('source-detail-latest-chapter-url'),
            title: '最新章节',
            label: content.latestChapter!.title,
            subtitle:
                _attributeValue(content.attributes, 'discoveryUpdatedLabel') ??
                (content.latestChapter!.updatedAt == null ? null : _formatDateTime(content.latestChapter!.updatedAt!)),
            url: content.latestChapter!.url,
            onOpenUrl: _openUrl,
          ),
        _ExternalRow(
          key: const Key('source-detail-catalog-url'),
          title: '阅读来源',
          label: '当前来源：${detail.sourceName}',
          url: detail.catalogUrl ?? content.url,
          onOpenUrl: _openUrl,
        ),
        if (recommendationCandidates.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.section),
          Divider(color: tokens.divider, height: 1),
          const SizedBox(height: AppSpacing.comfortable),
          _RecommendationsSection(candidates: recommendationCandidates, onRecommendationRequested: onRecommendationRequested),
          const SizedBox(height: AppSpacing.regular),
          Material(
            color: tokens.accentSoft.withValues(alpha: .52),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {},
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Row(
                  children: <Widget>[
                    Expanded(child: Text('查看书友评论', style: theme.textTheme.bodyLarge)),
                    Text('4.2万条评论', style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded, color: tokens.mutedText),
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.section),
        Divider(color: tokens.divider, height: 1),
        const SizedBox(height: AppSpacing.comfortable),
        Text('目录', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        if (isRefreshing && bundle.chapters.items.isEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          const _DetailShimmerBlock(height: 12, widthFactor: .22),
          const SizedBox(height: AppSpacing.comfortable),
          const _DetailLoadingChapterRows(),
        ] else
          Text(chapterTotal == null ? '暂无章节' : '共 $chapterTotal 章', style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
        for (final chapter in bundle.chapters.items.take(visibleChapterCount))
          _ChapterRow(
            chapter: chapter,
            onRead: () => unawaited(
              _openTextChapter(
                context,
                gateway: gateway,
                detail: detail,
                firstCatalogPage: bundle.chapters,
                chapter: chapter,
                onTextChapterRequested: onTextChapterRequested,
                onComicChapterRequested: onComicChapterRequested,
                onAudioChapterRequested: onAudioChapterRequested,
                onVideoEpisodeRequested: onVideoEpisodeRequested,
              ),
            ),
            onOpenUrl: _openUrl,
          ),
        if (onLoadMore != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.regular),
            child: OutlinedButton(key: const Key('source-detail-load-more-chapters'), onPressed: onLoadMore, child: const Text('加载更多章节')),
          ),
      ],
    );
  }

  Future<void> _openUrl(BuildContext context, Uri? url) async {
    if (url == null || (url.scheme != 'http' && url.scheme != 'https')) return;
    final launched = await onExternalUrlRequested(url);
    if (!context.mounted || launched) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('无法调用系统浏览器打开该链接。')));
  }
}
