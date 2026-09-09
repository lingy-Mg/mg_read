part of 'source_content_detail_sheet.dart';

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.isModalSheet});

  final bool isModalSheet;

  @override
  Widget build(BuildContext context) => DiscoveryTopBar(
    title: isModalSheet ? '书籍详情' : '详情',
    sourceName: '当前来源',
    onSourcePressed: () {},
    onSearchPressed: () {},
    onToggleTheme: () {},
    onBackPressed: () => Navigator.of(context).pop(),
    backButtonKey: const Key('source-detail-back'),
    barKey: const Key('source-detail-header'),
    titleKey: const Key('source-detail-header-title'),
    showSourceSelector: false,
    showSearchAction: false,
    trailingActions: isModalSheet
        ? <Widget>[]
        : <Widget>[DiscoveryTopAction(tooltip: '更多', icon: Icons.more_vert_rounded, onPressed: () {})],
  );
}

/// Routes to one of two independent detail-header compositions. The source's
/// cover direction selects the composition; media kind does not participate.
class _DetailSummaryHeader extends StatelessWidget {
  const _DetailSummaryHeader({required this.content, required this.labels, required this.onCoverTap});

  final PluginContentSummary content;
  final List<String> labels;
  final VoidCallback? onCoverTap;

  @override
  Widget build(BuildContext context) => switch (content.coverOrientation) {
    PluginCoverOrientation.portrait => _PortraitDetailSummaryHeader(content: content, labels: labels, onCoverTap: onCoverTap),
    PluginCoverOrientation.landscape => _LandscapeDetailSummaryHeader(content: content, labels: labels, onCoverTap: onCoverTap),
  };
}

/// Portrait covers keep a compact cover-and-metadata row.
class _PortraitDetailSummaryHeader extends StatelessWidget {
  const _PortraitDetailSummaryHeader({required this.content, required this.labels, required this.onCoverTap});

  final PluginContentSummary content;
  final List<String> labels;
  final VoidCallback? onCoverTap;

  @override
  Widget build(BuildContext context) => Row(
    key: const Key('source-detail-portrait-header'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _DetailCoverLink(content: content, width: 112, height: 174, presentation: DiscoveryCoverPresentation.portrait, onTap: onCoverTap),
      const SizedBox(width: AppSpacing.regular),
      Expanded(
        child: _DetailHeaderMetadata(content: content, labels: labels),
      ),
    ],
  );
}

/// Landscape covers use a full-width visual followed by metadata. They are not
/// treated as video thumbnails and receive no play affordance or media badge.
class _LandscapeDetailSummaryHeader extends StatelessWidget {
  const _LandscapeDetailSummaryHeader({required this.content, required this.labels, required this.onCoverTap});

  final PluginContentSummary content;
  final List<String> labels;
  final VoidCallback? onCoverTap;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('source-detail-landscape-header'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return _DetailCoverLink(
            content: content,
            width: width,
            height: width * AppSpacing.discoveryLandscapeCoverAspectRatio,
            presentation: DiscoveryCoverPresentation.landscape,
            onTap: onCoverTap,
          );
        },
      ),
      const SizedBox(height: AppSpacing.regular),
      _DetailHeaderMetadata(content: content, labels: labels),
    ],
  );
}

class _DetailCoverLink extends StatelessWidget {
  const _DetailCoverLink({
    required this.content,
    required this.width,
    required this.height,
    required this.presentation,
    required this.onTap,
  });

  final PluginContentSummary content;
  final double width;
  final double height;
  final DiscoveryCoverPresentation presentation;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    key: const Key('source-detail-open-cover-url'),
    onTap: onTap,
    borderRadius: presentation == DiscoveryCoverPresentation.landscape ? BorderRadius.circular(10) : AppRadii.discoveryCover,
    child: DiscoveryBookCover(
      key: const Key('source-detail-cover'),
      title: content.title,
      coverBytes: content.coverBytes,
      remoteContentId: content.id,
      coverUrl: content.coverUrl,
      variant: _coverVariant(content.id),
      width: width,
      height: height,
      presentation: presentation,
    ),
  );
}

