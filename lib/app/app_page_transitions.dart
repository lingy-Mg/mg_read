/// 所有 Material 二级页面的统一淡入与轻位移，控制器由 Navigator 持有。
/// 曲线监听随页面销毁；无动画时路由时长为零，运行中切换策略也立即显示完整页面。
/// 不接管页面返回或 TV 焦点；iOS 常规模式保留系统交互式返回过渡。
library;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

import '../shared/presentation/motion/app_motion.dart';

class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder({this.disabled = false});

  final bool disabled;

  static PageTransitionsTheme theme({bool disabled = false}) => PageTransitionsTheme(
    builders: {
      for (final platform in TargetPlatform.values)
        platform: platform == TargetPlatform.iOS && !disabled
            ? const CupertinoPageTransitionsBuilder()
            : AppPageTransitionsBuilder(disabled: disabled),
    },
  );

  @override
  Duration get transitionDuration => disabled ? Duration.zero : AppMotion.pageTransition;

  @override
  Duration get reverseTransitionDuration => disabled ? Duration.zero : AppMotion.pageReverseTransition;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (disabled || AppMotion.disablesAnimations(context)) return child;
    return _PageTransition(animation: animation, child: child);
  }
}

class _PageTransition extends StatefulWidget {
  const _PageTransition({required this.animation, required this.child});
  final Animation<double> animation;
  final Widget child;

  @override
  State<_PageTransition> createState() => _PageTransitionState();
}

class _PageTransitionState extends State<_PageTransition> {
  late CurvedAnimation _progress;

  void _bind() => _progress = CurvedAnimation(
    parent: widget.animation,
    curve: AppMotion.navigationCurve,
    reverseCurve: AppMotion.navigationReverseCurve,
  );

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(_PageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation == widget.animation) return;
    _progress.dispose();
    _bind();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _progress,
    child: AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) => Transform.translate(offset: Offset(AppMotion.contentTravel * (1 - _progress.value), 0), child: child),
    ),
  );
}
