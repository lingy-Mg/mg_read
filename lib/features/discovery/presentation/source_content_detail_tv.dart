/// TV 内容详情：摘要和操作独立于目录滚动，所有媒体共用已有加载与书架状态。
/// 来源标题、分组和章节保持原样；本文件不执行 IO，简介在遥控可读弹窗展开。
part of 'source_content_detail_sheet.dart';

Future<bool> _confirmTvFavoriteRemoval(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => TvDiscoveryDialog(
        key: const Key('tv-favorite-removal-confirmation'),
        title: '移出收藏',
        actions: [
          TvFocusable(autofocus: true, onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TvFocusable(onPressed: () => Navigator.pop(context, true), child: const Text('移出')),
        ],
        child: Text('确定要将《$title》移出收藏吗？'),
      ),
    ) ??
    false;

class _TvContentDetail extends StatelessWidget {
  const _TvContentDetail({required this.body, required this.canPlay, required this.canChangeShelf});
  final _SourceDetailBody body;
  final bool canPlay;
  final bool canChangeShelf;

  @override
  Widget build(BuildContext context) {
    final detail = body.bundle.detail;
    final content = detail.summary;
    final catalog = body.bundle.chapters;
    final tokens = AppThemeTokens.of(context);
    final theme = Theme.of(context);
    final video = content.contentKind == PluginContentKind.video;
    final audio = content.contentKind == PluginContentKind.audio;
    final recommendations = _recommendationCandidates(
      body.relatedContents,
      excludedId: content.id,
    ).where((candidate) => candidate.contentKind == content.contentKind).toList();
    final labels = <String>{...content.categories, ...content.tags, ..._displayAttributes(content.attributes).map((value) => value.value)};
    void play(PluginChapterSummary chapter, PluginChaptersResult chapters) => unawaited(
      _openTextChapter(
        context,
        gateway: body.gateway,
        detail: detail,
        firstCatalogPage: chapters,
        chapter: chapter,
        onTextChapterRequested: body.onTextChapterRequested,
        onComicChapterRequested: body.onComicChapterRequested,
        onAudioChapterRequested: body.onAudioChapterRequested,
        onVideoEpisodeRequested: body.onVideoEpisodeRequested,
      ),
    );
    return TvDiscoveryWorkspace(
      key: const Key('source-content-detail-sheet'),
      sidebarFraction: .38,
      sidebar: ListView(
        key: const Key('tv-video-detail-summary'),
        padding: const EdgeInsets.all(4),
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final presentation = discoveryCoverPresentation(content.coverOrientation);
              final compact = MediaQuery.sizeOf(context).height < 500;
              final width = compact ? 64.0 : 100.0;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DiscoveryBookCover(
                    title: content.title,
                    variant: DiscoveryCoverVariant.values.first,
                    contentKind: content.contentKind,
                    remoteContentId: content.id,
                    coverUrl: content.coverUrl,
                    coverBytes: content.coverBytes,
                    presentation: presentation,
                    width: width,
                    height:
                        width *
                        (presentation == DiscoveryCoverPresentation.landscape
                            ? 9 / 16
                            : presentation == DiscoveryCoverPresentation.square
                            ? 1
                            : 1.38),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          content.title,
                          maxLines: compact ? 2 : 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          detail.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              TvFocusable(
                key: const Key('source-detail-start-reading'),
                autofocus: canPlay,
                selected: true,
                onPressed: canPlay ? () => play(catalog.items.first, catalog) : null,
                child: Text(
                  body.isRefreshing
                      ? '正在加载…'
                      : video
                      ? '开始播放'
                      : audio
                      ? '开始收听'
                      : '开始阅读',
                ),
              ),
              TvFocusable(
                key: const Key('source-detail-add-shelf'),
                onPressed: canChangeShelf
                    ? () => body.shelfState == SourceDetailShelfState.canAdd
                          ? body.onSaveToShelf(detail)
                          : body.onRemoveFromShelfRequested(content)
                    : null,
                child: Text(
                  body.isSavingToShelf || body.isRemovingFromShelf
                      ? '正在处理…'
                      : body.shelfState == SourceDetailShelfState.canAdd
                      ? '加入收藏'
                      : '移出收藏',
                ),
              ),
            ],
          ),
          if (body.sourceVariants.length > 1 && body.onSourceVariantRequested != null) ...[
            const SizedBox(height: 12),
            TvFocusable(
              key: const Key('source-detail-source-variants'),
              onPressed: () => showSourceContentVariantPicker(
                context,
                variants: body.sourceVariants,
                selectedPluginId: detail.pluginId,
                selectedContentId: content.id,
                onSelected: body.onSourceVariantRequested!,
              ),
              child: Text('切换来源 · ${body.sourceVariants.length}'),
            ),
          ],
          if (labels.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              labels.take(6).join(' · '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
            ),
          ],
          const SizedBox(height: 16),
          TvFocusable(
            key: const Key('tv-video-detail-description'),
            onPressed: () => showTvDiscoveryText(
              context,
              title: content.title,
              text: [
                content.title,
                detail.sourceName,
                if (content.author != null) content.author!,
                labels.join(' · '),
                content.description ?? '暂无简介',
              ].where((value) => value.trim().isNotEmpty).join('\n\n'),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('内容简介  ›'),
                const SizedBox(height: 8),
                Text(
                  content.description ?? '暂无简介',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                ),
              ],
            ),
          ),
          if ((detail.catalogUrl ?? content.url) != null) ...[
            const SizedBox(height: 12),
            TvFocusable(
              key: const Key('source-detail-catalog-url'),
              onPressed: () => unawaited(body._openUrl(context, detail.catalogUrl ?? content.url)),
              child: const Text('打开来源页面'),
            ),
          ],
        ],
      ),
      child: ListView(
        key: const Key('tv-detail-catalog-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          _DetailCatalogSection(
            catalog: catalog,
            gateway: body.gateway,
            contentId: content.id,
            contentKind: content.contentKind,
            isRefreshing: body.isRefreshing,
            chapterTotal: _chapterTotal(detailTotal: content.chapterCount, loadedCount: catalog.items.length),
            visibleChapterCount: body.visibleChapterCount,
            onLoadMore: body.onLoadMore,
            onChapterSelected: play,
            onOpenUrl: body._openUrl,
          ),
          if (recommendations.isNotEmpty && body.onRecommendationRequested != null) ...[
            const SizedBox(height: 28),
            Text('相关推荐', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            _TvDetailRecommendations(items: recommendations, onSelected: (item) => unawaited(body.onRecommendationRequested!(item))),
          ],
        ],
      ),
    );
  }
}

