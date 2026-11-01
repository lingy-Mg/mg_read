/// Page-owned TV traversal and recovery after asynchronous content replacement.
/// Focus stays within the active page; dialogs retain their own focus scope.
/// Directional scrolling animates only enough to reveal the next control.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/shared/presentation/tv_mode_scope.dart';
import 'tv_focus_traversal.dart';
export 'tv_focus_traversal.dart';

class TvFocusRegion extends StatefulWidget {
  const TvFocusRegion({required this.child, super.key});
  final Widget child;

  @override
  State<TvFocusRegion> createState() => _TvFocusRegionState();
}

class _TvFocusRegionState extends State<TvFocusRegion> {
  final _scope = FocusScopeNode(debugLabel: 'TV page');
  final _policy = ReadingOrderTraversalPolicy(requestFocusCallback: requestTvFocus);
  bool _scheduled = false;
  bool _active = false;

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
      final nodes = _scope.traversalDescendants.where((node) => node is! FocusScopeNode && node.context != null);
      if (nodes.isNotEmpty) requestTvFocus(_policy.sortDescendants(nodes, _scope).first);
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
      child: FocusTraversalGroup(policy: _policy, child: widget.child),
    );
  }
}