class _DetailHeaderMetadata extends StatelessWidget {
  const _DetailHeaderMetadata({required this.content, required this.labels});

  final PluginContentSummary content;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Column(
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
    );
  }
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
          _Stat(value: firstValue, label: firstLabel, suffix: rating == null ? null : '★★★★★'),
          _Stat(value: _wordCount(content.wordCount), label: _wordCountLabel(content.wordCount)),
          _Stat(value: _chapterCount(content.chapterCount), label: _statusLabel(content.status)),
        ],
      ),
    );
  }
}

class _ShelfActionBar extends StatefulWidget {
  const _ShelfActionBar({
    required this.title,
    required this.shelfState,
    required this.onAction,
    required this.onStartReading,
    this.isCoverBlurred = false,
  });

  final String? title;
  final SourceDetailShelfState shelfState;
  final SourceShelfActionRequested onAction;
  final SourceStartReadingRequested onStartReading;
  final bool isCoverBlurred;

  @override
  State<_ShelfActionBar> createState() => _ShelfActionBarState();
}

class _ShelfActionBarState extends State<_ShelfActionBar> {
  SourceShelfAction? _runningAction;
  late bool _isCoverBlurred;

  @override
  void initState() {
    super.initState();
    _isCoverBlurred = widget.isCoverBlurred;
  }

  @override
  void didUpdateWidget(covariant _ShelfActionBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_runningAction == null && oldWidget.isCoverBlurred != widget.isCoverBlurred) {
      _isCoverBlurred = widget.isCoverBlurred;
    }
  }

  bool get _isRunning => _runningAction != null;
  bool get _isRefreshing => _runningAction == SourceShelfAction.refresh;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final bool isPrivate = widget.shelfState == SourceDetailShelfState.private;
    final shape = RoundedRectangleBorder(borderRadius: AppRadii.control);
    ButtonStyle style(Color foreground, Color border) => OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(50),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.unit),
      foregroundColor: foreground,
      side: BorderSide(color: border),
      shape: shape,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const int columnCount = 3;
        final actionWidth = (constraints.maxWidth - AppSpacing.compact * (columnCount - 1)) / columnCount;
        return Wrap(
          spacing: AppSpacing.compact,
          runSpacing: AppSpacing.compact,
          children: <Widget>[
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-refresh-action'),
                onPressed: _isRunning ? null : () => _run(SourceShelfAction.refresh),
                icon: _isRefreshing
                    ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh_rounded),
                label: Text(_isRefreshing ? '刷新中' : '刷新'),
                style: style(tokens.accent, tokens.accent),
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-privacy-action'),
                onPressed: _isRunning ? null : () => _run(isPrivate ? SourceShelfAction.cancelPrivate : SourceShelfAction.setPrivate),
                icon: Icon(isPrivate ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                label: Text(isPrivate ? '取消隐私' : '隐私'),
                style: style(tokens.mutedText, tokens.divider),
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-cover-blur-action'),
                onPressed: _isRunning ? null : () => _run(SourceShelfAction.toggleCoverBlur),
                icon: Icon(_isCoverBlurred ? Icons.blur_off_rounded : Icons.blur_on_rounded),
                label: Text(_isCoverBlurred ? '取消模糊' : '模糊封面'),
                style: style(tokens.mutedText, tokens.divider),
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-delete-action'),
                onPressed: _isRunning ? null : () => _confirmDelete(context),
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('删除'),
                style: style(Theme.of(context).colorScheme.error, Theme.of(context).colorScheme.error.withValues(alpha: .58)),
              ),
            ),
            SizedBox(
              width: actionWidth,
              child: OutlinedButton.icon(
                key: const Key('source-detail-start-reading'),
                onPressed: _isRunning ? null : _startReading,
                icon: const Icon(Icons.menu_book_rounded),
                label: const Text('开始阅读'),
                style: style(tokens.accent, tokens.accent),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _startReading() async {
    if (_isRunning) return;
    Navigator.of(context).pop();
    await widget.onStartReading();
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showBookshelfRemovalConfirmation(context, title: widget.title);
    if (confirmed && mounted) await _run(SourceShelfAction.delete);
  }

  Future<void> _run(SourceShelfAction action) async {
    if (_isRunning) return;
    setState(() => _runningAction = action);
    try {
      await widget.onAction(action);
      if (!mounted) return;
      if (action == SourceShelfAction.toggleCoverBlur) {
        setState(() => _isCoverBlurred = !_isCoverBlurred);
      } else if (action != SourceShelfAction.refresh) {
        Navigator.of(context).pop();
      }
    } on Object catch (error) {
      if (!mounted) return;
      if (action == SourceShelfAction.refresh) {
        await showAppOperationErrorDialog(context, operation: '刷新书籍', error: error, guidance: '书架已保留刷新前的数据。请稍后重试。');
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('操作未能完成，请稍后重试。')));
    } finally {
      if (mounted) setState(() => _runningAction = null);
    }
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
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.2),
              ),
            ),
            if (suffix != null)
              Text(
                suffix!,
                maxLines: 1,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).accent, letterSpacing: -1),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText),
        ),
      ],
    ),
  );
}

