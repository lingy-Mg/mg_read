part of 'discovery_page.dart';

class DiscoveryPopularBooks extends StatelessWidget {
  const DiscoveryPopularBooks({required this.books, required this.onBookPressed, super.key});

  final List<DiscoveryBookViewData> books;
  final ValueChanged<DiscoveryBookViewData> onBookPressed;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      key: const Key('discovery-popular-books'),
      constraints: const BoxConstraints(minHeight: 120),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: books
            .take(5)
            .map((DiscoveryBookViewData book) => DiscoveryPopularBook(data: book, onPressed: () => onBookPressed(book)))
            .toList(growable: false),
      ),
    );
  }
}

class DiscoveryCarouselBooks extends StatefulWidget {
  const DiscoveryCarouselBooks({required this.books, required this.onBookPressed, super.key});

  final List<DiscoveryHeroViewData> books;
  final ValueChanged<DiscoveryHeroViewData> onBookPressed;

  @override
  State<DiscoveryCarouselBooks> createState() => _DiscoveryCarouselBooksState();
}

class _DiscoveryCarouselBooksState extends State<DiscoveryCarouselBooks> {
  late final PageController _pageController;
  Timer? _autoPlayTimer;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _startAutoPlay();
  }

  @override
  void didUpdateWidget(covariant DiscoveryCarouselBooks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.books.length != widget.books.length) {
      _currentIndex = 0;
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      _autoPlayTimer?.cancel();
      _startAutoPlay();
    }
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startAutoPlay() {
    if (widget.books.length < 2) return;
    _autoPlayTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_pageController.hasClients) return;
      setState(() {
        _currentIndex = (_currentIndex + 1) % widget.books.length;
      });
      _pageController.animateToPage(_currentIndex, duration: const Duration(milliseconds: 360), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.books.isEmpty) return const SizedBox.shrink();
    return Semantics(
      container: true,
      label: '重磅推荐轮播，共 ${widget.books.length} 本',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 360;
          final verticalPadding = compact ? 12.0 : 14.0;
          final coverWidth = compact ? 84.0 : (constraints.maxWidth * 0.23).clamp(88.0, 112.0);
          final coverHeight = coverWidth * 1.42;
          // The cover is a fixed-size child. Keep the PageView's tight height
          // large enough for it after card padding, including on wide windows
          // where the cover width reaches its 112px cap.
          final height = math.max(compact ? 156.0 : 184.0, coverHeight + verticalPadding * 2);
          return SizedBox(
            key: const Key('discovery-carousel-books'),
            height: height,
            child: Stack(
              children: <Widget>[
                ScrollConfiguration(
                  behavior: discoveryDragScrollBehavior(context),
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: widget.books.length,
                    onPageChanged: (index) => setState(() {
                      _currentIndex = index;
                    }),
                    itemBuilder: (context, index) {
                      final book = widget.books[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: DiscoveryCarouselHeroCard(data: book, onPressed: () => widget.onBookPressed(book)),
                      );
                    },
                  ),
                ),
                if (widget.books.length > 1)
                  Positioned(
                    right: 18,
                    bottom: 10,
                    child: _DiscoveryCarouselIndicator(count: widget.books.length, activeIndex: _currentIndex),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class DiscoveryCarouselHeroCard extends StatelessWidget {
  const DiscoveryCarouselHeroCard({required this.data, required this.onPressed, super.key});

  final DiscoveryHeroViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 360;
        final coverWidth = compact ? 84.0 : (constraints.maxWidth * 0.23).clamp(88.0, 112.0);
        final coverHeight = coverWidth * 1.42;
        return Semantics(
          button: true,
          label: '打开书籍：${data.title}',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('discovery-carousel-hero-card'),
              onTap: onPressed,
              borderRadius: AppRadii.discoveryHero,
              child: Ink(
                decoration: BoxDecoration(
                  borderRadius: AppRadii.discoveryHero,
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: <Color>[tokens.featureSurface, tokens.accentSoft.withValues(alpha: 0.72)],
                  ),
                  border: Border.all(color: tokens.accent.withValues(alpha: 0.15)),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 16, vertical: compact ? 12 : 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      DiscoveryBookCover(
                        title: data.title,
                        coverBytes: data.coverBytes,
                        remoteContentId: data.remoteContentId,
                        coverUrl: data.coverUrl,
                        variant: data.coverVariant,
                        width: coverWidth,
                        height: coverHeight,
                      ),
                      SizedBox(width: compact ? 12 : 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    data.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
                                  ),
                                ),
                                if (data.category != null) ...<Widget>[const SizedBox(width: 8), DiscoveryTag(label: data.category!)],
                              ],
                            ),
                            if (data.metadata != null) ...<Widget>[
                              const SizedBox(height: 6),
                              Text(
                                data.metadata!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                              ),
                            ],
                            if (data.description != null) ...<Widget>[
                              const SizedBox(height: 8),
                              Flexible(
                                child: Text(
                                  data.description!,
                                  maxLines: compact ? 2 : 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurface.withValues(alpha: 0.78),
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            ],
                            if (data.heat != null) ...<Widget>[
                              const SizedBox(height: 8),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(Icons.local_fire_department_rounded, size: 16, color: tokens.notification),
                                  const SizedBox(width: 4),
                                  Text(
                                    data.heat!,
                                    style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DiscoveryCarouselIndicator extends StatelessWidget {
  const _DiscoveryCarouselIndicator({required this.count, required this.activeIndex});

  final int count;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: tokens.surface.withValues(alpha: 0.78), borderRadius: AppRadii.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var index = 0; index < count; index++) ...<Widget>[
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: index == activeIndex ? 12 : 5,
                height: 5,
                decoration: BoxDecoration(
                  color: index == activeIndex ? tokens.accent : tokens.mutedText.withValues(alpha: 0.34),
                  borderRadius: AppRadii.pill,
                ),
              ),
              if (index != count - 1) const SizedBox(width: 4),
            ],
          ],
        ),
      ),
    );
  }
}

class DiscoveryPopularBook extends StatelessWidget {
  const DiscoveryPopularBook({required this.data, required this.onPressed, super.key});

  final DiscoveryBookViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: data.author == null ? '打开书籍：${data.title}' : '打开书籍：${data.title}，${data.author}',
      child: InkResponse(
        onTap: onPressed,
        radius: AppSpacing.minimumTouchTarget / 2,
        child: SizedBox(
          width: AppSpacing.discoveryPopularItemWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              DiscoveryBookCover(
                title: data.title,
                variant: data.coverVariant,
                width: AppSpacing.discoveryPopularCoverWidth,
                height: AppSpacing.discoveryPopularCoverHeight,
              ),
              const SizedBox(height: 4),
              Text(
                data.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w400,
                  height: 1.2,
                  letterSpacing: 0,
                ),
              ),
              if (data.author != null) ...<Widget>[
                const SizedBox(height: 1),
                Text(
                  data.author!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.mutedText,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DiscoveryRankingBoard extends StatelessWidget {
  const DiscoveryRankingBoard({required this.title, required this.books, required this.onPressed, required this.onMorePressed, super.key});

  final String title;
  final List<DiscoveryRankedBookViewData> books;
  final ValueChanged<DiscoveryRankedBookViewData> onPressed;
  final VoidCallback onMorePressed;

  @override
  Widget build(BuildContext context) {
    return DiscoveryBoardSurface(
      key: const Key('discovery-ranking-board'),
      child: Column(
        children: <Widget>[
          DiscoveryBoardHeader(title: title, onPressed: onMorePressed),
          const SizedBox(height: 4),
          for (final DiscoveryRankedBookViewData book in books.take(5))
            Expanded(
              child: DiscoveryRankingRow(data: book, onPressed: () => onPressed(book)),
            ),
        ],
      ),
    );
  }
}

class DiscoveryRankingRow extends StatelessWidget {
  const DiscoveryRankingRow({required this.data, required this.onPressed, super.key});

  final DiscoveryRankedBookViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Color rankColor = switch (data.rank) {
      1 => tokens.notification,
      2 || 3 => tokens.accent,
      _ => tokens.mutedText,
    };
    return Semantics(
      button: true,
      label: <String>[
        if (data.rank != null) '第 ${data.rank} 名',
        data.title,
        if (data.author != null) data.author!,
        if (data.heat != null) data.heat!,
      ].join('，'),
      child: InkResponse(
        onTap: onPressed,
        radius: AppSpacing.minimumTouchTarget / 2,
        child: Row(
          children: <Widget>[
            DiscoveryBookCover(
              title: data.title,
              variant: data.coverVariant,
              width: AppSpacing.discoveryRankCoverWidth,
              height: AppSpacing.discoveryRankCoverHeight,
            ),
            const SizedBox(width: 6),
            if (data.rank != null) ...<Widget>[
              SizedBox(
                width: 12,
                child: Text(
                  '${data.rank}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: rankColor, fontWeight: FontWeight.w600, height: 1.1, letterSpacing: 0),
                ),
              ),
              const SizedBox(width: 3),
            ],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    data.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                      letterSpacing: 0,
                    ),
                  ),
                  if (data.author != null) ...<Widget>[
                    const SizedBox(height: 1),
                    Text(
                      data.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tokens.mutedText,
                        fontWeight: FontWeight.w400,
                        height: 1.1,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (data.heat != null) ...<Widget>[
              const SizedBox(width: 2),
              Icon(Icons.local_fire_department_rounded, size: 10, color: tokens.notification),
              const SizedBox(width: 1),
              Text(
                data.heat!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.mutedText,
                  fontWeight: FontWeight.w400,
                  height: 1.1,
                  letterSpacing: 0,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class DiscoveryCategoryBoard extends StatelessWidget {
  const DiscoveryCategoryBoard({required this.title, required this.categories, required this.onPressed, this.onCategoryPressed, super.key});

  final String title;
  final List<DiscoveryCategoryViewData> categories;
  final VoidCallback onPressed;
  final ValueChanged<DiscoveryCategoryViewData>? onCategoryPressed;

  @override
  Widget build(BuildContext context) {
    final List<DiscoveryCategoryViewData> visible = categories.take(8).toList(growable: false);
    return DiscoveryBoardSurface(
      key: const Key('discovery-category-board'),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columnCount = discoveryAdaptiveColumnCount(constraints.maxWidth, visible.length);
          final double gap = AppSpacing.discoveryCategoryTileGap;
          final double tileWidth = (constraints.maxWidth - gap * (columnCount - 1)) / columnCount;
          return Column(
            children: <Widget>[
              DiscoveryBoardHeader(title: title, onPressed: onPressed),
              const SizedBox(height: 6),
              Wrap(
                spacing: gap,
                runSpacing: gap,
                children: visible
                    .map(
                      (category) => SizedBox(
                        width: tileWidth,
                        child: DiscoveryCategoryTile(
                          key: ValueKey<String>('discovery-category-${category.target ?? category.title}'),
                          data: category,
                          onPressed: () => _handleCategory(category),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
          );
        },
      ),
    );
  }

  void _handleCategory(DiscoveryCategoryViewData category) {
    final callback = onCategoryPressed;
    if (callback == null) {
      onPressed();
      return;
    }
    callback(category);
  }
}

/// Returns the number of equal category controls that fit the available width.
///
/// Two columns remain the compact reference layout. Wider boards gain columns
/// only when each control can retain the same minimum readable width.
int discoveryAdaptiveColumnCount(double maxWidth, int itemCount) {
  if (itemCount <= 0) return 1;
  final int estimated =
      ((maxWidth + AppSpacing.discoveryCategoryTileGap) / (AppSpacing.discoveryCategoryTileMinWidth + AppSpacing.discoveryCategoryTileGap))
          .floor();
  return math.max(2, math.min(itemCount, estimated));
}

class DiscoveryCategoryTile extends StatelessWidget {
  const DiscoveryCategoryTile({required this.data, required this.onPressed, super.key});

  final DiscoveryCategoryViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Color iconColor = _categoryColor(data.icon, tokens);
    return Semantics(
      button: true,
      label: data.count == null ? data.title : '${data.title}，${data.count}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.discoveryTile,
          child: Ink(
            height: AppSpacing.discoveryCategoryTileHeight,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(color: tokens.surface.withValues(alpha: 0.82), borderRadius: AppRadii.discoveryTile),
            child: Row(
              children: <Widget>[
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: theme.brightness == Brightness.dark ? 0.24 : 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(_categoryIcon(data.icon), size: 14, color: iconColor),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        data.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w500,
                          height: 1.1,
                          letterSpacing: 0,
                        ),
                      ),
                      if (data.count != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          data.count!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: tokens.mutedText,
                            fontWeight: FontWeight.w400,
                            height: 1,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _categoryIcon(DiscoveryCategoryIcon icon) {
    return switch (icon) {
      DiscoveryCategoryIcon.fantasy => Icons.auto_awesome_rounded,
      DiscoveryCategoryIcon.adventure => Icons.gavel_rounded,
      DiscoveryCategoryIcon.martialArts => Icons.sports_martial_arts_rounded,
      DiscoveryCategoryIcon.xianxia => Icons.colorize_rounded,
      DiscoveryCategoryIcon.urban => Icons.apartment_rounded,
      DiscoveryCategoryIcon.history => Icons.fort_rounded,
      DiscoveryCategoryIcon.game => Icons.stadium_rounded,
      DiscoveryCategoryIcon.sciFi => Icons.rocket_launch_rounded,
    };
  }

  Color _categoryColor(DiscoveryCategoryIcon icon, AppThemeTokens tokens) {
    return switch (icon) {
      DiscoveryCategoryIcon.urban || DiscoveryCategoryIcon.game || DiscoveryCategoryIcon.sciFi => tokens.coverOceanEnd,
      DiscoveryCategoryIcon.history => tokens.coverEmberEnd,
      _ => tokens.warning,
    };
  }
}

class DiscoveryBoardSurface extends StatelessWidget {
  const DiscoveryBoardSurface({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.mutedSurface,
        borderRadius: AppRadii.discoveryPanel,
        border: Border.all(color: tokens.divider.withValues(alpha: 0.72), width: 0.6),
      ),
      child: Padding(padding: const EdgeInsets.fromLTRB(8, 9, 8, 8), child: child),
    );
  }
}

class DiscoveryBoardHeader extends StatelessWidget {
  const DiscoveryBoardHeader({required this.title, required this.onPressed, super.key});

  final String title;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      height: 22,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                  height: 1.15,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          InkResponse(
            onTap: onPressed,
            radius: AppSpacing.minimumTouchTarget / 2,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '更多',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.mutedText,
                    fontWeight: FontWeight.w400,
                    height: 1.1,
                    letterSpacing: 0,
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 14, color: tokens.mutedText),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DiscoveryEditorsChoiceCard extends StatelessWidget {
  const DiscoveryEditorsChoiceCard({required this.data, required this.onPressed, super.key});

  final DiscoveryEditorsChoiceViewData data;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      button: true,
      label: '打开书籍：${data.title}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('discovery-editors-choice'),
          onTap: onPressed,
          borderRadius: AppRadii.discoveryPanel,
          child: Ink(
            height: AppSpacing.discoveryEditorCardHeight,
            decoration: BoxDecoration(color: tokens.mutedSurface, borderRadius: AppRadii.discoveryPanel),
            child: ClipRRect(
              borderRadius: AppRadii.discoveryPanel,
              child: Row(
                children: <Widget>[
                  DiscoveryBookCover(
                    title: data.title,
                    variant: data.coverVariant,
                    width: AppSpacing.discoveryEditorCoverWidth,
                    height: AppSpacing.discoveryEditorCoverHeight,
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 9, 7),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  data.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurface,
                                    fontWeight: FontWeight.w600,
                                    height: 1.15,
                                    letterSpacing: 0,
                                  ),
                                ),
                              ),
                              if (data.category != null) ...<Widget>[const SizedBox(width: 7), DiscoveryTag(label: data.category!)],
                            ],
                          ),
                          if (data.description != null) ...<Widget>[
                            const SizedBox(height: 4),
                            Text(
                              data.description!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(alpha: 0.76),
                                fontWeight: FontWeight.w400,
                                height: 1.28,
                                letterSpacing: 0,
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (data.metadata != null)
                            Text(
                              data.metadata!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: tokens.mutedText,
                                fontWeight: FontWeight.w400,
                                height: 1.1,
                                letterSpacing: 0,
                              ),
                            ),
                        ],
                      ),
                    ),
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
