/// Remote-operable TV action with a persistent focus node and visible ring.
/// Owns focus, keep-alive and feedback; traversal owns scrolling.
/// Commands and data remain caller-owned.
/// Local tabs may activate on focus; route changes require confirmation.
/// Focused lazy children stay alive until focus moves to another control.
/// Caller-supplied focus nodes remain caller-owned.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/app/app_theme.dart';

class TvFocusable extends StatefulWidget {
  const TvFocusable({
    required this.child,
    required this.onPressed,
    this.onMore,
    this.focusNode,
    this.autofocus = false,
    this.selected = false,
    this.activateOnFocus = false,
    this.label,
    this.padding = const EdgeInsets.all(12),
    super.key,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onMore;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool selected;
  final bool activateOnFocus;
  final String? label;
  final EdgeInsetsGeometry padding;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> with AutomaticKeepAliveClientMixin {
  late FocusNode _node = widget.focusNode ?? FocusNode();
  bool _focused = false;

  @override
  bool get wantKeepAlive => _focused;

  @override
  void didUpdateWidget(covariant TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode == widget.focusNode) return;
    if (oldWidget.focusNode == null) _node.dispose();
    _node = widget.focusNode ?? FocusNode();
    _focused = _node.hasFocus;
    updateKeepAlive();
  }

  @override
  void dispose() {
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  void _activate() {
    if (widget.onPressed != null) widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tokens = AppThemeTokens.of(context);
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180);
    return Semantics(
      button: true,
      label: widget.label,
      selected: widget.selected,
      enabled: widget.onPressed != null,
      child: Focus(
        focusNode: _node,
        autofocus: widget.autofocus,
        canRequestFocus: widget.onPressed != null,
        onFocusChange: (value) {
          setState(() => _focused = value);
          updateKeepAlive();
          if (value) {
            if (widget.activateOnFocus) _activate();
          }
        },
        onKeyEvent: (_, event) {
          final key = event.logicalKey;
          final activate =
              key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.numpadEnter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.gameButtonA;
          final more = key == LogicalKeyboardKey.contextMenu;
          if (!activate && !more) return KeyEventResult.ignored;
          if (event is KeyDownEvent) {
            if (more) {
              widget.onMore?.call();
            } else if (!widget.activateOnFocus) {
              _activate();
            }
          }
          return KeyEventResult.handled;
        },
        child: GestureDetector(
          onTap: widget.onPressed == null
              ? null
              : () {
                  _node.requestFocus();
                  if (!widget.activateOnFocus) _activate();
                },
          onLongPress: widget.onMore,
          child: AnimatedScale(
            scale: _focused ? 1 : .98,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              padding: widget.padding,
              constraints: const BoxConstraints(minHeight: 52),
              decoration: BoxDecoration(
                color: widget.selected ? tokens.accentSoft : tokens.surface,
                borderRadius: AppRadii.detailControl,
                boxShadow: _focused ? [BoxShadow(color: tokens.accent.withValues(alpha: .25), blurRadius: 12)] : null,
              ),
              foregroundDecoration: BoxDecoration(
                borderRadius: AppRadii.detailControl,
                border: Border.all(color: _focused ? tokens.accent : Colors.transparent, width: 3),
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
