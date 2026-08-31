/// Source-detail catalog presentation.
///
/// Responsibilities:
/// - Preserve source-owned neutral media groups instead of flattening them.
/// - Present grouped video episodes with a group switcher and bounded grid.
/// - Retain the existing row catalog for content without groups.
///
/// Notes:
/// - Group titles are source data and must not be rewritten as seasons or lines.
/// - Selecting an episode forwards the complete catalog so the player receives
///   the same group identities shown on the detail page.
part of 'source_content_detail_sheet.dart';

class _DetailCatalogSection extends StatelessWidget {
  const _DetailCatalogSection({
    required this.catalog,
    required this.contentKind,
    required this.isRefreshing,
    required this.chapterTotal,
    required this.visibleChapterCount,
    required this.onLoadMore,
    required this.onChapterSelected,
    required this.onOpenUrl,
  });

  final PluginChaptersResult catalog;
  final PluginContentKind contentKind;
  final bool isRefreshing;
  final int? chapterTotal;
  final int visibleChapterCount;
  final VoidCallback? onLoadMore;
  final ValueChanged<PluginChapterSummary> onChapterSelected;
  final Future<void> Function(BuildContext context, Uri? url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final theme = Theme.of(context);
    final hasGroups = catalog.groups.isNotEmpty;
    final isVideo = contentKind == PluginContentKind.video;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: AppSpacing.section),
        Divider(color: tokens.divider, height: 1),
        const SizedBox(height: AppSpacing.comfortable),
        Text(isVideo ? '选集播放' : '目录', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        if (isRefreshing && catalog.items.isEmpty) ...<Widget>[
          const SizedBox(height: AppSpacing.compact),
          const _DetailShimmerBlock(height: 12, widthFactor: .22),
          const SizedBox(height: AppSpacing.comfortable),
          const _DetailLoadingChapterRows(),
        ] else ...<Widget>[
          const SizedBox(height: AppSpacing.unit),
          Text(
            hasGroups
                ? '共 ${catalog.items.length} 集 · ${catalog.groups.length} 个分组'
                : chapterTotal == null
                ? '暂无章节'
                : '共 $chapterTotal ${isVideo ? '集' : '章'}',
            key: const Key('source-detail-catalog-summary'),
            style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
          ),
          if (hasGroups)
            _GroupedDetailCatalog(groups: catalog.groups, onEpisodeSelected: onChapterSelected)
          else ...<Widget>[
            for (final chapter in catalog.items.take(visibleChapterCount))
              _ChapterRow(chapter: chapter, onRead: () => onChapterSelected(chapter), onOpenUrl: onOpenUrl),
            if (onLoadMore != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.regular),
                child: OutlinedButton(
                  key: const Key('source-detail-load-more-chapters'),
                  onPressed: onLoadMore,
                  child: const Text('加载更多章节'),
                ),
              ),
          ],
        ],
      ],
    );
  }
}

class _GroupedDetailCatalog extends StatefulWidget {
  const _GroupedDetailCatalog({required this.groups, required this.onEpisodeSelected});

  final List<PluginMediaGroup> groups;
  final ValueChanged<PluginChapterSummary> onEpisodeSelected;

  @override
  State<_GroupedDetailCatalog> createState() => _GroupedDetailCatalogState();
}

class _GroupedDetailCatalogState extends State<_GroupedDetailCatalog> {
  static const _pageSize = 24;

  late String? _selectedGroupId = widget.groups.firstOrNull?.id;
  var _visibleEpisodeCount = _pageSize;

  @override
  void didUpdateWidget(covariant _GroupedDetailCatalog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.groups.any((group) => group.id == _selectedGroupId)) return;
    _selectedGroupId = widget.groups.firstOrNull?.id;
    _visibleEpisodeCount = _pageSize;
  }

  PluginMediaGroup? get _selectedGroup {
    for (final group in widget.groups) {
      if (group.id == _selectedGroupId) return group;
    }
    return null;
  }

  void _selectGroup(String groupId) {
    if (groupId == _selectedGroupId) return;
    setState(() {
      _selectedGroupId = groupId;
      _visibleEpisodeCount = _pageSize;
    });
  }

  @override
  Widget build(BuildContext context) {
    final group = _selectedGroup;
    final episodes = group?.episodes ?? const <PluginChapterSummary>[];
    final visibleEpisodes = episodes.take(_visibleEpisodeCount).toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: AppSpacing.regular),
        SingleChildScrollView(
          key: const Key('source-detail-group-tabs'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (final item in widget.groups)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.compact),
                  child: _DetailGroupTab(group: item, selected: item.id == _selectedGroupId, onTap: () => _selectGroup(item.id)),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.regular),
        if (group == null || episodes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.section),
            child: Text(
              '该分组暂无可播放选集',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppThemeTokens.of(context).mutedText),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = switch (constraints.maxWidth) {
                < 360 => 2,
                < 680 => 3,
                < 980 => 4,
                _ => 6,
              };
              return GridView.builder(
                key: ValueKey<String>('source-detail-episode-grid-${group.id}'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: visibleEpisodes.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: AppSpacing.compact,
                  crossAxisSpacing: AppSpacing.compact,
                  childAspectRatio: 2.45,
                ),
                itemBuilder: (context, index) {
                  final episode = visibleEpisodes[index];
                  return OutlinedButton(
                    key: ValueKey<String>('source-detail-episode-${group.id}-${episode.id}'),
                    onPressed: () => widget.onEpisodeSelected(episode),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(episode.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  );
                },
              );
            },
          ),
        if (episodes.length > visibleEpisodes.length)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.regular),
            child: OutlinedButton(
              key: const Key('source-detail-load-more-group-episodes'),
              onPressed: () => setState(() => _visibleEpisodeCount = math.min(_visibleEpisodeCount + _pageSize, episodes.length)),
              child: const Text('显示更多选集'),
            ),
          ),
      ],
    );
  }
}

class _DetailGroupTab extends StatelessWidget {
  const _DetailGroupTab({required this.group, required this.selected, required this.onTap});

  final PluginMediaGroup group;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '${group.title}，${group.episodes.length} 集',
      child: Material(
        key: ValueKey<String>('source-detail-group-${group.id}'),
        color: selected ? tokens.accentSoft : tokens.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: selected ? tokens.accent : tokens.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  group.title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: selected ? tokens.accent : theme.colorScheme.onSurface,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                const SizedBox(width: AppSpacing.compact),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected ? tokens.accent.withValues(alpha: .14) : tokens.mutedSurface,
                    borderRadius: AppRadii.pill,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    child: Text(
                      '${group.episodes.length}',
                      style: theme.textTheme.labelSmall?.copyWith(color: selected ? tokens.accent : tokens.mutedText),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
