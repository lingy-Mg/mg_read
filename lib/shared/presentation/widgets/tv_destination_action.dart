/// TV destination actions activate on focus except Search, which requires OK.
/// A root-owned handoff restores the destination control across route changes,
/// so continued left/right movement never falls into newly mounted content.
library;

import 'package:flutter/material.dart';
import '../app_navigation_destination.dart';
import 'tv_focusable.dart';
import 'tv_focus_traversal.dart';

class TvNavigationHandoff extends StatefulWidget {
  const TvNavigationHandoff({required this.child, super.key});
  final Widget child;

  static void request(BuildContext context, Object identity) {
    context.getInheritedWidgetOfExactType<_NavigationScope>()?.intent.pending = identity;
  }

  @override
  State<TvNavigationHandoff> createState() => _TvNavigationHandoffState();
}

class _TvNavigationHandoffState extends State<TvNavigationHandoff> {
  final _intent = _NavigationIntent();

  @override
  Widget build(BuildContext context) => _NavigationScope(intent: _intent, child: widget.child);
}

class _NavigationIntent {
  Object? pending;
}

class _NavigationScope extends InheritedWidget {
  const _NavigationScope({required this.intent, required super.child});
  final _NavigationIntent intent;

  @override
  bool updateShouldNotify(_NavigationScope oldWidget) => intent != oldWidget.intent;
}

class TvDestinationAction extends StatefulWidget {
  const TvDestinationAction({
    required this.destination,
    required this.current,
    required this.onPressed,
    required this.child,
    this.selected = false,
    this.autofocus = false,
    this.focusNode,
    this.navigationId,
    super.key,
  });
  final AppNavigationDestination destination;
  final AppNavigationDestination current;
  final VoidCallback onPressed;
  final Widget child;
  final bool selected;
  final bool autofocus;
  final FocusNode? focusNode;
  final Object? navigationId;

  @override
  State<TvDestinationAction> createState() => _TvDestinationActionState();
}

class _TvDestinationActionState extends State<TvDestinationAction> {
  late final FocusNode _ownedNode = FocusNode();
  FocusNode get _node => widget.focusNode ?? _ownedNode;
  Object get _id => widget.navigationId ?? widget.destination;

  @override
  void initState() {
    super.initState();
    _node.addListener(_reveal);
  }

  void _reveal() {
    if (_node.hasFocus) requestTvFocus(_node);
  }

  @override
  void didUpdateWidget(TvDestinationAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedNode).removeListener(_reveal);
      _node.addListener(_reveal);
    }
    _restore();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restore();
  }

  void _restore() {
    final intent = context.dependOnInheritedWidgetOfExactType<_NavigationScope>()?.intent;
    final active = ModalRoute.of(context)?.isCurrent ?? true;
    if (!active || intent?.pending != _id || widget.current != widget.destination || !widget.selected) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false || intent?.pending != _id) return;
      intent?.pending = null;
      requestTvFocus(_node);
    });
  }

  @override
  void dispose() {
    _node.removeListener(_reveal);
    _ownedNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: _node,
    autofocus: widget.autofocus,
    selected: widget.selected,
    activateOnFocus: widget.destination != AppNavigationDestination.search,
    onPressed: () {
      if (!widget.selected) {
        context.getInheritedWidgetOfExactType<_NavigationScope>()?.intent.pending = _id;
      }
      widget.onPressed();
    },
    child: widget.child,
  );
}