List<PluginContentSummary> _recommendationCandidates(Iterable<PluginContentSummary> contents, {required String excludedId}) {
  final seen = <String>{excludedId};
  return contents.where((item) => seen.add(item.id)).toList(growable: false);
}

class _RecommendationsSection extends StatefulWidget {
  const _RecommendationsSection({required this.candidates, required this.onRecommendationRequested});

  final List<PluginContentSummary> candidates;
  final SourceRecommendationRequested? onRecommendationRequested;

  @override
  State<_RecommendationsSection> createState() => _RecommendationsSectionState();
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
    if (oldWidget.candidates.length != widget.candidates.length || !_sameCandidateIds(oldWidget.candidates, widget.candidates)) {
      _reshuffle(useRandom: false);
    }
  }

  void _reshuffle({bool useRandom = true}) {
    _visibleCandidates = List<PluginContentSummary>.of(widget.candidates)..shuffle(math.Random(useRandom ? null : _recommendationSeed()));
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

  bool _sameCandidateIds(List<PluginContentSummary> previous, List<PluginContentSummary> current) {
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
              child: Text('猜你喜欢', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            ),
            Semantics(
              button: true,
              label: '换一换推荐内容',
              child: InkWell(
                key: const Key('source-detail-recommendations-refresh'),
                borderRadius: AppRadii.pill,
                onTap: () => setState(_reshuffle),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.unit, vertical: AppSpacing.unit),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('换一换', style: theme.textTheme.bodyMedium),
                      const SizedBox(width: 4),
                      Icon(Icons.refresh_rounded, size: 18, color: tokens.mutedText),
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
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: const <PointerDeviceKind>{
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
                PointerDeviceKind.trackpad,
              },
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _visibleCandidates
                    .map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: _RecommendationCard(content: item, onPressed: widget.onRecommendationRequested),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.content, required this.onPressed});

  final PluginContentSummary content;
  final SourceRecommendationRequested? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onPressed != null,
    label: '查看${content.title}详情',
    child: InkWell(
      key: ValueKey<String>('source-detail-recommendation-${content.id}'),
      onTap: onPressed == null ? null : () => unawaited(onPressed!(content)),
      borderRadius: AppRadii.discoveryCover,
      child: SizedBox(
        width: 96,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DiscoveryBookCover(
              title: content.title,
              coverBytes: content.coverBytes,
              remoteContentId: content.id,
              coverUrl: content.coverUrl,
              variant: _coverVariant(content.id),
              width: 96,
              height: 140,
            ),
            const SizedBox(height: 7),
            Text(
              content.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 2),
            Text(
              content.author ?? '作者未知',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DetailTag extends StatelessWidget {
  const _DetailTag({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: AppThemeTokens.of(context).mutedSurface, borderRadius: AppRadii.pill),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact, vertical: AppSpacing.unit),
      child: Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText)),
    ),
  );
}

