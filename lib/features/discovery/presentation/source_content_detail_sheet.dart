import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mgread_plugin_runtime/mgread_plugin_runtime.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/core/errors/app_error.dart';
import 'package:mg_read/features/discovery/application/source_content_gateway.dart';
import 'package:mg_read/features/discovery/presentation/discovery_view_data.dart';
import 'package:mg_read/features/discovery/presentation/widgets/discovery_book_cover.dart';

typedef SourceTextChapterRequested =
    Future<void> Function({
      required PluginContentDetail detail,
      required PluginChaptersResult firstCatalogPage,
      required PluginChapterSummary chapter,
    });

typedef SourceExternalUrlLauncher = Future<bool> Function(Uri url);

typedef SourceShelfSaveRequested =
    Future<void> Function(PluginContentSummary content);

/// Whether this detail is being viewed from discovery or the local shelf.
enum SourceDetailShelfState { canAdd, alreadyAdded }

Future<void> showSourceContentDetailSheet(
  BuildContext context, {
  required SourceContentGateway gateway,
  required String pluginId,
  required String id,
  PluginContentSummary? initialContent,
  PluginChaptersResult? initialCatalog,
  String? initialSourceName,
  Iterable<PluginContentSummary> relatedContents =
      const <PluginContentSummary>[],
  SourceTextChapterRequested? onTextChapterRequested,
  SourceShelfSaveRequested? onAddToShelf,
  SourceDetailShelfState shelfState = SourceDetailShelfState.canAdd,
  SourceExternalUrlLauncher? onExternalUrlRequested,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => _SourceDetailScreen(
        gateway: gateway,
        pluginId: pluginId,
        id: id,
        initialContent: initialContent,
        initialCatalog: initialCatalog,
        initialSourceName: initialSourceName,
        relatedContents: relatedContents,
        onTextChapterRequested: onTextChapterRequested,
        onAddToShelf: onAddToShelf,
        shelfState: shelfState,
        onExternalUrlRequested: onExternalUrlRequested ?? _launchSystemBrowser,
      ),
    ),
  );
}

Future<bool> _launchSystemBrowser(Uri url) =>
    launchUrl(url, mode: LaunchMode.externalApplication);

Future<_SourceDetailBundle> _loadDetail(
  SourceContentGateway gateway,
  String pluginId,
  String id,
) async {
  final detail = await gateway.getDetail(pluginId: pluginId, id: id);
  final chapters = await gateway.getChapters(
    pluginId: pluginId,
    id: id,
    pageSize: 20,
  );
  return _SourceDetailBundle(detail: detail, chapters: chapters);
}

final class _SourceDetailBundle {
  const _SourceDetailBundle({required this.detail, required this.chapters});
  final PluginContentDetail detail;
  final PluginChaptersResult chapters;
}

PluginContentDetail _previewDetail({
  required String pluginId,
  required PluginContentSummary content,
  required String? sourceName,
}) => PluginContentDetail(
  pluginId: pluginId,
  sourceName: sourceName ?? '当前来源',
  summary: content,
  aliases: const <String>[],
  catalogUrl: content.url,
);

PluginChaptersResult _emptyChapters({
  required String pluginId,
  required String? sourceName,
}) => PluginChaptersResult(
  pluginId: pluginId,
  sourceName: sourceName ?? '当前来源',
  items: const <PluginChapterSummary>[],
  nextCursor: null,
  totalCount: null,
);