class _TvDetailEpisodes extends StatelessWidget {
  const _TvDetailEpisodes({
    required this.episodes,
    required this.groupId,
    required this.onSelected,
    this.focusedEpisodeId,
    this.episodeFocusNode,
  });
  final String? focusedEpisodeId;
  final FocusNode? episodeFocusNode;
  final Iterable<PluginChapterSummary> episodes;
  final String groupId;
  final ValueChanged<PluginChapterSummary> onSelected;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / (140 * MediaQuery.textScalerOf(context).scale(1))).floor().clamp(1, 6);
      final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final episode in episodes)
              SizedBox(
                width: width,
                child: TvFocusable(
                  key: ValueKey('source-detail-episode-$groupId-${episode.id}'),
                  focusNode: episode.id == focusedEpisodeId ? episodeFocusNode : null,
                  onPressed: () => onSelected(episode),
                  child: Text(episode.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyMedium),
                ),
              ),
          ],
        ),
      );
    },
  );
}

/// Recommendations size against the detail pane, preserving remote readability.
class _TvDetailRecommendations extends StatelessWidget {
  const _TvDetailRecommendations({required this.items, required this.onSelected});
  final List<PluginContentSummary> items;
  final ValueChanged<PluginContentSummary> onSelected;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / (220 * MediaQuery.textScalerOf(context).scale(1))).floor().clamp(1, 4);
      final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final item in items)
            SizedBox(
              width: width,
              child: TvFocusable(
                key: ValueKey('tv-detail-recommendation-${item.id}'),
                onPressed: () => onSelected(item),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DiscoveryBookCover(
                      title: item.title,
                      variant: DiscoveryCoverVariant.values.first,
                      contentKind: item.contentKind,
                      remoteContentId: item.id,
                      coverUrl: item.coverUrl,
                      coverBytes: item.coverBytes,
                      presentation: discoveryCoverPresentation(item.coverOrientation),
                      width: width - 24,
                      height: (width - 24) * 9 / 16,
                    ),
                    const SizedBox(height: 12),
                    Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Ungrouped catalogs reveal the first newly added chapter after remote paging.
class _TvUngroupedCatalog extends StatefulWidget {
  const _TvUngroupedCatalog({required this.episodes, required this.onSelected, super.key});
  final List<PluginChapterSummary> episodes;
  final ValueChanged<PluginChapterSummary> onSelected;
  @override
  State<_TvUngroupedCatalog> createState() => _TvUngroupedCatalogState();
}

class _TvUngroupedCatalogState extends State<_TvUngroupedCatalog> {
  int _count = 24;
  String? _expandedId;
  final _expandedFocus = FocusNode();
  @override
  void dispose() {
    _expandedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _TvDetailEpisodes(
        episodes: widget.episodes.take(_count),
        groupId: 'default',
        onSelected: widget.onSelected,
        focusedEpisodeId: _expandedId,
        episodeFocusNode: _expandedFocus,
      ),
      if (widget.episodes.length > _count)
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: TvFocusable(
            key: const Key('source-detail-load-more-chapters'),
            onPressed: () {
              setState(() {
                _expandedId = widget.episodes[_count].id;
                _count = math.min(_count + 24, widget.episodes.length);
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) requestTvFocus(_expandedFocus);
              });
            },
            child: const Text('显示更多章节'),
          ),
        ),
    ],
  );
}
