/// 数据源内容详情页的加载骨架。
///
/// 职责：
/// - 在详情或目录等待刷新时保持稳定的页面结构。
/// - 以低干扰闪亮效果标记尚未取得的数据。
///
/// 注意：
/// - 动画遵从系统的减少动态效果设置，并在不可见时停止。
/// - 不承载数据源请求或阅读动作。
///
/// TODO:
/// - 无。
part of 'source_content_detail_sheet.dart';

class _SourceDetailLoadingView extends StatelessWidget {
  const _SourceDetailLoadingView({required this.initialContent, required this.shelfState, this.onShelfAction, this.onStartReading});

  final PluginContentSummary? initialContent;
  final SourceDetailShelfState shelfState;
  final SourceShelfActionRequested? onShelfAction;
  final SourceStartReadingRequested? onStartReading;

  @override
  Widget build(BuildContext context) {
    final content = initialContent;
    final tokens = AppThemeTokens.of(context);
    final theme = Theme.of(context);
    return ListView(
      key: const Key('source-content-detail-sheet'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.discoveryPagePadding,
        AppSpacing.regular,
        AppSpacing.discoveryPagePadding,
        AppSpacing.page,
      ),
      children: <Widget>[
        Semantics(
          key: const Key('source-detail-loading'),
          label: '正在加载内容详情与目录',
          liveRegion: true,
          child: ExcludeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const _DetailShimmerBlock(width: 112, height: 174, borderRadius: AppRadii.discoveryCover),
                const SizedBox(width: AppSpacing.comfortable),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (content == null) ...<Widget>[
                        const _DetailShimmerBlock(height: 24, widthFactor: .8),
                        const SizedBox(height: AppSpacing.regular),
                        const _DetailShimmerBlock(height: 16, widthFactor: .46),
                      ] else ...<Widget>[
                        Text(
                          content.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
                        ),
                        const SizedBox(height: AppSpacing.regular),
                        Text(
                          content.author ?? '作者未知',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(color: tokens.mutedText),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.regular),
                      const _DetailShimmerBlock(height: 18, widthFactor: .68),
                      const SizedBox(height: AppSpacing.regular),
                      Divider(color: tokens.divider, height: 1),
                      const SizedBox(height: AppSpacing.regular),
                      const _DetailShimmerBlock(height: 32),
                      const SizedBox(height: AppSpacing.regular),
                      Divider(color: tokens.divider, height: 1),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.section),
        if (shelfState != SourceDetailShelfState.canAdd && onShelfAction != null && onStartReading != null)
          _ShelfActionBar(shelfState: shelfState, onAction: onShelfAction!, onStartReading: onStartReading!)
        else
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.library_add_outlined),
                  label: const Text('加入书架'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    disabledForegroundColor: tokens.mutedText,
                    side: BorderSide(color: tokens.divider),
                    shape: RoundedRectangleBorder(borderRadius: AppRadii.control),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: FilledButton(
                  key: const Key('source-detail-start-reading'),
                  onPressed: null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    disabledBackgroundColor: tokens.accent,
                    disabledForegroundColor: tokens.surface,
                    shape: RoundedRectangleBorder(borderRadius: AppRadii.control),
                  ),
                  child: const _DetailLoadingButtonLabel(),
                ),
              ),
            ],
          ),
        const SizedBox(height: AppSpacing.section),
        Divider(color: tokens.divider, height: 1),
        const SizedBox(height: AppSpacing.comfortable),
        Text('简介', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.compact),
        const _DetailShimmerBlock(height: 68),
        const SizedBox(height: AppSpacing.section),
        Divider(color: tokens.divider, height: 1),
        const SizedBox(height: AppSpacing.comfortable),
        Text('目录', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.compact),
        const _DetailShimmerBlock(height: 12, widthFactor: .22),
        const SizedBox(height: AppSpacing.comfortable),
        const _DetailLoadingChapterRows(),
      ],
    );
  }
}

class _DetailLoadingButtonLabel extends StatelessWidget {
  const _DetailLoadingButtonLabel();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 20,
    child: Center(child: _DetailShimmerText(text: '加载中')),
  );
}

class _DetailLoadingChapterRows extends StatelessWidget {
  const _DetailLoadingChapterRows();

  @override
  Widget build(BuildContext context) => const Column(
    children: <Widget>[
      _DetailShimmerBlock(height: 20, widthFactor: .84),
      SizedBox(height: AppSpacing.comfortable),
      _DetailShimmerBlock(height: 20, widthFactor: .66),
      SizedBox(height: AppSpacing.comfortable),
      _DetailShimmerBlock(height: 20, widthFactor: .76),
    ],
  );
}

class _DetailShimmerText extends StatefulWidget {
  const _DetailShimmerText({required this.text});

  final String text;

  @override
  State<_DetailShimmerText> createState() => _DetailShimmerTextState();
}

class _DetailShimmerTextState extends State<_DetailShimmerText> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppMotion.loadingShimmer);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.disablesAnimations(context) || !TickerMode.valuesOf(context).enabled) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, child) => ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (bounds) => _shimmerGradient(
        context,
        phase: _controller.value,
        base: AppThemeTokens.of(context).surface.withValues(alpha: .68),
      ).createShader(bounds),
      child: child,
    ),
    child: Text(widget.text, style: Theme.of(context).textTheme.labelLarge),
  );
}

class _DetailShimmerBlock extends StatefulWidget {
  const _DetailShimmerBlock({required this.height, this.width, this.widthFactor, this.borderRadius = AppRadii.surface});

  final double height;
  final double? width;
  final double? widthFactor;
  final BorderRadius borderRadius;

  @override
  State<_DetailShimmerBlock> createState() => _DetailShimmerBlockState();
}

class _DetailShimmerBlockState extends State<_DetailShimmerBlock> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppMotion.loadingShimmer);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.disablesAnimations(context) || !TickerMode.valuesOf(context).enabled) {
      _controller.stop();
      _controller.value = 1;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = SizedBox(width: widget.width, height: widget.height);
    if (widget.widthFactor == null) return _paint(child);
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(width: constraints.maxWidth * widget.widthFactor!, height: widget.height, child: _paint(const SizedBox.expand())),
      ),
    );
  }

  Widget _paint(Widget child) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _controller,
      child: child,
      builder: (context, child) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          gradient: _shimmerGradient(context, phase: _controller.value, base: AppThemeTokens.of(context).mutedSurface),
        ),
        child: ClipRRect(borderRadius: widget.borderRadius, child: child),
      ),
    ),
  );
}

LinearGradient _shimmerGradient(BuildContext context, {required double phase, required Color base}) {
  final highlight = Color.lerp(base, AppThemeTokens.of(context).surface, .72)!;
  final offset = -1.6 + 3.2 * phase;
  return LinearGradient(
    begin: Alignment(offset - .8, 0),
    end: Alignment(offset + .8, 0),
    colors: <Color>[base, highlight, base],
    stops: const <double>[0, .5, 1],
  );
}