class _SourceDetailScreen extends StatefulWidget {
  const _SourceDetailScreen({
    required this.gateway,
    required this.pluginId,
    required this.id,
    required this.initialContent,
    required this.initialCatalog,
    required this.initialSourceName,
    required this.relatedContents,
    required this.onTextChapterRequested,
    required this.onAddToShelf,
    required this.shelfState,
    required this.onExternalUrlRequested,
  });
  final SourceContentGateway gateway;
  final String pluginId;
  final String id;
  final PluginContentSummary? initialContent;
  final PluginChaptersResult? initialCatalog;
  final String? initialSourceName;
  final Iterable<PluginContentSummary> relatedContents;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceShelfSaveRequested? onAddToShelf;
  final SourceDetailShelfState shelfState;
  final SourceExternalUrlLauncher onExternalUrlRequested;

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
    final _SourceDetailBundle? previewBundle = widget.initialContent == null
        ? null
        : _SourceDetailBundle(
            detail: _previewDetail(
              pluginId: widget.pluginId,
              content: widget.initialContent!,
              sourceName: widget.initialSourceName,
            ),
            chapters:
                widget.initialCatalog ??
                _emptyChapters(
                  pluginId: widget.pluginId,
                  sourceName: widget.initialSourceName,
                ),
          );
    return Scaffold(
      body: SafeArea(
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
                    onAddToShelf: widget.onAddToShelf,
                    shelfState: widget.shelfState,
                    onExternalUrlRequested: widget.onExternalUrlRequested,
                  ),
                );
              }
              return Center(
                child: Semantics(
                  label: '正在加载内容详情与目录',
                  child: CircularProgressIndicator(),
                ),
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
                  onAddToShelf: widget.onAddToShelf,
                  shelfState: widget.shelfState,
                  onExternalUrlRequested: widget.onExternalUrlRequested,
                );
              }
              return _DetailFailure(
                error: AppError.fromUnknown(snapshot.error!),
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
                isRefreshing: false,
                onTextChapterRequested: widget.onTextChapterRequested,
                onAddToShelf: widget.onAddToShelf,
                shelfState: widget.shelfState,
                onExternalUrlRequested: widget.onExternalUrlRequested,
              ),
            );
          },
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
    required this.onAddToShelf,
    required this.shelfState,
    required this.onExternalUrlRequested,
    super.key,
  });
  final _SourceDetailBundle bundle;
  final SourceContentGateway gateway;
  final Iterable<PluginContentSummary> relatedContents;
  final bool isRefreshing;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceShelfSaveRequested? onAddToShelf;
  final SourceDetailShelfState shelfState;
  final SourceExternalUrlLauncher onExternalUrlRequested;

  @override
  State<_SourceDetailView> createState() => _SourceDetailViewState();
}

class _SourceDetailViewState extends State<_SourceDetailView> {
  late final List<PluginChapterSummary> _chapters;
  late String? _nextCursor;
  late int? _totalCount;
  late SourceDetailShelfState _shelfState;
  bool _isLoadingMore = false;
  bool _isSavingToShelf = false;

  @override
  void initState() {
    super.initState();
    _chapters = List<PluginChapterSummary>.of(widget.bundle.chapters.items);
    _nextCursor = widget.bundle.chapters.nextCursor;
    _totalCount = widget.bundle.chapters.totalCount;
    _shelfState = widget.shelfState;
  }

