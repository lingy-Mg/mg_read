/// 底部导航跨路由动效状态。
///
/// 职责：
/// - 持有胶囊和装饰纹理的唯一 AnimationController。
/// - 统一减少动态效果、快速重定向和 controller 释放语义。
///
/// 注意：
/// - 只管理无业务的视觉状态，不决定路由或选中目的地。
/// - 环境纹理在不可见、TickerMode 禁用或减少动态效果时不得继续运行。
///
/// TODO:
/// - 无。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// Provides the motion state consumed by the bottom-navigation renderer.
abstract interface class AppBottomNavigationMotion {
  Listenable get animation;
  bool get isMounted;
  Listenable get textureAnimation;
  double get pillHeightScale;
  double get pillWidthScale;
  double get texturePhase;

  void animateTo(AppNavigationDestination destination);
  void ensureDestination(AppNavigationDestination destination);
  double positionFor(AppNavigationDestination fallback);
  AppNavigationDestination visualSelectionFor(
    AppNavigationDestination fallback,
  );
}

/// Keeps the bottom-navigation indicator moving across top-level route swaps.
class AppBottomNavigationMotionScope extends StatefulWidget {
  /// Creates one process-local motion owner for bottom-navigation instances.
  const AppBottomNavigationMotionScope({
    required this.child,
    this.initialDestination,
    this.animateTexture = true,
    super.key,
  });

  final Widget child;
  final AppNavigationDestination? initialDestination;

  /// Whether the decorative texture may play ambient motion while visible.
  final bool animateTexture;

  static AppBottomNavigationMotion? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<
          _AppBottomNavigationMotionInherited
        >()
        ?.motion;
  }

  @override
  State<AppBottomNavigationMotionScope> createState() =>
      _AppBottomNavigationMotionScopeState();
}

class _AppBottomNavigationMotionScopeState
    extends State<AppBottomNavigationMotionScope>
    with TickerProviderStateMixin
    implements AppBottomNavigationMotion {
  late final AnimationController _controller;
  late final AnimationController _textureController;
  Animation<double> _position = const AlwaysStoppedAnimation<double>(0);
  Animation<double> _pillWidthScale = const AlwaysStoppedAnimation<double>(1);
  Animation<double> _pillHeightScale = const AlwaysStoppedAnimation<double>(1);
  late final Animation<double> _texturePhase;
  AppNavigationDestination? _origin;
  AppNavigationDestination? _target;
  bool _textureMotionEnabled = false;
  bool _textureMovingForward = true;

  @override
  Listenable get animation => _controller;

  @override
  bool get isMounted => mounted;

  @override
  Listenable get textureAnimation => _textureController;

  @override
  double get texturePhase => _texturePhase.value;

  @override
  double get pillWidthScale => _pillWidthScale.value;

  @override
  double get pillHeightScale => _pillHeightScale.value;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AppMotion.bottomNavigationPillTravel,
      vsync: this,
    );
    _textureController = AnimationController(
      duration: AppMotion.bottomNavigationTextureDrift,
      vsync: this,
    );
    _texturePhase = CurvedAnimation(
      parent: _textureController,
      curve: AppMotion.bottomNavigationTextureCurve,
      reverseCurve: AppMotion.bottomNavigationTextureCurve,
    );
    final AppNavigationDestination? initial = widget.initialDestination;
    if (initial != null) _setImmediate(initial);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.disablesAnimations(context) && _target != null) {
      _setImmediate(_target!);
    }
    _syncTextureMotion();
  }

  @override
  void didUpdateWidget(covariant AppBottomNavigationMotionScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animateTexture != widget.animateTexture) _syncTextureMotion();
  }

  @override
  double positionFor(AppNavigationDestination fallback) {
    return _target == null ? fallback.index.toDouble() : _position.value;
  }

  @override
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

  @override
  void ensureDestination(AppNavigationDestination destination) {
    if (_target == null) {
      _setImmediate(destination);
      return;
    }
    if (!_controller.isAnimating && _target != destination) {
      animateTo(destination);
    }
  }

  @override
  void animateTo(AppNavigationDestination destination) {
    if (_target == destination) return;
    if (AppMotion.disablesAnimations(context)) {
      _setImmediate(destination);
      return;
    }

    final double target = destination.index.toDouble();
    final double current = _position.value;
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
        ).chain(CurveTween(curve: AppMotion.navigationCurve)),
        weight: 70,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: overshoot,
          end: target,
        ).chain(CurveTween(curve: AppMotion.navigationCurve)),
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
    _controller.duration = AppMotion.interruptedDuration(
      fullDuration: AppMotion.bottomNavigationPillTravel,
      minimumDuration: AppMotion.bottomNavigationPillMinimumTravel,
      from: current / (AppNavigationDestination.values.length - 1),
      to: target / (AppNavigationDestination.values.length - 1),
      disableAnimations: false,
    );
    _controller.forward(from: 0);
    _playTextureMotion();
  }

  void _syncTextureMotion() {
    final bool shouldAnimate =
        widget.animateTexture &&
        !AppMotion.disablesAnimations(context) &&
        TickerMode.valuesOf(context).enabled;
    if (_textureMotionEnabled == shouldAnimate) return;
    _textureMotionEnabled = shouldAnimate;
    if (shouldAnimate) {
      _playTextureMotion();
      return;
    }
    _textureController.stop();
    if (AppMotion.disablesAnimations(context) || !widget.animateTexture) {
      _textureController.value = 0.5;
    }
  }

  void _playTextureMotion() {
    if (!_textureMotionEnabled) return;
    if (_textureMovingForward) {
      _textureController.forward();
    } else {
      _textureController.reverse();
    }
    _textureMovingForward = !_textureMovingForward;
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
        ).chain(CurveTween(curve: AppMotion.standardCurve)),
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
        ).chain(CurveTween(curve: AppMotion.navigationCurve)),
        weight: 25,
      ),
      TweenSequenceItem<double>(
        tween: Tween<double>(
          begin: arrival,
          end: 1,
        ).chain(CurveTween(curve: AppMotion.navigationCurve)),
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
    _textureController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _AppBottomNavigationMotionInherited(
      motion: this,
      child: widget.child,
    );
  }
}

class _AppBottomNavigationMotionInherited extends InheritedWidget {
  const _AppBottomNavigationMotionInherited({
    required this.motion,
    required super.child,
  });

  final AppBottomNavigationMotion motion;

  @override
  bool updateShouldNotify(_AppBottomNavigationMotionInherited oldWidget) {
    return oldWidget.motion != motion;
  }
}
