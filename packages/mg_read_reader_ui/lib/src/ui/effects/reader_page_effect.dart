import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/models.dart';

/// Applies a reader-owned transition to one page in an overlay transition.
///
/// [progress] runs from zero at the start to one at completion. The caller
/// supplies both the outgoing (`entering: false`) and incoming
/// (`entering: true`) pages in the same stack. This widget changes only their
/// paint transform; it never changes pagination or semantic positions.
class ReaderPageEffect extends StatelessWidget {
  const ReaderPageEffect({
    required this.animation,
    required this.progress,
    required this.entering,
    required this.child,
    this.forward = true,
    this.reduceMotion = false,
    super.key,
  });

  final ReaderPageAnimation animation;
  final double progress;
  final bool entering;
  final bool forward;
  final bool reduceMotion;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool motionDisabled =
        reduceMotion || MediaQuery.maybeOf(context)?.disableAnimations == true;
    if (motionDisabled || animation == ReaderPageAnimation.none) {
      final bool hidden = entering ? progress < 1 : progress >= 1;
      return Offstage(offstage: hidden, child: child);
    }
    final double t = Curves.easeOutCubic.transform(
      progress.clamp(0, 1).toDouble(),
    );
    return switch (animation) {
      ReaderPageAnimation.slide => _SlidePageEffect(
        progress: t,
        entering: entering,
        forward: forward,
        child: child,
      ),
      ReaderPageAnimation.cover => _CoverPageEffect(
        progress: t,
        entering: entering,
        forward: forward,
        child: child,
      ),
      ReaderPageAnimation.pageCurl => _PageCurlEffect(
        progress: t,
        entering: entering,
        forward: forward,
        child: child,
      ),
      ReaderPageAnimation.none => child,
    };
  }
}

class _SlidePageEffect extends StatelessWidget {
  const _SlidePageEffect({
    required this.progress,
    required this.entering,
    required this.forward,
    required this.child,
  });

  final double progress;
  final bool entering;
  final bool forward;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double direction = forward ? 1 : -1;
    final double dx = entering
        ? direction * (1 - progress)
        : -direction * progress;
    return ClipRect(
      child: FractionalTranslation(translation: Offset(dx, 0), child: child),
    );
  }
}

class _CoverPageEffect extends StatelessWidget {
  const _CoverPageEffect({
    required this.progress,
    required this.entering,
    required this.forward,
    required this.child,
  });

  final double progress;
  final bool entering;
  final bool forward;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // PageView paints the following page above the current page and the
    // previous page below it. A cover transition therefore has two symmetric
    // halves: moving forward slides the incoming, upper page over a stationary
    // current page; moving backward slides the current, upper page to the
    // right and reveals a stationary previous page underneath.
    final bool movingPage = forward ? entering : !entering;
    if (!movingPage) return child;

    final double dx = forward ? 1 - progress : progress;
    final double shadowAlpha = math.sin(progress * math.pi) * .18;
    return ClipRect(
      child: FractionalTranslation(
        translation: Offset(dx, 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: shadowAlpha),
                blurRadius: 18,
                spreadRadius: 2,
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _PageCurlEffect extends StatelessWidget {
  const _PageCurlEffect({
    required this.progress,
    required this.entering,
    required this.forward,
    required this.child,
  });

  final double progress;
  final bool entering;
  final bool forward;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double direction = forward ? 1 : -1;
    final double phase = entering ? 1 - progress : progress;
    final double angle = direction * phase * math.pi * .42;
    final Alignment alignment = direction > 0
        ? Alignment.centerLeft
        : Alignment.centerRight;
    final Matrix4 transform = Matrix4.identity()
      ..setEntry(3, 2, .0016)
      ..rotateY(entering ? angle : -angle);
    final double shade = math.sin(phase * math.pi / 2) * .16;

    return ClipRect(
      child: Transform(
        alignment: alignment,
        transform: transform,
        child: Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            child,
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: direction > 0
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      end: direction > 0
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      colors: <Color>[
                        Colors.transparent,
                        Colors.black.withValues(alpha: shade),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
