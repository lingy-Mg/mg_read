/// 无动画滚动只响应真实输入；关闭松手惯性、越界回弹与滚动装饰，保留滚动控制器身份。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';

class MotionScrollScope extends StatelessWidget {
  const MotionScrollScope({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context);
    return ScrollConfiguration(
      behavior: motionDisabled(context)
          ? behavior.copyWith(
              physics: const InstantScrollPhysics(),
              overscroll: false,
              scrollbars: false,
            )
          : behavior,
      child: child,
    );
  }
}

class InstantScrollPhysics extends ClampingScrollPhysics {
  const InstantScrollPhysics({super.parent});
  @override
  InstantScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      InstantScrollPhysics(parent: buildParent(ancestor));
  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => null;
}

class MotionScrollbar extends StatelessWidget {
  const MotionScrollbar({
    required this.child,
    this.controller,
    this.thumbVisibility,
    this.thickness,
    this.radius,
    super.key,
  });
  final Widget child;
  final ScrollController? controller;
  final bool? thumbVisibility;
  final double? thickness;
  final Radius? radius;
  @override
  Widget build(BuildContext context) => motionDisabled(context)
      ? RawScrollbar(
          controller: controller,
          thumbVisibility: true,
          thickness: thickness ?? 6,
          radius: radius,
          thumbColor: Theme.of(context).colorScheme.onSurfaceVariant,
          fadeDuration: Duration.zero,
          timeToFade: Duration.zero,
          child: child,
        )
      : Scrollbar(
          controller: controller,
          thumbVisibility: thumbVisibility,
          thickness: thickness,
          radius: radius,
          child: child,
        );
}
