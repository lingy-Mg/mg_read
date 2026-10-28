part of 'source_content_detail_sheet.dart';

/// Detail heading, cover, metadata, and statistics presentation.
class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.isModalSheet, required this.readerOwnedTheme});

  final bool isModalSheet;
  final bool readerOwnedTheme;

  @override
  Widget build(BuildContext context) => DiscoveryTopBar(
    title: isModalSheet ? '书籍详情' : '详情',
    sourceName: '当前来源',
    onSourcePressed: () {},
    onSearchPressed: () {},
    onToggleTheme: () => AppThemeModeScope.of(context).onToggleTheme(Theme.of(context).brightness),
    onBackPressed: () => Navigator.of(context).pop(),
    backButtonKey: const Key('source-detail-back'),
    barKey: const Key('source-detail-header'),
    titleKey: const Key('source-detail-header-title'),
    showSourceSelector: false,
    showSearchAction: false,
    showThemeToggle: !readerOwnedTheme,
    trailingActions: const <Widget>[],
  );
}

/// Routes to one of three independent detail-header compositions. The source's
/// cover direction selects the composition; media kind does not participate.
class _DetailSummaryHeader extends StatelessWidget {
  const _DetailSummaryHeader({required this.content, required this.labels, required this.onCoverTap});

  final PluginContentSummary content;
  final List<String> labels;
  final VoidCallback? onCoverTap;

  @override
  Widget build(BuildContext context) => switch (content.coverOrientation) {
    PluginCoverOrientation.portrait => _PortraitDetailSummaryHeader(content: content, labels: labels, onCoverTap: onCoverTap),
    PluginCoverOrientation.square => _SquareDetailSummaryHeader(content: content, labels: labels, onCoverTap: onCoverTap),
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
      _DetailCoverLink(content: content, height: 174, presentation: DiscoveryCoverPresentation.portrait, onTap: onCoverTap),
      const SizedBox(width: AppSpacing.regular),
      Expanded(
        child: _DetailHeaderMetadata(content: content, labels: labels),
      ),
    ],
  );
}

/// Square artwork keeps its full album-like composition beside metadata.
class _SquareDetailSummaryHeader extends StatelessWidget {
  const _SquareDetailSummaryHeader({required this.content, required this.labels, required this.onCoverTap});

  final PluginContentSummary content;
  final List<String> labels;
  final VoidCallback? onCoverTap;

  @override
  Widget build(BuildContext context) => Row(
    key: const Key('source-detail-square-header'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _DetailCoverLink(content: content, width: 144, height: 144, presentation: DiscoveryCoverPresentation.square, onTap: onCoverTap),
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
  const _DetailCoverLink({required this.content, this.width, required this.height, required this.presentation, required this.onTap});

  final PluginContentSummary content;
  final double? width;
  final double height;
  final DiscoveryCoverPresentation presentation;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: enabled,
      enabled: enabled,
      label: '打开封面链接',
      child: InkWell(
        key: const Key('source-detail-open-cover-url'),
        onTap: onTap,
        borderRadius: presentation == DiscoveryCoverPresentation.landscape ? BorderRadius.circular(10) : AppRadii.discoveryCover,
        child: DiscoveryBookCover(
          key: const Key('source-detail-cover'),
          title: content.title,
          contentKind: content.contentKind,
          coverBytes: content.coverBytes,
          remoteContentId: content.id,
          coverUrl: content.coverUrl,
          variant: _coverVariant(content.id),
          width: width,
          height: height,
          presentation: presentation,
        ),
      ),
    );
  }
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

/// One labeled count used in the detail statistics row.

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
