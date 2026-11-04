/// Remote-operable TV action with a persistent focus node and visible ring.
/// Owns focus, keep-alive and feedback; traversal owns scrolling.
/// Commands and data remain caller-owned.
/// Callers choose focus activation for navigation; content commands require OK.
/// Navigation may provide a separate confirmation callback for refreshing itself.
/// Focused lazy children stay alive until focus moves to another control.
/// Caller-supplied focus nodes remain caller-owned.
/// Actions with a menu defer OK until release; holding OK opens the menu once.
/// Losing focus, disabling or disposing cancels a pending remote hold.
library;

import 'dart:async';

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
    this.onConfirmed,
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
  final VoidCallback? onConfirmed;
  final String? label;
  final EdgeInsetsGeometry padding;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> with AutomaticKeepAliveClientMixin {
  late FocusNode _node = widget.focusNode ?? FocusNode();
  bool _focused = false;
  Timer? _holdTimer;
  LogicalKeyboardKey? _heldKey;

  @override
  bool get wantKeepAlive => _focused;

  @override
  void didUpdateWidget(covariant TvFocusable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onPressed == null || widget.onMore == null || oldWidget.focusNode != widget.focusNode) _cancelHold();
    if (oldWidget.focusNode == widget.focusNode) return;
    if (oldWidget.focusNode == null) _node.dispose();
    _node = widget.focusNode ?? FocusNode();
    _focused = _node.hasFocus;
    updateKeepAlive();
  }

  @override
  void dispose() {
    _cancelHold();
    if (widget.focusNode == null) _node.dispose();
    super.dispose();
  }

  void _activate() {
    if (widget.onPressed != null) widget.onPressed!();
  }

  void _confirm() {
    if (widget.activateOnFocus) {
      widget.onConfirmed?.call();
    } else {
      _activate();
    }
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _heldKey = null;
  }

  KeyEventResult _onKeyEvent(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    final activate = const [
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.gameButtonA,
    ].contains(key);
    final more = key == LogicalKeyboardKey.contextMenu;
    if (!activate && !more) return KeyEventResult.ignored;
    if (widget.onPressed == null) return KeyEventResult.handled;
    if (more) {
      if (event is KeyDownEvent) {
        _cancelHold();
        widget.onMore?.call();
      }
    } else if (widget.onMore != null) {
      if (event is KeyDownEvent && _heldKey == null) {
        _heldKey = key;
        _holdTimer = Timer(const Duration(milliseconds: 600), () {
          _cancelHold();
          if (mounted && _node.hasFocus && widget.onPressed != null) widget.onMore?.call();
        });
      } else if (event is KeyUpEvent && _heldKey == key) {
        _cancelHold();
        _confirm();
      }
    } else if (event is KeyDownEvent) {
      _confirm();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tokens = AppThemeTokens.of(context);
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180);
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _confirm();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        label: widget.label,
        selected: widget.selected,
        enabled: widget.onPressed != null,
        child: Focus(
          focusNode: _node,
          autofocus: widget.autofocus,
          // Explicitly reset the local flag: a caller-owned node's computed
          // skipTraversal is temporarily true under an inactive route scope.
          skipTraversal: false,
          canRequestFocus: widget.onPressed != null,
          onFocusChange: (value) {
            if (!value) _cancelHold();
            setState(() => _focused = value);
            updateKeepAlive();
            if (value) {
              if (widget.activateOnFocus) _activate();
            }
          },
          onKeyEvent: _onKeyEvent,
          child: GestureDetector(
            onTap: widget.onPressed == null
                ? null
                : () {
                    _node.requestFocus();
                    _confirm();
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
      ),
    );
  }
}