  @override
  void didUpdateWidget(covariant _SourceDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isSavingToShelf &&
        oldWidget.shelfState != widget.shelfState &&
        widget.shelfState == SourceDetailShelfState.alreadyAdded) {
      _shelfState = widget.shelfState;
    }
  }

  Future<void> _saveToShelf(PluginContentSummary content) async {
    final save = widget.onAddToShelf;
    if (save == null ||
        _isSavingToShelf ||
        _shelfState == SourceDetailShelfState.alreadyAdded) {
      return;
    }
    setState(() => _isSavingToShelf = true);
    try {
      await save(content);
      if (!mounted) return;
      setState(() {
        _isSavingToShelf = false;
        _shelfState = SourceDetailShelfState.alreadyAdded;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已加入书架。')));
    } on Object {
      if (!mounted) return;
      setState(() => _isSavingToShelf = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂时无法加入书架，请稍后重试。')));
    }
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final next = await widget.gateway.getChapters(
        pluginId: widget.bundle.detail.pluginId,
        id: widget.bundle.detail.summary.id,
        cursor: cursor,
        pageSize: 20,
      );
      if (!mounted) return;
      final seen = _chapters.map((chapter) => chapter.id).toSet();
      setState(() {
        _chapters.addAll(next.items.where((chapter) => seen.add(chapter.id)));
        _nextCursor = next.nextCursor;
        _totalCount = next.totalCount ?? _totalCount;
        _isLoadingMore = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _isLoadingMore = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法加载更多章节，请稍后重试。')));
    }
  }

  @override
  Widget build(BuildContext context) => _SourceDetailBody(
    bundle: _SourceDetailBundle(
      detail: widget.bundle.detail,
      chapters: PluginChaptersResult(
        pluginId: widget.bundle.chapters.pluginId,
        sourceName: widget.bundle.chapters.sourceName,
        items: _chapters,
        nextCursor: _nextCursor,
        totalCount: _totalCount,
      ),
    ),
    gateway: widget.gateway,
    relatedContents: widget.relatedContents,
    isRefreshing: widget.isRefreshing,
    onTextChapterRequested: widget.onTextChapterRequested,
    onAddToShelf: widget.onAddToShelf,
    shelfState: _shelfState,
    isSavingToShelf: _isSavingToShelf,
    onSaveToShelf: _saveToShelf,
    onExternalUrlRequested: widget.onExternalUrlRequested,
    isLoadingMore: _isLoadingMore,
    onLoadMore: _nextCursor == null ? null : _loadMore,
  );
}

class _SourceDetailBody extends StatelessWidget {
  const _SourceDetailBody({
    required this.bundle,
    required this.gateway,
    required this.relatedContents,
    required this.isRefreshing,
    required this.onTextChapterRequested,
    required this.onAddToShelf,
    required this.shelfState,
    required this.isSavingToShelf,
    required this.onSaveToShelf,
    required this.onExternalUrlRequested,
    required this.isLoadingMore,
    required this.onLoadMore,
  });

  final _SourceDetailBundle bundle;
  final SourceContentGateway gateway;
  final Iterable<PluginContentSummary> relatedContents;
  final bool isRefreshing;
  final SourceTextChapterRequested? onTextChapterRequested;
  final SourceShelfSaveRequested? onAddToShelf;
  final SourceDetailShelfState shelfState;
  final bool isSavingToShelf;
  final ValueChanged<PluginContentSummary> onSaveToShelf;
  final SourceExternalUrlLauncher onExternalUrlRequested;
  final bool isLoadingMore;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final detail = bundle.detail;
    final content = detail.summary;
    final tokens = AppThemeTokens.of(context);
    final theme = Theme.of(context);
    final firstChapter = bundle.chapters.items.isEmpty
        ? null
        : bundle.chapters.items.first;
    final labels = <String>{
      ...content.categories,
      ...content.tags,
    }.take(3).toList(growable: false);
    final attributes = _displayAttributes(
      content.attributes,
    ).toList(growable: false);
    final chapterTotal = _chapterTotal(
      reportedTotal: bundle.chapters.totalCount,
      detailTotal: content.chapterCount,
      loadedCount: bundle.chapters.items.length,
    );
    final recommendationCandidates = _recommendationCandidates(
      relatedContents,
      excludedId: content.id,
    );
    return ListView(
      key: const Key('source-content-detail-sheet'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: <Widget>[
        _DetailHeader(
          title: content.title,
          sourceUrl: content.url,
          onOpenUrl: _openUrl,
        ),
        if (isRefreshing)
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: tokens.accent,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '正在补充详情…',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.mutedText,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InkWell(
              key: const Key('source-detail-open-cover-url'),
              onTap: content.coverUrl == null
                  ? null
                  : () => unawaited(_openUrl(context, content.coverUrl)),
              borderRadius: AppRadii.discoveryCover,
              child: DiscoveryBookCover(
                key: const Key('source-detail-cover'),
                title: content.title,
                coverBytes: content.coverBytes,
                variant: _coverVariant(content.id),
                width: 112,
                height: 174,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    content.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.person_outline_rounded,
                        size: 20,
                        color: tokens.mutedText,
                      ),
                      const SizedBox(width: AppSpacing.unit),
                      Expanded(
                        child: Text(
                          content.author ?? '作者未知',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: tokens.mutedText,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (labels.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      children: labels
                          .map((value) => _DetailTag(label: value))
                          .toList(growable: false),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Divider(color: tokens.divider, height: 1),
                  _DetailStats(content: content),
                  Divider(color: tokens.divider, height: 1),
                  _ExternalRow(
                    key: const Key('source-detail-source-url'),
                    label: '来源频道：${detail.sourceName}',
                    url: content.url,
                    onOpenUrl: _openUrl,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('source-detail-add-shelf'),
                onPressed: shelfState == SourceDetailShelfState.alreadyAdded
                    ? () => ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('此书已在书架中。')))
                    : onAddToShelf == null
                    ? () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('书架保存功能尚未接入此书源。')),
                      )
                    : isSavingToShelf
                    ? null
                    : () => onSaveToShelf(content),
                icon: Icon(
                  shelfState == SourceDetailShelfState.alreadyAdded
                      ? Icons.bookmark_added_outlined
                      : isSavingToShelf
                      ? Icons.hourglass_top_rounded
                      : Icons.library_add_outlined,
                ),
                label: Text(
                  shelfState == SourceDetailShelfState.alreadyAdded
                      ? '已在书架'
                      : isSavingToShelf
                      ? '正在加入…'
                      : '加入书架',
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  foregroundColor: tokens.accent,
                  side: BorderSide(color: tokens.accent),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: FilledButton(
                key: const Key('source-detail-start-reading'),
                onPressed: firstChapter == null
                    ? null
                    : () => unawaited(
                        _openTextChapter(
                          context,
                          gateway: gateway,
                          detail: detail,
                          firstCatalogPage: bundle.chapters,
                          chapter: firstChapter,
                          onTextChapterRequested: onTextChapterRequested,
                        ),
                      ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  backgroundColor: tokens.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('开始阅读'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Divider(color: tokens.divider, height: 1),
        const SizedBox(height: 24),
        Text(
          '简介',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpacing.compact),
        Text(
          content.description ?? '正在获取作品简介…',
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: tokens.mutedText,
            height: 1.65,
          ),
        ),
        if (attributes.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: attributes
                .map((value) => _DetailTag(label: value.value))
                .toList(growable: false),
          ),
        ],
        const SizedBox(height: 24),
        Divider(color: tokens.divider, height: 1),
        if (content.latestChapter != null)
          _ExternalRow(
            key: const Key('source-detail-latest-chapter-url'),
            title: '最新章节',
            label: content.latestChapter!.title,
            subtitle:
                _attributeValue(content.attributes, 'discoveryUpdatedLabel') ??
                (content.latestChapter!.updatedAt == null
                    ? null
                    : _formatDateTime(content.latestChapter!.updatedAt!)),
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
          const SizedBox(height: 24),
          Divider(color: tokens.divider, height: 1),
          const SizedBox(height: 22),
          _RecommendationsSection(candidates: recommendationCandidates),
          const SizedBox(height: 20),
          Material(
            color: tokens.accentSoft.withValues(alpha: .52),
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {},
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('查看书友评论', style: theme.textTheme.bodyLarge),
                    ),
                    Text(
                      '4.2万条评论',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.mutedText,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded, color: tokens.mutedText),
                  ],
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 28),
        Divider(color: tokens.divider, height: 1),
        const SizedBox(height: 20),
        Text(
          '目录',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          chapterTotal == null ? '暂无章节' : '共 $chapterTotal 章',
          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
        ),
        for (final chapter in bundle.chapters.items)
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
              ),
            ),
            onOpenUrl: _openUrl,
          ),
        if (onLoadMore != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.regular),
            child: OutlinedButton(
              key: const Key('source-detail-load-more-chapters'),
              onPressed: isLoadingMore ? null : onLoadMore,
              child: isLoadingMore
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('加载更多章节'),
            ),
          ),
      ],
    );
  }

  Future<void> _openUrl(BuildContext context, Uri? url) async {
    if (url == null || (url.scheme != 'http' && url.scheme != 'https')) return;
    final launched = await onExternalUrlRequested(url);
    if (!context.mounted || launched) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法调用系统浏览器打开该链接。')));
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({
    required this.title,
    required this.sourceUrl,
    required this.onOpenUrl,
  });
  final String title;
  final Uri? sourceUrl;
  final Future<void> Function(BuildContext context, Uri? url) onOpenUrl;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Stack(
      alignment: Alignment.center,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 96),
          child: Text(
            title,
            key: const Key('source-detail-header-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Row(
          children: <Widget>[
            IconButton(
              key: const Key('source-detail-back'),
              tooltip: '返回',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
            ),
            const Spacer(),
            IconButton(
              key: const Key('source-detail-open-source-url'),
              tooltip: '在浏览器打开来源',
              onPressed: sourceUrl == null
                  ? null
                  : () => unawaited(onOpenUrl(context, sourceUrl)),
              icon: const Icon(Icons.ios_share_rounded),
            ),
            IconButton(
              tooltip: '更多',
              onPressed: () {},
              icon: const Icon(Icons.more_vert_rounded),
            ),
          ],
        ),
      ],
    ),
  );
}

