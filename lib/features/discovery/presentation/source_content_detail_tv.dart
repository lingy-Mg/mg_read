/// TV video detail composition: compact poster, viewing actions, then episodes.
/// Reuses the detail owner's loading, shelf and chapter callbacks; owns no IO.
/// Metadata stays source-owned; reading statistics are excluded from this view.
part of 'source_content_detail_sheet.dart';

Future<bool> _confirmTvFavoriteRemoval(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('tv-favorite-removal-confirmation'),
        scrollable: true,
        title: const Text('移出收藏'),
        content: Text('确定要将《$title》移出收藏吗？'),
        actions: [
          TextButton(autofocus: true, onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('移出')),
        ],
      ),
    ) ??
    false;

class _TvVideoDetail extends StatelessWidget {
  const _TvVideoDetail({required this.body, required this.canPlay, required this.canChangeShelf});

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
    final recommendations = _recommendationCandidates(
      body.relatedContents,
      excludedId: content.id,
    ).where((candidate) => candidate.contentKind == PluginContentKind.video).toList();
    final labels = <String>{...content.categories, ...content.tags, ..._displayAttributes(content.attributes).map((value) => value.value)};
    void play(PluginChapterSummary chapter, PluginChaptersResult chapters) => unawaited(
      _openTextChapter(
        context,
        gateway: body.gateway,
        detail: detail,
        firstCatalogPage: chapters,
        chapter: chapter,
        onTextChapterRequested: null,
        onComicChapterRequested: null,
        onAudioChapterRequested: null,
        onVideoEpisodeRequested: body.onVideoEpisodeRequested,
      ),
    );
    return ListView(
      key: const Key('source-content-detail-sheet'),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final posterWidth = constraints.maxWidth < 700 ? 104.0 : 144.0;
            final presentation = discoveryCoverPresentation(content.coverOrientation);
            return Row(
              key: const Key('tv-video-detail-summary'),
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
                  width: posterWidth,
                  height:
                      posterWidth *
                      (presentation == DiscoveryCoverPresentation.landscape
                          ? 9 / 16
                          : presentation == DiscoveryCoverPresentation.square
                          ? 1
                          : 1.38),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        content.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (labels.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          labels.take(6).join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          TvFocusable(
                            key: const Key('source-detail-start-reading'),
                            autofocus: canPlay,
                            onPressed: canPlay ? () => play(catalog.items.first, catalog) : null,
                            selected: true,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.play_arrow_rounded),
                                const SizedBox(width: 8),
                                Text(body.isRefreshing ? '正在加载…' : '开始播放', style: theme.textTheme.titleMedium),
                              ],
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
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          if (body.sourceVariants.length > 1 && body.onSourceVariantRequested != null)
                            TvFocusable(
                              key: const Key('source-detail-source-variants'),
                              onPressed: () => showSourceContentVariantPicker(
                                context,
                                variants: body.sourceVariants,
                                selectedPluginId: detail.pluginId,
                                selectedContentId: content.id,
                                onSelected: body.onSourceVariantRequested!,
                              ),
                              child: const Text('切换来源'),
                            ),
                        ],
                      ),
                      if (content.description case final description? when description.trim().isNotEmpty) ...[
                        const SizedBox(height: 12),
                        TvFocusable(
                          key: const Key('tv-video-detail-description'),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              scrollable: true,
                              title: const Text('影片简介'),
                              content: Text(description),
                              actions: [TextButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
                            ),
                          ),
                          child: Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
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
        const SizedBox(height: 12),
        if (recommendations.isNotEmpty && body.onRecommendationRequested != null) ...[
          Text('相关影片', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          DiscoveryCoverGrid(
            items: [
              for (final item in recommendations) PluginDiscoveryContentItem(content: item, rank: null, metric: null, recommendation: null),
            ],
            onPressed: (item) => unawaited(body.onRecommendationRequested!(item)),
            isInBookshelf: (_) => false,
          ),
          const SizedBox(height: 12),
        ],
        Text('方向键选择 · OK 确认 · 返回退出详情', style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
      ],
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
      final columns = (constraints.maxWidth / 210).floor().clamp(2, 6);
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
