import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// Keeps the bottom-navigation indicator moving across top-level route swaps.
///
/// Root destinations each own their page scaffold, so this scope lives above
/// the router content and lets outgoing and incoming bars render one shared
/// capsule position while the route itself cross-fades.
class AppBottomNavigationMotionScope extends StatefulWidget {
  /// Creates a process-local motion scope for bottom navigation instances.
  const AppBottomNavigationMotionScope({
    required this.child,
    this.initialDestination,
    super.key,
  });

  final Widget child;
  final AppNavigationDestination? initialDestination;

  static _AppBottomNavigationMotionScopeState? _maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<
          _AppBottomNavigationMotionInherited
        >()
        ?.state;
  }

  @override
  State<AppBottomNavigationMotionScope> createState() =>
      _AppBottomNavigationMotionScopeState();
}

class _AppBottomNavigationMotionScopeState
    extends State<AppBottomNavigationMotionScope>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Animation<double> _position = const AlwaysStoppedAnimation<double>(0);
  Animation<double> _pillWidthScale = const AlwaysStoppedAnimation<double>(1);
  Animation<double> _pillHeightScale = const AlwaysStoppedAnimation<double>(1);
  AppNavigationDestination? _origin;
  AppNavigationDestination? _target;

  Listenable get animation => _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AppMotion.bottomNavigationPillTravel,
      vsync: this,
    );
    final AppNavigationDestination? initial = widget.initialDestination;
    if (initial != null) {
      _setImmediate(initial);
    }
  }

  double positionFor(AppNavigationDestination fallback) {
    return _target == null ? fallback.index.toDouble() : _position.value;
  }

  AppNavigationDestination visualSelectionFor(
    AppNavigationDestination fallback,
  ) {
    final AppNavigationDestination target = _target ?? fallback;
    if (_controller.isAnimating &&
        _controller.value < AppMotion.bottomNavigationSelectionHandoff) {
      return _origin ?? target;
    }
    return target;
  }

  double get pillWidthScale => _pillWidthScale.value;
  double get pillHeightScale => _pillHeightScale.value;

  void ensureDestination(AppNavigationDestination destination) {
    if (_target == null) {
      _setImmediate(destination);
      return;
    }
    // During a route cross-fade the outgoing bar still reports its old
    // selection. It must not pull the shared capsule back from the new target.
    if (!_controller.isAnimating && _target != destination) {
      animateTo(destination);
    }
  }

  void animateTo(AppNavigationDestination destination) {
    final double target = destination.index.toDouble();
    final double current = _position.value;
    if (_target == destination) return;

    final AppNavigationDestination currentVisual = visualSelectionFor(
      _target ?? destination,
    );
    final double currentWidthScale = _pillWidthScale.value;
    final double currentHeightScale = _pillHeightScale.value;
    _controller.stop();
    _origin = currentVisual;
    _target = destination;
    final double direction = target >= current ? 1 : -1;
    final double overshoot =
        target + direction * AppMotion.bottomNavigationPillOvershoot;
    _position = TweenSequence<double>(<TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
        tween: ConstantTween<double>(current),
        weight: 14,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: current,
          end: overshoot,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 70,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: overshoot,
          end: target,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 16,
      ),
    ]).animate(_controller);
    _pillWidthScale = _pillScaleSequence(
      begin: currentWidthScale,
      travelling: AppMotion.bottomNavigationPillTravelWidthScale,
      arrival: AppMotion.bottomNavigationPillArrivalWidthScale,
    ).animate(_controller);
    _pillHeightScale = _pillScaleSequence(
      begin: currentHeightScale,
      travelling: AppMotion.bottomNavigationPillTravelHeightScale,
      arrival: AppMotion.bottomNavigationPillArrivalHeightScale,
    ).animate(_controller);
    _controller.forward(from: 0);
  }

  TweenSequence<double> _pillScaleSequence({
    required double begin,
    required double travelling,
    required double arrival,
  }) {
    return TweenSequence<double>(<TweenSequenceItem<double>>[
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: begin,
          end: travelling,
        ).chain(CurveTween(curve: Curves.easeInOutCubic)),
        weight: 18,
      ),
      TweenSequenceItem<double>(
        tween: ConstantTween<double>(travelling),
        weight: 45,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: travelling,
          end: arrival,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 25,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: arrival,
          end: 1,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 12,
      ),
    ]);
  }

  void _setImmediate(AppNavigationDestination destination) {
    _controller.stop();
    _origin = destination;
    _target = destination;
    _position = AlwaysStoppedAnimation<double>(destination.index.toDouble());
    _pillWidthScale = const AlwaysStoppedAnimation<double>(1);
    _pillHeightScale = const AlwaysStoppedAnimation<double>(1);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _AppBottomNavigationMotionInherited(
      state: this,
      child: widget.child,
    );
  }
}