class _DetailStats extends StatelessWidget {
  const _DetailStats({required this.content});
  final PluginContentSummary content;

  @override
  Widget build(BuildContext context) {
    final rating = _attributeValue(content.attributes, 'rating');
    final ratingCount = _attributeValue(content.attributes, 'ratingCount');
    final heat = _attributeValue(content.attributes, 'heat');
    final favorites = _attributeValue(content.attributes, 'favorites');
    final firstLabel = rating != null
        ? '${ratingCount == null ? '' : _formatStatValue(ratingCount)}人评分'
        : heat == null
        ? '热度'
        : favorites == null
        ? '热度'
        : '热度 · 收藏 ${_formatStatValue(favorites)}';
    final firstValue = rating != null
        ? _formatStatValue(rating)
        : heat == null
        ? '—'
        : _formatStatValue(heat);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          _Stat(
            value: firstValue,
            label: firstLabel,
            suffix: rating == null ? null : '★★★★★',
          ),
          _Stat(
            value: _wordCount(content.wordCount),
            label: _wordCountLabel(content.wordCount),
          ),
          _Stat(
            value: _chapterCount(content.chapterCount),
            label: _statusLabel(content.status),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.suffix});
  final String value;
  final String label;
  final String? suffix;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ),
            if (suffix != null)
              Text(
                suffix!,
                maxLines: 1,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppThemeTokens.of(context).accent,
                  letterSpacing: -1,
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppThemeTokens.of(context).mutedText,
          ),
        ),
      ],
    ),
  );
}

