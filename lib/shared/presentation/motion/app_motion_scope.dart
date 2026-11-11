/// 将已持久化的无动画偏好与系统无障碍策略合并到路由、覆盖层和独立阅读器 package。
/// 不关闭整树 TickerMode，避免控件冻结在过渡中途；各动效读取策略并呈现终态。
library;

import 'package:flutter/material.dart';

class AppMotionScope extends StatelessWidget {
  const AppMotionScope({required this.disabled, required this.child, super.key});

  final bool disabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduceMotion = disabled || media.disableAnimations;
    return MediaQuery(
      data: media.copyWith(disableAnimations: reduceMotion),
      child: HeroMode(enabled: !reduceMotion, child: child),
    );
  }
}
