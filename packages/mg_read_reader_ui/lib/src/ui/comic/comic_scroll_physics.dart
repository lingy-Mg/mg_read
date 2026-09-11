/// Applies a one-shot geometry correction during layout, preserving drag and
/// ballistic activity rather than interrupting a gesture with jumpTo.
library;

import 'package:flutter/widgets.dart';

class ComicScrollPhysics extends ScrollPhysics {
  const ComicScrollPhysics({required this.takeCorrection, super.parent});

  final double Function() takeCorrection;

  @override
  ComicScrollPhysics applyTo(ScrollPhysics? ancestor) => ComicScrollPhysics(
    takeCorrection: takeCorrection,
    parent: buildParent(ancestor),
  );

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final correction = takeCorrection();
    if (correction != 0) {
      return (newPosition.pixels + correction).clamp(
        newPosition.minScrollExtent,
        newPosition.maxScrollExtent,
      );
    }
    return super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
  }
}