List<PluginContentSummary> _recommendationCandidates(
  Iterable<PluginContentSummary> contents, {
  required String excludedId,
}) {
  final seen = <String>{excludedId};
  return contents.where((item) => seen.add(item.id)).toList(growable: false);
}

class _RecommendationsSection extends StatefulWidget {
  const _RecommendationsSection({required this.candidates});

  final List<PluginContentSummary> candidates;

  @override
  State<_RecommendationsSection> createState() =>
      _RecommendationsSectionState();
}

class _RecommendationsSectionState extends State<_RecommendationsSection> {
  late List<PluginContentSummary> _visibleCandidates;

  @override
  void initState() {
    super.initState();
    _reshuffle(useRandom: false);
  }

  @override
  void didUpdateWidget(covariant _RecommendationsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.candidates.length != widget.candidates.length ||
        !_sameCandidateIds(oldWidget.candidates, widget.candidates)) {
      _reshuffle(useRandom: false);
    }
  }

  void _reshuffle({bool useRandom = true}) {
    _visibleCandidates = List<PluginContentSummary>.of(widget.candidates)
      ..shuffle(math.Random(useRandom ? null : _recommendationSeed()));
  }

  int _recommendationSeed() {
    var seed = 17;
    for (final candidate in widget.candidates) {
      for (final unit in candidate.id.codeUnits) {
        seed = (seed * 31 + unit) & 0x7fffffff;
      }
    }
    return seed;
  }

  bool _sameCandidateIds(
    List<PluginContentSummary> previous,
    List<PluginContentSummary> current,
  ) {
    if (previous.length != current.length) return false;
    for (var index = 0; index < current.length; index++) {
      if (previous[index].id != current[index].id) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '猜你喜欢',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Semantics(
              button: true,
              label: '换一换推荐内容',
              child: InkWell(
                key: const Key('source-detail-recommendations-refresh'),
                borderRadius: AppRadii.pill,
                onTap: () => setState(_reshuffle),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.unit,
                    vertical: AppSpacing.unit,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('换一换', style: theme.textTheme.bodyMedium),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.refresh_rounded,
                        size: 18,
                        color: tokens.mutedText,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SizedBox(
          key: const Key('source-detail-recommendations-scroll'),
          height: 194,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _visibleCandidates
                  .map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _RecommendationCard(content: item),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ),
      ],
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.content});

  final PluginContentSummary content;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      DiscoveryBookCover(
        title: content.title,
        coverBytes: content.coverBytes,
        variant: _coverVariant(content.id),
        width: 96,
        height: 140,
      ),
      const SizedBox(height: 7),
      Text(
        content.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: 2),
      Text(
        content.author ?? '作者未知',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppThemeTokens.of(context).mutedText,
        ),
      ),
    ],
  );
}

