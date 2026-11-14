/// 等待反馈：无动画时无 ticker；真实数值进度即时绘制，未知进度以静态标记表达。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';

class MotionCircularProgressIndicator extends StatelessWidget {
  const MotionCircularProgressIndicator({
    this.value,
    this.color,
    this.strokeWidth = 4,
    this.semanticsLabel,
    super.key,
  });
  final double? value;
  final Color? color;
  final double strokeWidth;
  final String? semanticsLabel;
  @override
  Widget build(BuildContext context) {
    if (!motionDisabled(context) || value != null) {
      return CircularProgressIndicator(
        value: value,
        color: color,
        strokeWidth: strokeWidth,
        semanticsLabel: semanticsLabel,
      );
    }
    return Semantics(
      label: semanticsLabel ?? '正在加载',
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Icon(
          Icons.hourglass_empty_rounded,
          color:
              color ??
              ProgressIndicatorTheme.of(context).color ??
              Theme.of(context).colorScheme.primary,
          size: 24,
        ),
      ),
    );
  }
}

class MotionLinearProgressIndicator extends StatelessWidget {
  const MotionLinearProgressIndicator({
    this.value,
    this.color,
    this.backgroundColor,
    this.minHeight,
    this.borderRadius,
    super.key,
  });
  final double? value;
  final Color? color;
  final Color? backgroundColor;
  final double? minHeight;
  final BorderRadiusGeometry? borderRadius;
  @override
  Widget build(BuildContext context) {
    if (!motionDisabled(context) || value != null) {
      return LinearProgressIndicator(
        value: value,
        color: color,
        backgroundColor: backgroundColor,
        minHeight: minHeight,
        borderRadius: borderRadius,
      );
    }
    return Semantics(
      label: '正在加载',
      child: SizedBox(
        height: minHeight ?? 4,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color:
                backgroundColor ??
                Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: borderRadius ?? BorderRadius.zero,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: SizedBox(
              width: 16,
              height: minHeight ?? 4,
              child: ColoredBox(
                color: color ?? Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
