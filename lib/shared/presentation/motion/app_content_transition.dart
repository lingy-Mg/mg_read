/// 有明确身份的局部内容切换：淡入与 12px 位移；布局、异步状态和滚动位置仍归调用方。
/// 只保留当前内容；无动画时控制器落到终态，策略变化不重挂载当前子树。
/// 不对列表每一行自动入场，不给数据刷新添加人为等待。
library;

import 'package:flutter/material.dart';

import 'app_motion.dart';

class AppContentTransition extends StatefulWidget {
  const AppContentTransition({required this.child, super.key});
  final Widget child;

  @override
  State<AppContentTransition> createState() => _AppContentTransitionState();
}

class _AppContentTransitionState extends State<AppContentTransition> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: AppMotion.contentChange, value: 1);
  late final Animation<double> _progress = _controller.drive(CurveTween(curve: AppMotion.navigationCurve));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.disablesAnimations(context)) _controller.value = 1;
  }

  @override
  void didUpdateWidget(AppContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (Widget.canUpdate(oldWidget.child, widget.child)) return;
    if (AppMotion.disablesAnimations(context)) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _progress,
    child: AnimatedBuilder(
      animation: _progress,
      child: widget.child,
      builder: (context, child) => Transform.translate(offset: Offset(0, AppMotion.contentTravel * (1 - _progress.value)), child: child),
    ),
  );
}