class _DetailTag extends StatelessWidget {
  const _DetailTag({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppThemeTokens.of(context).mutedSurface,
      borderRadius: AppRadii.pill,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.compact,
        vertical: AppSpacing.unit,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppThemeTokens.of(context).mutedText,
        ),
      ),
    ),
  );
}

class _ExternalRow extends StatelessWidget {
  const _ExternalRow({
    required this.label,
    required this.url,
    required this.onOpenUrl,
    this.title,
    this.subtitle,
    super.key,
  });
  final String? title;
  final String label;
  final String? subtitle;
  final Uri? url;
  final Future<void> Function(BuildContext context, Uri? url) onOpenUrl;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: url == null ? null : () => unawaited(onOpenUrl(context, url)),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (title != null)
                  Text(
                    title!,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppThemeTokens.of(context).mutedText,
                    ),
                  ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: AppThemeTokens.of(context).mutedText,
          ),
        ],
      ),
    ),
  );
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.chapter,
    required this.onRead,
    required this.onOpenUrl,
  });
  final PluginChapterSummary chapter;
  final VoidCallback onRead;
  final Future<void> Function(BuildContext context, Uri? url) onOpenUrl;
  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey<String>('source-chapter-${chapter.id}'),
    contentPadding: EdgeInsets.zero,
    title: Text(chapter.title),
    subtitle: Text(_chapterSubtitle(chapter)),
    trailing: chapter.url == null
        ? const Icon(Icons.chevron_right_rounded)
        : IconButton(
            key: ValueKey<String>('source-chapter-url-${chapter.id}'),
            tooltip: '在浏览器打开章节',
            onPressed: () => unawaited(onOpenUrl(context, chapter.url)),
            icon: const Icon(Icons.open_in_browser_rounded),
          ),
    onTap: onRead,
  );
}

Future<void> _openTextChapter(
  BuildContext context, {
  required SourceContentGateway gateway,
  required PluginContentDetail detail,
  required PluginChaptersResult firstCatalogPage,
  required PluginChapterSummary chapter,
  required SourceTextChapterRequested? onTextChapterRequested,
}) async {
  final callback = onTextChapterRequested;
  if (callback == null) {
    await _showChapterContent(
      context,
      gateway: gateway,
      pluginId: detail.pluginId,
      id: detail.summary.id,
      chapter: chapter,
    );
    return;
  }
  Navigator.of(context).pop();
  await callback(
    detail: detail,
    firstCatalogPage: firstCatalogPage,
    chapter: chapter,
  );
}

Future<void> _showChapterContent(
  BuildContext context, {
  required SourceContentGateway gateway,
  required String pluginId,
  required String id,
  required PluginChapterSummary chapter,
}) {
  final contentFuture = gateway.getContent(
    pluginId: pluginId,
    id: id,
    chapterId: chapter.id,
  );
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: .9,
      child: FutureBuilder<PluginChapterContent>(
        future: contentFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return _DetailFailure(error: AppError.fromUnknown(snapshot.error!));
          }
          final content = snapshot.requireData;
          return ListView(
            key: const Key('source-chapter-content-sheet'),
            padding: const EdgeInsets.all(AppSpacing.comfortable),
            children: <Widget>[
              Text(
                content.title ?? chapter.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.regular),
              if (content.contentKind == PluginContentKind.novel)
                SelectableText(content.text ?? '')
              else
                for (final page in content.pages)
                  _ExternalRow(
                    label: '第 ${page.index + 1} 页',
                    subtitle: _mangaPageSubtitle(page),
                    url: page.url,
                    onOpenUrl: (context, url) async {
                      if (url != null) await _launchSystemBrowser(url);
                    },
                  ),
            ],
          );
        },
      ),
    ),
  );
}

