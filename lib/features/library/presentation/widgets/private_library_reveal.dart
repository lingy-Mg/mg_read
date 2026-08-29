/// 首页进入隐私书架的扩散过渡。
///
/// 职责：
/// - 从首页底部图标位置扩散遮罩，并在遮罩覆盖页面后触发显式导航回调。
/// - 遵循系统“减少动态效果”设置，关闭动效时直接进入隐私书架。
///
/// 注意：
/// - 本组件不拥有路由和隐私书架状态。
/// - 覆盖层只存在于一次长按导航过渡期间，并阻止重复交互。
///
/// TODO:
/// - 无。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

/// Reveals the private-library route from [globalOrigin].
Future<void> showPrivateLibraryReveal({
  required BuildContext context,
  required Offset globalOrigin,
  required VoidCallback onCovered,
}) async {
  if (AppMotion.disablesAnimations(context)) {
    onCovered();
    return;
  }

  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  final RenderBox? overlayBox = overlay.context.findRenderObject() as RenderBox?;
  final Size overlaySize = overlayBox?.size ?? MediaQuery.sizeOf(context);
  final Offset origin = overlayBox?.globalToLocal(globalOrigin) ?? globalOrigin;
  final Completer<void> finished = Completer<void>();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext context) => _PrivateLibraryReveal(
      origin: origin,
      overlaySize: overlaySize,
      onCovered: onCovered,
      onFinished: () {
        if (!finished.isCompleted) finished.complete();
      },
    ),
  );
  overlay.insert(entry);
  await finished.future;
  if (entry.mounted) entry.remove();
}

class _PrivateLibraryReveal extends StatefulWidget {
  const _PrivateLibraryReveal({required this.origin, required this.overlaySize, required this.onCovered, required this.onFinished});

  final Offset origin;
  final Size overlaySize;
  final VoidCallback onCovered;
  final VoidCallback onFinished;

  @override
  State<_PrivateLibraryReveal> createState() => _PrivateLibraryRevealState();
}

class _PrivateLibraryRevealState extends State<_PrivateLibraryReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: AppMotion.privacyModeReveal);
    _progress = CurvedAnimation(parent: _controller, curve: AppMotion.navigationCurve);
    unawaited(_controller.forward().then((_) => _complete()));
  }

  Future<void> _complete() async {
    if (_completed) return;
    _completed = true;
    widget.onCovered();
    await Future<void>.delayed(AppMotion.destinationTransition);
    widget.onFinished();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final double maxRadius = <double>[
      widget.origin.distance,
      (widget.origin - Offset(widget.overlaySize.width, 0)).distance,
      (widget.origin - Offset(0, widget.overlaySize.height)).distance,
      (widget.origin - Offset(widget.overlaySize.width, widget.overlaySize.height)).distance,
    ].reduce(math.max);

    return Positioned.fill(
      child: IgnorePointer(
        child: Semantics(
          label: '正在进入隐私模式',
          liveRegion: true,
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _progress,
              builder: (BuildContext context, Widget? child) => CustomPaint(
                key: const Key('private-library-reveal'),
                painter: _PrivateLibraryRevealPainter(
                  origin: widget.origin,
                  radius: maxRadius * _progress.value,
                  fillColor: Color.alphaBlend(tokens.accent.withValues(alpha: 0.08), tokens.featureSurface),
                  ringColor: tokens.accent.withValues(alpha: 0.2 * (1 - _progress.value)),
                ),
                child: child,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

class _PrivateLibraryRevealPainter extends CustomPainter {
  const _PrivateLibraryRevealPainter({required this.origin, required this.radius, required this.fillColor, required this.ringColor});

  final Offset origin;
  final double radius;
  final Color fillColor;
  final Color ringColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(origin, radius, Paint()..color = fillColor);
    if (radius > 0) {
      canvas.drawCircle(
        origin,
        radius,
        Paint()
          ..color = ringColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = AppSpacing.unit,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PrivateLibraryRevealPainter oldDelegate) {
    return oldDelegate.origin != origin ||
        oldDelegate.radius != radius ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.ringColor != ringColor;
  }
}
