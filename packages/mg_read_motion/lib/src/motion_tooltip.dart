/// 悬停提示的静态分支；复用 RawTooltip 的输入、语义、定位与生命周期，只将过渡时长置零。
/// 稳定子树 key 保留模式切换前后的焦点和输入控件状态。
library;

import 'package:flutter/material.dart';
import 'motion_policy.dart';

class MotionTooltip extends StatefulWidget {
  const MotionTooltip({
    required this.message,
    required this.child,
    this.excludeFromSemantics = false,
    this.waitDuration,
    this.showDuration,
    this.preferBelow = true,
    this.childProvidesTooltip = false,
    super.key,
  });
  final String message;
  final Widget child;
  final bool excludeFromSemantics;
  final Duration? waitDuration;
  final Duration? showDuration;
  final bool preferBelow;

  /// 原生按钮已经负责普通模式提示时，保留其原始语义树。
  final bool childProvidesTooltip;
  @override
  State<MotionTooltip> createState() => _MotionTooltipState();
}

class _MotionTooltipState extends State<MotionTooltip> {
  final _childKey = GlobalKey();
  @override
  Widget build(BuildContext context) {
    final disabled = motionDisabled(context);
    final child = KeyedSubtree(
      key: _childKey,
      child: TooltipVisibility(
        visible: !widget.childProvidesTooltip || !disabled,
        child: widget.child,
      ),
    );
    if (!disabled) {
      if (widget.childProvidesTooltip) return child;
      return Tooltip(
        message: widget.message,
        excludeFromSemantics: widget.excludeFromSemantics,
        waitDuration: widget.waitDuration,
        showDuration: widget.showDuration,
        preferBelow: widget.preferBelow,
        child: child,
      );
    }
    final theme = Theme.of(context);
    final tooltip = theme.tooltipTheme;
    return RawTooltip(
      semanticsTooltip: widget.excludeFromSemantics ? null : widget.message,
      animationStyle: AnimationStyle.noAnimation,
      hoverDelay: widget.waitDuration ?? tooltip.waitDuration ?? Duration.zero,
      touchDelay:
          widget.showDuration ??
          tooltip.showDuration ??
          const Duration(seconds: 2),
      dismissDelay: Duration.zero,
      ignorePointer: true,
      positionDelegate: (position) => positionDependentBox(
        size: position.overlaySize,
        childSize: position.tooltipSize,
        target: position.target,
        verticalOffset: position.targetSize.height / 2 + 8,
        preferBelow: widget.preferBelow,
      ),
      tooltipBuilder: (context, _) => ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - 24,
        ),
        child: DecoratedBox(
          decoration:
              tooltip.decoration ??
              BoxDecoration(
                color: theme.colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(4),
              ),
          child: Padding(
            padding:
                tooltip.padding ??
                const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Text(
              widget.message,
              style:
                  tooltip.textStyle ??
                  theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
            ),
          ),
        ),
      ),
      child: child,
    );
  }
}
