part of 'source_content_detail_sheet.dart';

class _DetailHeader extends StatelessWidget {
  const _DetailHeader();

  @override
  Widget build(BuildContext context) => DiscoveryTopBar(
    title: '详情',
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
    trailingActions: <Widget>[DiscoveryTopAction(tooltip: '更多', icon: Icons.more_vert_rounded, onPressed: () {})],
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
          _Stat(value: firstValue, label: firstLabel, suffix: rating == null ? null : '★★★★★'),
          _Stat(value: _wordCount(content.wordCount), label: _wordCountLabel(content.wordCount)),
          _Stat(value: _chapterCount(content.chapterCount), label: _statusLabel(content.status)),
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
  const _RecommendationsSection({required this.candidates});

  final List<PluginContentSummary> candidates;

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
  Widget build(BuildContext context) => SizedBox(
    width: 96,
    child: Column(
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
        Text(content.title, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: Theme.of(context).textTheme.bodyMedium),
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
}) async {
  final callback = onTextChapterRequested;
  if (callback == null) {
    await _showChapterContent(context, gateway: gateway, pluginId: detail.pluginId, id: detail.summary.id, chapter: chapter);
    return;
  }
  Navigator.of(context).pop();
  await callback(detail: detail, firstCatalogPage: firstCatalogPage, chapter: chapter);
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
  const _DetailFailure({required this.error});
  final AppError error;
  @override
  Widget build(BuildContext context) =>
      Center(child: Text('无法加载内容（${error.code.wireValue}）', key: const Key('source-content-sheet-failure')));
}

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