class _ExternalRow extends StatelessWidget {
  const _ExternalRow({required this.label, required this.url, required this.onOpenUrl, this.title, this.subtitle, super.key});
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
                if (title != null) Text(title!, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(subtitle!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppThemeTokens.of(context).mutedText),
        ],
      ),
    ),
  );
}

class _ChapterRow extends StatelessWidget {
  const _ChapterRow({required this.chapter, required this.onRead, required this.onOpenUrl});
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
  required SourceComicChapterRequested? onComicChapterRequested,
  required SourceAudioChapterRequested? onAudioChapterRequested,
  required SourceVideoEpisodeRequested? onVideoEpisodeRequested,
}) async {
  // The detail route is the stable return destination for all four content
  // types. The app host pushes a reader/player above this route, so do not
  // dismiss the detail before invoking its callback. Doing so skips the detail
  // on exit and can also desynchronise discovery's retained category routes.
  if (detail.summary.contentKind == PluginContentKind.audio) {
    final callback = onAudioChapterRequested;
    if (callback == null) {
      throw StateError('An audio-player host has not been registered.');
    }
    // Audio and video entry covers live on detail.summary. Both branches must
    // attach the resolved bytes before entering their host-owned surface.
    final playbackDetail = _withResolvedEntryCover(detail, context);
    await callback(detail: playbackDetail, firstCatalogPage: firstCatalogPage, chapter: chapter);
    return;
  }
  if (detail.summary.contentKind == PluginContentKind.video) {
    final callback = onVideoEpisodeRequested;
    if (callback == null) {
      throw StateError('A video-player host has not been registered.');
    }
    // The detail cover is commonly resolved by DiscoveryBookCover and kept in
    // the route-to-route memory cache. Carry it across the detail-to-player
    // handoff so the player can show the real artwork immediately instead of
    // its fallback.
    final playbackDetail = _withResolvedEntryCover(detail, context);
    await callback(detail: playbackDetail, firstCatalogPage: firstCatalogPage, chapter: chapter);
    return;
  }
  if (detail.summary.contentKind == PluginContentKind.manga) {
    final callback = onComicChapterRequested;
    if (callback == null) {
      await _showChapterContent(context, gateway: gateway, pluginId: detail.pluginId, id: detail.summary.id, chapter: chapter);
      return;
    }
    final entryCoverBytes = _resolvedEntryCoverBytes(context, detail.summary);
    await callback(detail: detail, firstCatalogPage: firstCatalogPage, chapter: chapter, entryCoverBytes: entryCoverBytes);
    return;
  }
  final callback = onTextChapterRequested;
  if (callback == null) {
    await _showChapterContent(context, gateway: gateway, pluginId: detail.pluginId, id: detail.summary.id, chapter: chapter);
    return;
  }
  final entryCoverBytes = _resolvedEntryCoverBytes(context, detail.summary);
  await callback(detail: detail, firstCatalogPage: firstCatalogPage, chapter: chapter, entryCoverBytes: entryCoverBytes);
}

List<int>? _resolvedEntryCoverBytes(BuildContext context, PluginContentSummary content) {
  final supplied = content.coverBytes;
  if (supplied != null && supplied.isNotEmpty) return supplied;
  final coverUrl = content.coverUrl;
  final scope = context.getInheritedWidgetOfExactType<BookCoverSourceScope>();
  if (coverUrl == null || scope == null) return null;
  return BookCoverMemoryCache.peek(scope.requestFor(remoteContentId: content.id, coverUrl: coverUrl));
}

PluginContentDetail _withResolvedEntryCover(PluginContentDetail detail, BuildContext context) {
  return preserveSourceContentCover(detail: detail, resolvedCoverBytes: _resolvedEntryCoverBytes(context, detail.summary));
}

