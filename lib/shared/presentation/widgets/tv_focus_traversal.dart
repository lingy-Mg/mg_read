/// TV traversal scrolls the newly focused control into view after layout.
/// Superseded focus requests never scroll a stale or detached render object.
/// Crossing upward from content always lands on the active outer tab.
library;

import 'package:flutter/material.dart';
import '../motion/app_motion.dart';
import 'tv_destination_action.dart';

TvDestinationAction? _destination(FocusNode node) => node.context?.findAncestorWidgetOfExactType<TvDestinationAction>();

FocusNode? selectedTvNavigationNode(FocusScopeNode scope) =>
    scope.traversalDescendants.where((node) => _destination(node)?.selected == true).firstOrNull;

class TvPageTraversalPolicy extends ReadingOrderTraversalPolicy {
  TvPageTraversalPolicy() : this._(_TvTraversalRequest());
  TvPageTraversalPolicy._(this._request) : super(requestFocusCallback: _request.call);
  final _TvTraversalRequest _request;

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    _request.fromContentUp = direction == TraversalDirection.up && _destination(currentNode) == null;
    try {
      return super.inDirection(currentNode, direction);
    } finally {
      _request.fromContentUp = false;
    }
  }
}

class _TvTraversalRequest {
  bool fromContentUp = false;

  void call(FocusNode node, {ScrollPositionAlignmentPolicy? alignmentPolicy, double? alignment, Duration? duration, Curve? curve}) {
    final scope = node.nearestScope;
    if (fromContentUp && scope != null && _destination(node) != null) {
      node = selectedTvNavigationNode(scope) ?? node;
    }
    requestTvFocus(node, alignmentPolicy: alignmentPolicy, alignment: alignment, duration: duration, curve: curve);
  }
}

void requestTvFocus(FocusNode node, {ScrollPositionAlignmentPolicy? alignmentPolicy, double? alignment, Duration? duration, Curve? curve}) {
  if (node.context == null || !node.context!.mounted) return;
  node.requestFocus();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final target = node.context;
    if (target == null || !target.mounted || !node.hasFocus) return;
    final box = target.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    Scrollable.ensureVisible(
      target,
      alignmentPolicy: alignmentPolicy ?? ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      alignment: alignment ?? 1,
      duration: AppMotion.effectiveDuration(target, AppMotion.contentChange),
      curve: Curves.easeOutCubic,
    );
  });
  WidgetsBinding.instance.ensureVisualUpdate();
}
