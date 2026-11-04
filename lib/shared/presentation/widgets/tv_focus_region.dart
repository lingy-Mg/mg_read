/// Page-owned TV traversal and recovery after asynchronous content replacement.
/// Focus stays within the active page; dialogs retain their own focus scope.
/// Directional scrolling animates only enough to reveal the next control.
/// Recovery prefers an already selected control, so restoring a page cannot
/// activate an unrelated destination whose navigation happens on focus.
/// Root back can reset mounted vertical viewports and restore the active tab;
/// nested routes and dialogs are handled by Navigator before this fallback.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'tv_focus_traversal.dart';
import 'tv_focusable.dart';
export 'tv_focus_traversal.dart';

class TvFocusRegion extends StatefulWidget {
  const TvFocusRegion({required this.child, super.key});
  final Widget child;

  static bool returnToNavigation() =>
      FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<_TvFocusRegionState>()?._returnToNavigation() ?? false;

  @override
  State<TvFocusRegion> createState() => _TvFocusRegionState();
}

class _TvFocusRegionState extends State<TvFocusRegion> {
  final _scope = FocusScopeNode(debugLabel: 'TV page');
  final _policy = TvPageTraversalPolicy();
  bool _scheduled = false;
  bool _active = false;

  bool _returnToNavigation() {
    if (!_active) return false;
    final selected = selectedTvNavigationNode(_scope);
    if (selected == null) return false;
    final positions = <ScrollPosition>[];
    void visit(Element element) {
      // Outgoing animations and covered pages retain their own saved offsets.
      if (element.widget case Offstage(offstage: true) || ExcludeFocus(excluding: true)) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final position = (element.state as ScrollableState).position;
        if (position.axis == Axis.vertical && position.hasPixels && position.pixels > position.minScrollExtent) positions.add(position);
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    if (selected.hasFocus && positions.isEmpty) return false;
    for (final position in positions) {
      position.jumpTo(position.minScrollExtent);
    }
    requestTvFocus(selected);
    return true;
  }

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_repairFocus);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_repairFocus);
    _scope.dispose();
    super.dispose();
  }

  void _repairFocus() {
    if (!_active || _scheduled || !_scope.hasPrimaryFocus) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_active || !_scope.hasPrimaryFocus) return;
      final nodes = _scope.traversalDescendants.where(
        (node) =>
            node is! FocusScopeNode &&
            node.context != null &&
            node.context?.findAncestorWidgetOfExactType<EditableText>()?.readOnly != true,
      );
      if (nodes.isNotEmpty) {
        final ordered = _policy.sortDescendants(nodes, _scope);
        final selected = ordered.where((node) => node.context?.findAncestorWidgetOfExactType<TvFocusable>()?.selected ?? false);
        requestTvFocus(selected.firstOrNull ?? ordered.first);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    if (!TvModeScope.isEnabled(context)) {
      _active = false;
      return widget.child;
    }
    final active = ModalRoute.of(context)?.isCurrent ?? true;
    if (active && !_active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_active) return;
        _scope.requestFocus();
        _repairFocus();
      });
    }
    _active = active;
    _repairFocus();
    return FocusScope(
      node: _scope,
      autofocus: active,
      canRequestFocus: active,
      descendantsAreFocusable: active,
      descendantsAreTraversable: active,
      child: TvRemoteShortcuts(
        child: FocusTraversalGroup(policy: _policy, child: widget.child),
      ),
    );
  }
}
