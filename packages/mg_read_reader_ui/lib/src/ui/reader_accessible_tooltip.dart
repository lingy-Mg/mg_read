/// 阅读器稳定悬停提示与无障碍动作边界。
///
/// 职责：
/// - 保留桌面端可见悬停提示和触摸长按提示。
/// - 用单一显式 Semantics 节点承载标签与动作。
/// - 用排除语义的 OverlayEntry 取代 Material Tooltip 的 OverlayPortal。
///
/// 注意：
/// - 调用方必须把同一个动作同时交给 [onTap] 和实际可点击子控件。
/// - 仅用于阅读器中需要可见悬停提示的动作控件，不替代普通内容语义。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class ReaderAccessibleTooltip extends StatefulWidget {
  const ReaderAccessibleTooltip({
    required this.label,
    required this.onTap,
    required this.child,
    this.tooltipMessage,
    this.link = false,
    this.expanded,
    super.key,
  });

  final String label;
  final String? tooltipMessage;
  final VoidCallback onTap;
  final bool link;
  final bool? expanded;
  final Widget child;

  @override
  State<ReaderAccessibleTooltip> createState() =>
      _ReaderAccessibleTooltipState();
}

class _ReaderAccessibleTooltipState extends State<ReaderAccessibleTooltip> {
  static const Duration _dismissDelay = Duration(milliseconds: 100);
  static const Duration _touchDuration = Duration(milliseconds: 1500);
  static const double _maxWidth = 260;
  static const double _edgeMargin = 8;
  static const double _targetGap = 8;

  OverlayEntry? _entry;
  Timer? _hideTimer;

  void _showTooltip() {
    _hideTimer?.cancel();
    if (!mounted || _entry != null) return;

    final RenderObject? targetObject = context.findRenderObject();
    final OverlayState overlay = Overlay.of(context, rootOverlay: true);
    final RenderObject? overlayObject = overlay.context.findRenderObject();
    if (targetObject is! RenderBox || overlayObject is! RenderBox) return;

    final Rect targetRect =
        targetObject.localToGlobal(Offset.zero, ancestor: overlayObject) &
        targetObject.size;
    final Size overlaySize = overlayObject.size;
    final double tooltipWidth = math.min(
      _maxWidth,
      math.max(0, overlaySize.width - _edgeMargin * 2),
    );
    final double halfWidth = tooltipWidth / 2;
    final double leftCenterLimit = halfWidth + _edgeMargin;
    final double rightCenterLimit = overlaySize.width - halfWidth - _edgeMargin;
    final double centerX = rightCenterLimit < leftCenterLimit
        ? overlaySize.width / 2
        : targetRect.center.dx
              .clamp(leftCenterLimit, rightCenterLimit)
              .toDouble();
    final bool placeBelow =
        targetRect.bottom + 44 <= overlaySize.height || targetRect.top < 44;
    final ThemeData theme = Theme.of(context);
    final String message = widget.tooltipMessage ?? widget.label;

    _entry = OverlayEntry(
      builder: (BuildContext overlayContext) {
        final Widget tooltip = Theme(
          data: theme,
          child: ExcludeSemantics(
            child: IgnorePointer(
              child: Material(
                color: theme.colorScheme.inverseSurface,
                elevation: 4,
                borderRadius: BorderRadius.circular(4),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: tooltipWidth),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onInverseSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        return Positioned(
          left: centerX,
          top: placeBelow ? targetRect.bottom + _targetGap : null,
          bottom: placeBelow
              ? null
              : overlaySize.height - targetRect.top + _targetGap,
          child: FractionalTranslation(
            translation: const Offset(-0.5, 0),
            child: tooltip,
          ),
        );
      },
    );
    overlay.insert(_entry!);
  }

  void _hideTooltip() {
    _hideTimer?.cancel();
    _hideTimer = null;
    _entry?.remove();
    _entry = null;
  }

  void _handleMouseEnter(PointerEnterEvent event) {
    _showTooltip();
  }

  void _handleMouseExit(PointerExitEvent event) {
    _hideTimer?.cancel();
    _hideTimer = Timer(_dismissDelay, _hideTooltip);
  }

  void _handleLongPress() {
    _showTooltip();
    _hideTimer?.cancel();
    _hideTimer = Timer(_touchDuration, _hideTooltip);
  }

  void _handlePointerDown(PointerDownEvent event) {
    _hideTooltip();
  }

  @override
  void dispose() {
    _hideTooltip();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      link: widget.link,
      expanded: widget.expanded,
      label: widget.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: _handleMouseEnter,
        onExit: _handleMouseExit,
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          excludeFromSemantics: true,
          onLongPress: _handleLongPress,
          child: Listener(
            behavior: HitTestBehavior.deferToChild,
            onPointerDown: _handlePointerDown,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