class _AppBottomNavigationMotionInherited extends InheritedWidget {
  const _AppBottomNavigationMotionInherited({
    required this.state,
    required super.child,
  });

  final _AppBottomNavigationMotionScopeState state;

  @override
  bool updateShouldNotify(_AppBottomNavigationMotionInherited oldWidget) {
    return oldWidget.state != state;
  }
}

/// Bottom destinations for the mobile-first root feature surfaces.
class AppBottomNavigation extends StatelessWidget {
  /// Creates a navigation bar with one selected destination.
  const AppBottomNavigation({
    required this.selected,
    required this.onSelected,
    this.height = AppSpacing.bottomNavigationHeight,
    super.key,
  });

  final AppNavigationDestination selected;
  final ValueChanged<AppNavigationDestination> onSelected;

  final double height;

  @override
  Widget build(BuildContext context) {
    final _AppBottomNavigationMotionScopeState? motion =
        AppBottomNavigationMotionScope._maybeOf(context);
    if (motion == null) {
      return AppBottomNavigationMotionScope(
        initialDestination: selected,
        child: _AppBottomNavigationContent(
          selected: selected,
          onSelected: onSelected,
          height: height,
        ),
      );
    }

    return _AppBottomNavigationContent(
      selected: selected,
      onSelected: onSelected,
      height: height,
    );
  }
}

class _AppBottomNavigationContent extends StatelessWidget {
  const _AppBottomNavigationContent({
    required this.selected,
    required this.onSelected,
    required this.height,
  });

  final AppNavigationDestination selected;
  final ValueChanged<AppNavigationDestination> onSelected;
  final double height;