Future<void> _showChapterContent(
  BuildContext context, {
  required SourceContentGateway gateway,
  required String pluginId,
  required String id,
  required PluginChapterSummary chapter,
}) {
  final contentFuture = gateway.getContent(pluginId: pluginId, id: id, chapterId: chapter.id);
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
              Text(content.title ?? chapter.title, style: Theme.of(context).textTheme.titleLarge),
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
  const _DetailFailure({required this.error, this.capability = 'source.getContent.v1', this.hasRetainedData = false, this.onRetry});

  final AppError error;
  final String capability;
  final bool hasRetainedData;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Material(
            key: const Key('source-content-sheet-failure'),
            color: colors.errorContainer,
            shape: RoundedRectangleBorder(
              borderRadius: AppRadii.surface,
              side: BorderSide(color: colors.error),
            ),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.regular),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
                      const SizedBox(width: AppSpacing.compact),
                      Expanded(
                        child: Text('详情加载失败', style: theme.textTheme.titleSmall?.copyWith(color: colors.onErrorContainer)),
                      ),
                      if (onRetry != null) TextButton(key: const Key('source-detail-retry'), onPressed: onRetry, child: const Text('重试')),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.unit),
                  Text(_detailErrorDescription(error), style: theme.textTheme.bodyMedium?.copyWith(color: colors.onErrorContainer)),
                  if (hasRetainedData) ...<Widget>[
                    const SizedBox(height: AppSpacing.unit),
                    Text('已保留列表预览；实时详情和可播放选集尚未加载。', style: theme.textTheme.bodySmall?.copyWith(color: colors.onErrorContainer)),
                  ],
                  const SizedBox(height: AppSpacing.compact),
                  SelectableText(
                    '错误码：${error.code.wireValue}\n失败阶段：$capability\n自动重试：${error.retryable ? '允许' : '不建议'}',
                    key: const Key('source-detail-error-details'),
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.onErrorContainer, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _detailErrorDescription(AppError error) => switch (error.code) {
  AppErrorCode.invalidFormat => '数据源返回的详情或目录格式不符合规范。请更新插件后重试。',
  AppErrorCode.runtimeUnavailable || AppErrorCode.runtimeStartFailed || AppErrorCode.runtimeNotReady => '数据源运行环境当前不可用，请重启应用后重试。',
  AppErrorCode.pluginNotFound || AppErrorCode.pluginDisabled || AppErrorCode.pluginDamaged => '当前数据源不可用，请在数据源管理中检查插件状态。',
  AppErrorCode.timeout || AppErrorCode.rateLimited || AppErrorCode.overloaded => '请求暂时没有完成，请稍后重试。',
  _ => '无法安全加载实时详情，请根据下方稳定错误信息继续定位。',
};

DiscoveryCoverVariant _coverVariant(String id) {
  final checksum = id.codeUnits.fold<int>(0, (value, unit) => value + unit);
  return DiscoveryCoverVariant.values[checksum % DiscoveryCoverVariant.values.length];
}

String _wordCount(int? value) {
  if (value == null) return '—';
  return _formatReadableCount(value);
}

String _wordCountLabel(int? value) => value != null && value >= 10000 ? '万字' : '字数';

String _chapterCount(int? value) => value == null ? '—' : _formatReadableCount(value);

int? _chapterTotal({required int? detailTotal, required int loadedCount}) {
  if (loadedCount > 0) return loadedCount;
  return detailTotal != null && detailTotal > 0 ? detailTotal : null;
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

String _trimDecimal(num value) => value.toStringAsFixed(2).replaceFirst(RegExp(r'\.0+$'), '').replaceFirst(RegExp(r'0+$'), '');
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
  if (page.width != null && page.height != null) '${page.width} × ${page.height}',
].join(' · ');

String? _attributeValue(Iterable<PluginContentAttribute> attributes, String key) {
  for (final attribute in attributes) {
    if (attribute.key == key) return attribute.value;
  }
  return null;
}

Iterable<PluginContentAttribute> _displayAttributes(Iterable<PluginContentAttribute> attributes) => attributes.where(
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