class _DetailFailure extends StatelessWidget {
  const _DetailFailure({required this.error});
  final AppError error;
  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      '无法加载内容（${error.code.wireValue}）',
      key: const Key('source-content-sheet-failure'),
    ),
  );
}

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return DiscoveryCoverVariant.values[checksum %
      DiscoveryCoverVariant.values.length];
}

String _wordCount(int? value) {
  if (value == null) return '—';
  return _formatReadableCount(value);
}

String _wordCountLabel(int? value) =>
    value != null && value >= 10000 ? '万字' : '字数';

String _chapterCount(int? value) =>
    value == null ? '—' : _formatReadableCount(value);

int? _chapterTotal({
  required int? reportedTotal,
  required int? detailTotal,
  required int loadedCount,
}) {
  for (final count in <int?>[reportedTotal, detailTotal]) {
    if (count != null && count > 0) return count;
  }
  return loadedCount > 0 ? loadedCount : null;
}

String _formatStatValue(String value) {
  final normalized = value.trim();
  final parsed = num.tryParse(normalized);
  if (parsed == null || !parsed.isFinite) return value;
  if (parsed == parsed.roundToDouble()) {
    return _formatReadableCount(parsed.toInt());
  }
  if (parsed.abs() >= 10000) {
    return _formatReadableDecimal(parsed);
  }
  return normalized;
}

String _formatReadableCount(int value) {
  final absolute = value.abs();
  if (absolute >= 100000000) {
    return '${value < 0 ? '-' : ''}${_trimDecimal(absolute / 100000000)}亿';
  }
  if (absolute >= 10000) {
    return '${value < 0 ? '-' : ''}${_trimDecimal(absolute / 10000)}万';
  }
  return '$value';
}

String _formatReadableDecimal(num value) {
  final absolute = value.abs();
  if (absolute >= 100000000) {
    return '${value < 0 ? '-' : ''}${_trimDecimal(absolute / 100000000)}亿';
  }
  return '${value < 0 ? '-' : ''}${_trimDecimal(absolute / 10000)}万';
}

String _trimDecimal(num value) => value
    .toStringAsFixed(2)
    .replaceFirst(RegExp(r'\.0+$'), '')
    .replaceFirst(RegExp(r'0+$'), '');
String _statusLabel(PluginContentStatus value) => switch (value) {
  PluginContentStatus.ongoing => '连载中',
  PluginContentStatus.completed => '已完结',
  PluginContentStatus.hiatus => '暂停',
  PluginContentStatus.unknown => '未知',
};
String _chapterSubtitle(PluginChapterSummary chapter) => <String>[
  if (chapter.wordCount != null) '${chapter.wordCount} 字',
  if (chapter.updatedAt != null) _formatDateTime(chapter.updatedAt!),
  if (chapter.isLocked != null) chapter.isLocked! ? '已锁定' : '可阅读',
].join(' · ');
String _mangaPageSubtitle(PluginMangaPage page) => <String>[
  if (page.mimeType != null) page.mimeType!,
  if (page.width != null && page.height != null)
    '${page.width} × ${page.height}',
].join(' · ');

String? _attributeValue(
  Iterable<PluginContentAttribute> attributes,
  String key,
) {
  for (final attribute in attributes) {
    if (attribute.key == key) return attribute.value;
  }
  return null;
}

Iterable<PluginContentAttribute> _displayAttributes(
  Iterable<PluginContentAttribute> attributes,
) => attributes.where(
  (attribute) =>
      attribute.key != 'heat' &&
      attribute.key != 'favorites' &&
      attribute.key != 'rating' &&
      attribute.key != 'ratingCount' &&
      attribute.key != 'discoveryUpdatedLabel',
);

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String twoDigits(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} ${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}