  @override
  Widget build(BuildContext context) {
    final _AppBottomNavigationMotionScopeState motion =
        AppBottomNavigationMotionScope._maybeOf(context)!;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (motion.mounted) motion.ensureDestination(selected);
    });

    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return SizedBox(
      key: const Key('app-bottom-navigation'),
      height: height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          return AnimatedBuilder(
            animation: motion.animation,
            builder: (BuildContext context, Widget? child) {
              final double itemWidth =
                  constraints.maxWidth / AppNavigationDestination.values.length;
              final double position = motion
                  .positionFor(selected)
                  .clamp(0, AppNavigationDestination.values.length - 1);
              final double indicatorWidth =
                  AppSpacing.bottomNavigationIndicatorWidth *
                  motion.pillWidthScale;
              final double indicatorHeight =
                  AppSpacing.bottomNavigationIndicatorHeight *
                  motion.pillHeightScale;
              final double indicatorLeft =
                  itemWidth * (position + 0.5) - indicatorWidth / 2;
              final double indicatorTop =
                  (constraints.maxHeight - indicatorHeight) / 2;
              final AppNavigationDestination visualSelection = motion
                  .visualSelectionFor(selected);

              return ClipRect(
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    DecoratedBox(
                      key: const Key('app-bottom-navigation-backdrop'),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[
                            tokens.surface,
                            Color.alphaBlend(
                              tokens.accentSoft.withValues(alpha: 0.52),
                              tokens.surface,
                            ),
                          ],
                        ),
                      ),
                    ),
                    IgnorePointer(
                      key: const Key('app-bottom-navigation-texture'),
                      child: CustomPaint(
                        painter: _AppBottomNavigationTexturePainter(
                          lineColor: tokens.accent.withValues(alpha: 0.075),
                          washColor: tokens.featureSurface.withValues(
                            alpha: 0.22,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: indicatorLeft,
                      top: indicatorTop,
                      width: indicatorWidth,
                      height: indicatorHeight,
                      child: DecoratedBox(
                        key: const Key(
                          'app-bottom-navigation-moving-indicator',
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[
                              tokens.accentSoft,
                              Color.alphaBlend(
                                tokens.featureSurface.withValues(alpha: 0.5),
                                tokens.accentSoft,
                              ),
                            ],
                          ),
                          border: Border.all(
                            color: tokens.accent.withValues(alpha: 0.12),
                          ),
                          borderRadius: AppRadii.pill,
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: tokens.shadow.withValues(alpha: 0.1),
                              blurRadius: AppSpacing.compact,
                              offset: const Offset(0, 1),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.topCenter,
                      child: Divider(
                        height: 1,
                        thickness: 1,
                        color: tokens.divider,
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: AppNavigationDestination.values
                          .map(
                            (AppNavigationDestination destination) => Expanded(
                              child: _AppNavigationItem(
                                destination: destination,
                                visuallySelected:
                                    destination == visualSelection,
                                semanticallySelected: destination == selected,
                                onSelected: (value) {
                                  motion.animateTo(value);
                                  onSelected(value);
                                },
                                theme: theme,
                                tokens: tokens,
                              ),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AppBottomNavigationTexturePainter extends CustomPainter {
  const _AppBottomNavigationTexturePainter({
    required this.lineColor,
    required this.washColor,
  });

  final Color lineColor;
  final Color washColor;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint wash = Paint()
      ..color = washColor
      ..style = PaintingStyle.fill;
    final Paint secondaryWash = Paint()
      ..color = washColor.withValues(alpha: washColor.a * 0.58)
      ..style = PaintingStyle.fill;
    final Paint line = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppSpacing.unit / 4
      ..strokeCap = StrokeCap.round;

    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.12, size.height * 1.08),
        width: size.width * 0.58,
        height: size.height * 1.28,
      ),
      wash,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * 0.92, -size.height * 0.08),
        width: size.width * 0.42,
        height: size.height * 1.08,
      ),
      secondaryWash,
    );

    for (final double offset in <double>[0, 0.08, 0.16]) {
      final Path leftPage = Path()
        ..moveTo(-size.width * 0.04, size.height * (0.58 + offset))
        ..cubicTo(
          size.width * 0.12,
          size.height * (0.28 + offset),
          size.width * 0.29,
          size.height * (0.22 + offset),
          size.width * 0.47,
          size.height * (0.42 + offset),
        );
      final Path rightPage = Path()
        ..moveTo(size.width * 1.04, size.height * (0.42 + offset))
        ..cubicTo(
          size.width * 0.86,
          size.height * (0.68 + offset),
          size.width * 0.69,
          size.height * (0.68 + offset),
          size.width * 0.53,
          size.height * (0.42 + offset),
        );
      canvas
        ..drawPath(leftPage, line)
        ..drawPath(rightPage, line);
    }
  }

  @override
  bool shouldRepaint(covariant _AppBottomNavigationTexturePainter oldDelegate) {
    return oldDelegate.lineColor != lineColor ||
        oldDelegate.washColor != washColor;
  }
}

class _AppNavigationItem extends StatelessWidget {
  const _AppNavigationItem({
    required this.destination,
    required this.visuallySelected,
    required this.semanticallySelected,
    required this.onSelected,
    required this.theme,
    required this.tokens,
  });

  final AppNavigationDestination destination;
  final bool visuallySelected;
  final bool semanticallySelected;
  final ValueChanged<AppNavigationDestination> onSelected;
  final ThemeData theme;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final _AppNavigationItemData data = _dataFor(destination);
    final Color foreground = visuallySelected
        ? tokens.accent
        : theme.colorScheme.onSurface.withValues(alpha: 0.82);
    final TextStyle labelStyle =
        (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
          color: foreground,
          fontWeight: visuallySelected ? FontWeight.w600 : FontWeight.w400,
          height: 1.1,
        );

    return Semantics(
      button: true,
      selected: semanticallySelected,
      label: data.label,
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          key: ValueKey<String>('app-nav-${destination.name}'),
          onTap: () => onSelected(destination),
          radius: AppSpacing.minimumTouchTarget / 2,
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          focusColor: tokens.focusRing.withValues(alpha: 0.16),
          child: SizedBox.expand(
            child: Stack(
              children: <Widget>[
                AnimatedAlign(
                  key: ValueKey<String>(
                    'app-nav-icon-motion-${destination.name}',
                  ),
                  duration: AppMotion.bottomNavigationIconResponse,
                  curve: visuallySelected
                      ? Curves.easeOutBack
                      : AppMotion.navigationCurve,
                  alignment: visuallySelected
                      ? Alignment.center
                      : const Alignment(
                          0,
                          AppMotion.bottomNavigationUnselectedIconAlignmentY,
                        ),
                  child: AnimatedScale(
                    duration: AppMotion.bottomNavigationIconResponse,
                    curve: visuallySelected
                        ? Curves.easeOutBack
                        : AppMotion.navigationCurve,
                    scale: visuallySelected
                        ? AppMotion.bottomNavigationSelectedIconScale
                        : 1,
                    child: Transform.translate(
                      offset: data.opticalOffset,
                      child: AnimatedSwitcher(
                        duration: AppMotion.navigationSelection,
                        switchInCurve: AppMotion.navigationCurve,
                        switchOutCurve: AppMotion.navigationReverseCurve,
                        transitionBuilder:
                            (Widget child, Animation<double> animation) {
                              return FadeTransition(
                                opacity: animation,
                                child: ScaleTransition(
                                  scale: Tween<double>(
                                    begin: 0.9,
                                    end: 1,
                                  ).animate(animation),
                                  child: child,
                                ),
                              );
                            },
                        child: Icon(
                          key: ValueKey<bool>(visuallySelected),
                          visuallySelected ? data.selectedIcon : data.icon,
                          size: AppSpacing.bottomNavigationIconSize,
                          color: foreground,
                        ),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: const Alignment(
                    0,
                    AppMotion.bottomNavigationLabelAlignmentY,
                  ),
                  child: ExcludeSemantics(
                    child: AnimatedSlide(
                      key: ValueKey<String>(
                        'app-nav-label-motion-${destination.name}',
                      ),
                      duration: AppMotion.bottomNavigationLabelResponse,
                      curve: visuallySelected
                          ? AppMotion.navigationCurve
                          : Curves.easeOutBack,
                      offset: visuallySelected
                          ? const Offset(0, 0.28)
                          : Offset.zero,
                      child: AnimatedScale(
                        duration: AppMotion.bottomNavigationLabelResponse,
                        curve: visuallySelected
                            ? AppMotion.navigationCurve
                            : Curves.easeOutBack,
                        scale: visuallySelected ? 0.82 : 1,
                        child: AnimatedOpacity(
                          duration: AppMotion.bottomNavigationLabelResponse,
                          curve: AppMotion.navigationCurve,
                          opacity: visuallySelected ? 0 : 1,
                          child: AnimatedDefaultTextStyle(
                            duration: AppMotion.navigationSelection,
                            curve: AppMotion.navigationCurve,
                            style: labelStyle,
                            child: Text(data.label),
                          ),
                        ),
                      ),
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

  _AppNavigationItemData _dataFor(AppNavigationDestination value) {
    return switch (value) {
      AppNavigationDestination.home => const _AppNavigationItemData(
        label: '首页',
        icon: Icons.home_outlined,
        selectedIcon: Icons.home_rounded,
        opticalOffset: Offset(0, 0.25),
      ),
      AppNavigationDestination.search => const _AppNavigationItemData(
        label: '搜索',
        icon: Icons.search_rounded,
        selectedIcon: Icons.search_rounded,
        opticalOffset: Offset(-0.5, -0.5),
      ),
      AppNavigationDestination.discover => const _AppNavigationItemData(
        label: '发现',
        icon: Icons.explore_outlined,
        selectedIcon: Icons.explore_rounded,
        opticalOffset: Offset(0, -0.25),
      ),
      AppNavigationDestination.profile => const _AppNavigationItemData(
        label: '我的',
        icon: Icons.person_outline_rounded,
        selectedIcon: Icons.person_rounded,
        opticalOffset: Offset(0, -0.75),
      ),
    };
  }
}

class _AppNavigationItemData {
  const _AppNavigationItemData({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.opticalOffset,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Offset opticalOffset;
}
