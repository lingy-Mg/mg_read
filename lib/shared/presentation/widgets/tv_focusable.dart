/// Remote-operable TV action with a persistent focus node and visible ring.
/// Owns focus/scroll visibility only; commands and data remain caller-owned.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/app/app_theme.dart';

class TvFocusable extends StatefulWidget {
  const TvFocusable({
    required this.child,
    required this.onPressed,
    this.onMore,
    this.autofocus = false,
    this.selected = false,
    this.label,
    this.padding = const EdgeInsets.all(12),
    super.key,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onMore;
  final bool autofocus;
  final bool selected;
  final String? label;
  final EdgeInsetsGeometry padding;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  final FocusNode _node = FocusNode();
  bool _focused = false;

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  void _activate() {
    if (widget.onPressed != null) widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
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
          if (value) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _node.hasFocus) {
                Scrollable.ensureVisible(
                  context,
                  alignment: .5,
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 120),
                );
              }
            });
          }
        },
        onKeyEvent: (_, event) {
          final key = event.logicalKey;
          final activate =
              key == LogicalKeyboardKey.select ||
              key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.space ||
              key == LogicalKeyboardKey.gameButtonA;
          final more = key == LogicalKeyboardKey.contextMenu;
          if (!activate && !more) return KeyEventResult.ignored;
          if (event is KeyDownEvent) {
            if (more) {
              widget.onMore?.call();
            } else {
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
                  _activate();
                },
          onLongPress: widget.onMore,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: widget.padding,
            constraints: const BoxConstraints(minHeight: 52),
            decoration: BoxDecoration(
              color: widget.selected ? tokens.accentSoft : tokens.surface,
              borderRadius: AppRadii.detailControl,
              border: Border.all(color: _focused ? tokens.accent : Colors.transparent, width: 3),
              boxShadow: _focused ? [BoxShadow(color: tokens.accent.withValues(alpha: .25), blurRadius: 12)] : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
