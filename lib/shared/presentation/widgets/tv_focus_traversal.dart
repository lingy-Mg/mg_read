/// TV traversal scrolls the newly focused control into view after layout.
/// Superseded focus requests never scroll a stale or detached render object.
library;

import 'package:flutter/material.dart';

void requestTvFocus(FocusNode node, {ScrollPositionAlignmentPolicy? alignmentPolicy, double? alignment, Duration? duration, Curve? curve}) {
  if (node.context == null) return;
  node.requestFocus();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final target = node.context;
    final box = target?.findRenderObject();
    if (target == null || !node.hasFocus || box is! RenderBox || !box.attached || !box.hasSize) return;
    Scrollable.ensureVisible(
      target,
      alignmentPolicy: alignmentPolicy ?? ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      alignment: alignment ?? 1,
      duration: MediaQuery.disableAnimationsOf(target) ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  });
  WidgetsBinding.instance.ensureVisualUpdate();
}
