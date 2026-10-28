part of 'source_content_detail_sheet.dart';

/// Related content cards and recommendation interaction.
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
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: enabled,
      enabled: enabled,
      label: '查看${content.title}详情',
      child: Opacity(
        opacity: enabled ? 1 : .56,
        child: InkWell(
          key: ValueKey<String>('source-detail-recommendation-${content.id}'),
          onTap: enabled ? () => unawaited(onPressed!(content)) : null,
          borderRadius: AppRadii.discoveryCover,
          child: SizedBox(
            width: 96,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                DiscoveryBookCover(
                  title: content.title,
                  contentKind: content.contentKind,
                  coverBytes: content.coverBytes,
                  remoteContentId: content.id,
                  coverUrl: content.coverUrl,
                  variant: _coverVariant(content.id),
                  presentation: discoveryCoverPresentation(content.coverOrientation),
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
      ),
    );
  }
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
