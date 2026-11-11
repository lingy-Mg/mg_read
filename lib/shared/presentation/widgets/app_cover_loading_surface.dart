/// 封面等待的低对比骨架与慢扫光；延后启动，仅重绘局部画布。
/// Timer、ticker 与组件成对释放；无动画和 TickerMode 关闭时停止扫光。
part of 'app_cover_image.dart';

class _CoverLoadingSurface extends StatefulWidget {
  const _CoverLoadingSurface({required this.placeholder, required this.child, this.baseColor});

  final bool placeholder;
  final Widget child;
  final Color? baseColor;

  @override
  State<_CoverLoadingSurface> createState() => _CoverLoadingSurfaceState();
}

class _CoverLoadingSurfaceState extends State<_CoverLoadingSurface> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: AppMotion.coverLoadingSweep);
  Timer? _delay;
  bool _enabled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = !AppMotion.disablesAnimations(context) && TickerMode.valuesOf(context).enabled;
    if (enabled == _enabled) return;
    _enabled = enabled;
    _delay?.cancel();
    if (!enabled) {
      _sweep.stop();
      _sweep.value = 0;
      return;
    }
    _delay = Timer(AppMotion.coverLoadingDelay, () {
      if (mounted && _enabled) _sweep.repeat();
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = widget.baseColor == null
        ? theme.brightness == Brightness.dark
        : ThemeData.estimateBrightnessForColor(widget.baseColor!) == Brightness.dark;
    final accent = theme.extension<AppThemeTokens>()?.accent ?? theme.colorScheme.primary;
    final sheen = CustomPaint(
      key: Key(_enabled ? 'cover-load-progress' : 'cover-load-static'),
      painter: _CoverSheenPainter(_sweep, Colors.white.withValues(alpha: widget.placeholder ? (dark ? .055 : .42) : .14)),
    );
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Opacity(opacity: widget.placeholder ? 0 : 1, child: widget.child),
        Positioned.fill(
          child: IgnorePointer(
            child: widget.placeholder
                ? _CoverSkeleton(baseColor: widget.baseColor, child: sheen)
                : _enabled
                ? sheen
                : Align(
                    alignment: Alignment.bottomCenter,
                    child: SizedBox(
                      height: 1.5,
                      width: double.infinity,
                      child: ColoredBox(color: accent.withValues(alpha: .3), key: const Key('cover-load-static')),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _CoverSkeleton extends StatelessWidget {
  const _CoverSkeleton({this.child, this.baseColor});
  final Widget? child;
  final Color? baseColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<AppThemeTokens>();
    final muted = tokens?.mutedSurface ?? theme.colorScheme.surfaceContainerHighest;
    final divider = baseColor == null ? tokens?.divider ?? theme.colorScheme.outlineVariant : Color.lerp(baseColor, Colors.white, .08)!;
    final surface = baseColor == null ? tokens?.surface ?? theme.colorScheme.surface : Color.lerp(baseColor, Colors.white, .04)!;
    final base = baseColor ?? Color.lerp(muted, divider, .22)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.lerp(base, surface, .22)!, base, Color.lerp(base, divider, .08)!],
        ),
        border: Border.all(color: divider.withValues(alpha: .45)),
      ),
      child: child,
    );
  }
}

class _CoverSheenPainter extends CustomPainter {
  _CoverSheenPainter(this.progress, this.highlight) : super(repaint: progress);
  final Animation<double> progress;
  final Color highlight;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final phase = AppMotion.standardCurve.transform((progress.value / .76).clamp(0, 1));
    final center = size.width * (-.8 + 2.6 * phase);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: const Alignment(-1, -.35),
        end: const Alignment(1, .35),
        colors: [highlight.withValues(alpha: 0), highlight, highlight.withValues(alpha: 0)],
      ).createShader(Rect.fromLTWH(center - size.width / 2, 0, size.width, size.height));
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_CoverSheenPainter oldDelegate) => oldDelegate.progress != progress || oldDelegate.highlight != highlight;
}

class _CoverFailureMark extends StatelessWidget {
  const _CoverFailureMark({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 72 || constraints.maxHeight < 72) {
        return const Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: EdgeInsets.all(4),
            child: Icon(
              Icons.image_not_supported_outlined,
              size: 12,
              color: Colors.white,
              shadows: [Shadow(color: Color(0x80000000), blurRadius: 2)],
            ),
          ),
        );
      }
      return Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(7, 12, 7, 6),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0x59000000)],
            ),
          ),
          child: const Text(
            '加载失败',
            textAlign: TextAlign.right,
            maxLines: 1,
            style: TextStyle(color: Colors.white, fontSize: 10, height: 1.2, fontWeight: FontWeight.w400),
          ),
        ),
      );
    },
  );
}
