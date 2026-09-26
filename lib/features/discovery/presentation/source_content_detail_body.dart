/// 数据源内容详情的主体组合。
///
/// 职责：
/// - 组合详情摘要、书架动作、简介、来源、推荐与目录区块。
/// - 将章节、来源版本、书架和外链交互委托给既有回调。
///
/// 注意：
/// - 本文件只负责展示与用户交互，不持有加载或书架状态。
/// - 外链仅接受 HTTP(S)，启动失败时在当前详情页反馈。
part of 'source_content_detail_sheet.dart';

class _SourceDetailBody extends StatelessWidget {
  const _SourceDetailBody({
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
    required this.isSavingToShelf,
    required this.isRemovingFromShelf,
    required this.onSaveToShelf,
    required this.onRemoveFromShelfRequested,
    required this.onExternalUrlRequested,
    this.isCoverBlurred = false,
    required this.visibleChapterCount,
    required this.onLoadMore,
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
    final canStartReading =
        !isRefreshing &&
        !hasLoadFailure &&
        firstChapter != null &&
        switch (content.contentKind) {
          PluginContentKind.audio => onAudioChapterRequested != null,
          PluginContentKind.video => onVideoEpisodeRequested != null,
          _ => true,
        };
    final canChangeShelf =
        !isRefreshing &&
        !hasLoadFailure &&
        (shelfState != SourceDetailShelfState.canAdd
            ? onRemoveFromShelf != null && !isRemovingFromShelf
            : onAddToShelf != null && !isSavingToShelf);
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
        _DetailSummaryHeader(
          content: content,
          labels: labels,
          onCoverTap: content.coverUrl == null ? null : () => unawaited(_openUrl(context, content.coverUrl)),
        ),
        if (sourceVariants.length > 1 && onSourceVariantRequested != null) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          OutlinedButton.icon(
            key: const Key('source-detail-source-variants'),
            onPressed: () => showSourceContentVariantPicker(
              context,
              variants: sourceVariants,
              selectedPluginId: bundle.detail.pluginId,
              selectedContentId: bundle.detail.summary.id,
              onSelected: onSourceVariantRequested!,
            ),
            icon: const Icon(Icons.layers_outlined),
            label: Text('来源版本（${sourceVariants.length}）'),
          ),
        ],
        const SizedBox(height: AppSpacing.section),
        if (shelfState != SourceDetailShelfState.canAdd &&
            onShelfAction != null &&
            onStartReading != null &&
            (content.contentKind == PluginContentKind.novel || content.contentKind == PluginContentKind.manga))
          _ShelfActionBar(
            title: content.title,
            shelfState: shelfState,
            isCoverBlurred: isCoverBlurred,
            onAction: onShelfAction!,
            onStartReading: onStartReading!,
            canStartReading: canStartReading,
          )
        else
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('source-detail-add-shelf'),
                  onPressed: !canChangeShelf
                      ? null
                      : shelfState != SourceDetailShelfState.canAdd
                      ? () => onRemoveFromShelfRequested(content)
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
                    foregroundColor: canChangeShelf ? tokens.accent : tokens.mutedText,
                    side: BorderSide(color: canChangeShelf ? tokens.accent : tokens.divider),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: FilledButton(
                  key: const Key('source-detail-start-reading'),
                  onPressed: !canStartReading
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
                    backgroundColor: canStartReading ? tokens.accent : tokens.mutedSurface,
                    disabledBackgroundColor: tokens.mutedSurface,
                    disabledForegroundColor: tokens.mutedText,
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
            color: tokens.mutedSurface,
            borderRadius: BorderRadius.circular(14),
            child: Semantics(
              enabled: false,
              label: '查看书友评论，暂不可用',
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text('查看书友评论', style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText)),
                      ),
                      Text('4.2万条评论', style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText.withValues(alpha: .68))),
                      const SizedBox(width: 6),
                      Icon(Icons.chevron_right_rounded, color: tokens.mutedText.withValues(alpha: .5)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        _DetailCatalogSection(
          catalog: bundle.chapters,
          gateway: gateway,
          contentId: content.id,
          contentKind: content.contentKind,
          isRefreshing: isRefreshing,
          chapterTotal: chapterTotal,
          visibleChapterCount: visibleChapterCount,
          onLoadMore: onLoadMore,
          onChapterSelected: (chapter, catalog) => unawaited(
            _openTextChapter(
              context,
              gateway: gateway,
              detail: detail,
              firstCatalogPage: catalog,
              chapter: chapter,
              onTextChapterRequested: onTextChapterRequested,
              onComicChapterRequested: onComicChapterRequested,
              onAudioChapterRequested: onAudioChapterRequested,
              onVideoEpisodeRequested: onVideoEpisodeRequested,
            ),
          ),
          onOpenUrl: _openUrl,
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
