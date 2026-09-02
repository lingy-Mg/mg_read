/// 意见反馈页的感谢提示横幅。
///
/// 职责：
/// - 渲染反馈页顶部的静态感谢文案与插画。
/// - 复用全局主题 token，保持页面主体只负责状态和布局。
///
/// 注意：
/// - 不发起上传、网络或持久化操作。
/// - 插画仅依赖当前主题 token。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

/// 反馈页顶部的静态感谢横幅。
class FeedbackThanksBanner extends StatelessWidget {
  const FeedbackThanksBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      key: const Key('feedback-thanks-banner'),
      height: AppDetailMetrics.feedbackBannerHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppRadii.detailCard,
          border: Border.all(color: tokens.warning.withValues(alpha: 0.17), width: 0.8),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: <Color>[
              Color.alphaBlend(tokens.featureSurface.withValues(alpha: 0.75), tokens.surface),
              Color.alphaBlend(tokens.featureSurface.withValues(alpha: 0.65), tokens.surface),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          child: Row(
            children: <Widget>[
              const SizedBox(width: 82, height: 76, child: _FeedbackIllustration()),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '感谢您的反馈！',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '您的每一条建议都对我们非常重要，\n将帮助我们持续改进产品体验。',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: tokens.mutedText,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeedbackIllustration extends StatelessWidget {
  const _FeedbackIllustration();

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      image: true,
      label: '反馈消息与爱心插画',
      child: ExcludeSemantics(child: CustomPaint(painter: _FeedbackIllustrationPainter(tokens))),
    );
  }
}

class _FeedbackIllustrationPainter extends CustomPainter {
  const _FeedbackIllustrationPainter(this.tokens);

  final AppThemeTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint shadow = Paint()..color = tokens.warning.withValues(alpha: 0.09);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(size.width * 0.49, size.height * 0.84), width: size.width * 0.9, height: size.height * 0.16),
      shadow,
    );

    final RRect rearBubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width * 0.42, size.height * 0.31, size.width * 0.44, size.height * 0.42),
      const Radius.circular(8),
    );
    canvas.drawRRect(rearBubble, Paint()..color = tokens.accent.withValues(alpha: 0.28));
    final Path rearTail = Path()
      ..moveTo(size.width * 0.68, size.height * 0.7)
      ..lineTo(size.width * 0.79, size.height * 0.82)
      ..lineTo(size.width * 0.76, size.height * 0.67)
      ..close();
    canvas.drawPath(rearTail, Paint()..color = tokens.accent.withValues(alpha: 0.28));

    final RRect frontBubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width * 0.16, size.height * 0.2, size.width * 0.57, size.height * 0.49),
      const Radius.circular(9),
    );
    canvas.drawRRect(frontBubble, Paint()..color = tokens.accent);
    final Path frontTail = Path()
      ..moveTo(size.width * 0.28, size.height * 0.65)
      ..lineTo(size.width * 0.3, size.height * 0.82)
      ..lineTo(size.width * 0.43, size.height * 0.67)
      ..close();
    canvas.drawPath(frontTail, Paint()..color = tokens.accent);

    final Path heart = Path()
      ..moveTo(size.width * 0.44, size.height * 0.56)
      ..cubicTo(size.width * 0.2, size.height * 0.38, size.width * 0.37, size.height * 0.28, size.width * 0.44, size.height * 0.39)
      ..cubicTo(size.width * 0.51, size.height * 0.28, size.width * 0.68, size.height * 0.38, size.width * 0.44, size.height * 0.56)
      ..close();
    canvas.drawPath(heart, Paint()..color = tokens.surface);

    final Paint sparkle = Paint()..color = tokens.accent.withValues(alpha: 0.42);
    _drawSparkle(canvas, Offset(size.width * 0.07, size.height * 0.16), 5, sparkle);
    _drawSparkle(canvas, Offset(size.width * 0.88, size.height * 0.12), 5, sparkle);
    _drawSparkle(canvas, Offset(size.width * 0.07, size.height * 0.63), 3, sparkle);
  }

  void _drawSparkle(Canvas canvas, Offset center, double radius, Paint paint) {
    final Path path = Path()
      ..moveTo(center.dx, center.dy - radius)
      ..quadraticBezierTo(center.dx, center.dy, center.dx + radius, center.dy)
      ..quadraticBezierTo(center.dx, center.dy, center.dx, center.dy + radius)
      ..quadraticBezierTo(center.dx, center.dy, center.dx - radius, center.dy)
      ..quadraticBezierTo(center.dx, center.dy, center.dx, center.dy - radius)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _FeedbackIllustrationPainter oldDelegate) {
    return oldDelegate.tokens != tokens;
  }
}
