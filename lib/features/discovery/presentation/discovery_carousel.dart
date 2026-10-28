part of 'discovery_page.dart';

/// Hero recommendation carousel, its autoplay lifecycle, cards, and indicator.
class DiscoveryCarouselBooks extends StatefulWidget {
  const DiscoveryCarouselBooks({required this.books, required this.onBookPressed, super.key});

  final List<DiscoveryHeroViewData> books;
  final ValueChanged<DiscoveryHeroViewData> onBookPressed;

  @override
  State<DiscoveryCarouselBooks> createState() => _DiscoveryCarouselBooksState();
}

class _DiscoveryCarouselBooksState extends State<DiscoveryCarouselBooks> with WidgetsBindingObserver {
  late final PageController _pageController;
  Timer? _autoPlayTimer;
  ModalRoute<dynamic>? _route;
  int _currentIndex = 0;
  bool _appResumed = true;
  bool _routeCurrent = true;
  bool _tickerEnabled = true;
  bool _motionEnabled = true;
  bool _userScrolling = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    final AppLifecycleState? lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appResumed = lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<dynamic>? nextRoute = ModalRoute.of(context);
    if (!identical(nextRoute, _route)) {
      _route?.animation?.removeListener(_handleRouteChanged);
      _route?.secondaryAnimation?.removeListener(_handleRouteChanged);
      _route = nextRoute;
      _route?.animation?.addListener(_handleRouteChanged);
      _route?.secondaryAnimation?.addListener(_handleRouteChanged);
    }
    _routeCurrent = _route?.isCurrent ?? true;
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _motionEnabled = !MediaQuery.disableAnimationsOf(context);
    _syncAutoPlay();
  }

  @override
  void didUpdateWidget(covariant DiscoveryCarouselBooks oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.books.length != widget.books.length) {
      _currentIndex = 0;
      if (_pageController.hasClients) _pageController.jumpToPage(0);
      _syncAutoPlay();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _syncAutoPlay();
  }

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _route?.animation?.removeListener(_handleRouteChanged);
    _route?.secondaryAnimation?.removeListener(_handleRouteChanged);
    _pageController.dispose();
    super.dispose();
  }

  bool get _canAutoPlay => widget.books.length > 1 && _appResumed && _routeCurrent && _tickerEnabled && _motionEnabled && !_userScrolling;

  void _handleRouteChanged() {
    final bool isCurrent = _route?.isCurrent ?? true;
    if (_routeCurrent == isCurrent) return;
    _routeCurrent = isCurrent;
    _syncAutoPlay();
  }

  void _syncAutoPlay() {
    if (!_canAutoPlay) {
      _autoPlayTimer?.cancel();
      _autoPlayTimer = null;
      return;
    }
    if (_autoPlayTimer != null) return;
    _autoPlayTimer = Timer(const Duration(seconds: 4), _advancePage);
  }

  void _advancePage() {
    _autoPlayTimer = null;
    if (!mounted || !_canAutoPlay || !_pageController.hasClients) return;
    final int nextIndex = (_currentIndex + 1) % widget.books.length;
    _pageController.animateToPage(nextIndex, duration: const Duration(milliseconds: 360), curve: Curves.easeOut);
    _syncAutoPlay();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification && notification.dragDetails != null) {
      _userScrolling = true;
      _syncAutoPlay();
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _userScrolling = false;
      _syncAutoPlay();
    }
    return false;
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
                NotificationListener<ScrollNotification>(
                  onNotification: _handleScrollNotification,
                  child: ScrollConfiguration(
                    behavior: discoveryDragScrollBehavior(context),
                    child: PageView.builder(
                      controller: _pageController,
                      itemCount: widget.books.length,
                      onPageChanged: (index) {
                        if (_currentIndex != index) setState(() => _currentIndex = index);
                      },
                      itemBuilder: (context, index) {
                        final book = widget.books[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1),
                          child: DiscoveryCarouselHeroCard(data: book, onPressed: () => widget.onBookPressed(book)),
                        );
                      },
                    ),
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
                        contentKind: data.contentKind,
                        coverBytes: data.coverBytes,
                        remoteContentId: data.remoteContentId,
                        coverUrl: data.coverUrl,
                        variant: data.coverVariant,
                        presentation: discoveryCoverPresentation(data.coverOrientation),
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
