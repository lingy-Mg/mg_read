import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_book_list_view_data.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';

/// Prominent current-reading card driven only by a display view-model.
class LibraryContinueReadingCard extends StatelessWidget {
  /// Creates the current-reading card for [data].
  const LibraryContinueReadingCard({
    required this.data,
    required this.onContinueReading,
    this.isPreparing = false,
    super.key,
  });

  final LibraryContinueReadingViewData data;
  final VoidCallback onContinueReading;
  final bool isPreparing;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return Semantics(
      container: true,
      label: isPreparing ? '继续阅读，${data.title}，正在准备阅读内容' : '继续阅读，${data.title}',
      liveRegion: isPreparing,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact =
              constraints.maxWidth < AppSpacing.compactCardStackBreakpoint;
          final double coverWidth = compact
              ? AppSpacing.continueReadingCoverWidth - AppSpacing.section
              : AppSpacing.continueReadingCoverWidth;
          final double coverHeight = compact
              ? AppSpacing.continueReadingCoverHeight - AppSpacing.section * 2
              : AppSpacing.continueReadingCoverHeight;
          final double cardHeight = compact
              ? AppSpacing.continueReadingCardHeight - AppSpacing.regular
              : AppSpacing.continueReadingCardHeight;
          final double cardTop = compact
              ? AppSpacing.continueReadingCardTopInset - AppSpacing.compact
              : AppSpacing.continueReadingCardTopInset;
          final double cardLeft =
              coverWidth - AppSpacing.continueReadingCardCoverOverlap;

          return SizedBox(
            height: coverHeight,
            width: double.infinity,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned(
                  key: const Key('continue-reading-surface'),
                  left: cardLeft,
                  right: 0,
                  top: cardTop,
                  height: cardHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: AppRadii.card,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          tokens.featureSurface,
                          tokens.surface.withValues(alpha: 0.94),
                        ],
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: AppRadii.card,
                      child: Stack(
                        children: <Widget>[
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Opacity(
                                opacity: 0.72,
                                child: Image.asset(
                                  'assets/illustrations/home/continue_reading_backdrop.png',
                                  fit: BoxFit.cover,
                                  alignment: Alignment.centerRight,
                                ),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: _ContinueReadingTexturePainter(
                                  color: tokens.accent.withValues(alpha: 0.07),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.only(
                              left: coverWidth - cardLeft + AppSpacing.regular,
                              right: AppSpacing.comfortable,
                              top: AppSpacing.compact,
                              bottom: AppSpacing.compact,
                            ),
                            child: _ContinueReadingDetails(
                              data: data,
                              onContinueReading: onContinueReading,
                              isPreparing: isPreparing,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  child: _ContinueReadingCoverTreatment(
                    title: data.title,
                    variant: data.coverVariant,
                    coverBytes: data.coverBytes,
                    assetPath: data.coverAssetPath,
                    width: coverWidth,
                    height: coverHeight,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ContinueReadingDetails extends StatelessWidget {
  const _ContinueReadingDetails({
    required this.data,
    required this.onContinueReading,
    required this.isPreparing,
  });

  final LibraryContinueReadingViewData data;
  final VoidCallback onContinueReading;
  final bool isPreparing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final int percentage = (data.progress * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _AdaptiveSingleLineTitle(
          title: data.title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w500,
            height: 1.16,
            letterSpacing: -0.2,
          ),
        ),
        const Spacer(),
        Row(
          children: <Widget>[
            Flexible(
              fit: FlexFit.loose,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppSpacing.continueReadingProgressWidth,
                ),
                child: SizedBox(
                  width: AppSpacing.continueReadingProgressWidth,
                  child: ReadingProgressBar(progress: data.progress),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.continueReadingProgressValueGap),
            Text(
              '$percentage%',
              style: theme.textTheme.bodySmall?.copyWith(
                color: tokens.accent,
                fontWeight: FontWeight.w400,
                height: 1.1,
              ),
            ),
          ],
        ),
        const Spacer(),
        _ContinueReadingAction(
          onPressed: onContinueReading,
          isPreparing: isPreparing,
        ),
      ],
    );
  }
}

/// Gives the prominent cover a little physical depth without altering its
/// source artwork or the shared cover component used by the book list.
class _ContinueReadingCoverTreatment extends StatelessWidget {
  const _ContinueReadingCoverTreatment({
    required this.title,
    required this.variant,
    required this.width,
    required this.height,
    this.assetPath,
    this.coverBytes,
  });

  final String title;
  final LibraryCoverVariant variant;
  final double width;
  final double height;
  final String? assetPath;
  final List<int>? coverBytes;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final BorderRadius radius = AppRadii.bookCover;
    final double layerOffset = AppSpacing.continueReadingCoverLayerOffset;

    return SizedBox(
      width: width + layerOffset,
      height: height + layerOffset,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: layerOffset,
            top: layerOffset,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                color: tokens.accentSoft.withValues(alpha: 0.72),
                border: Border.all(
                  color: tokens.surface.withValues(alpha: 0.72),
                ),
              ),
              child: SizedBox(width: width, height: height),
            ),
          ),
          DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: tokens.shadow.withValues(alpha: 0.72),
                  blurRadius: AppSpacing.continueReadingCoverShadowBlur,
                  offset: const Offset(
                    0,
                    AppSpacing.continueReadingCoverShadowDrop,
                  ),
                ),
              ],
              border: Border.all(color: tokens.surface.withValues(alpha: 0.82)),
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                children: <Widget>[
                  LibraryBookCover(
                    title: title,
                    variant: variant,
                    coverBytes: coverBytes,
                    assetPath: assetPath,
                    width: width,
                    height: height,
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: <Color>[
                              Colors.white.withValues(alpha: 0.08),
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.16),
                            ],
                            stops: const <double>[0, 0.42, 1],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdaptiveSingleLineTitle extends StatelessWidget {
  const _AdaptiveSingleLineTitle({required this.title, required this.style});

  final String title;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final TextStyle resolvedStyle = style ?? DefaultTextStyle.of(context).style;
    final TextScaler textScaler = MediaQuery.textScalerOf(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double baseFontSize =
            resolvedStyle.fontSize ?? AppTypography.sectionTitle;
        double fontSize = baseFontSize;
        while (fontSize > AppTypography.continueReadingTitleMinimum &&
            _titleWidth(
                  context: context,
                  style: resolvedStyle.copyWith(fontSize: fontSize),
                  textScaler: textScaler,
                ) >
                constraints.maxWidth) {
          fontSize -= 1;
        }

        return Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textScaler: textScaler,
          style: resolvedStyle.copyWith(fontSize: fontSize),
        );
      },
    );
  }

  double _titleWidth({
    required BuildContext context,
    required TextStyle style,
    required TextScaler textScaler,
  }) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: title, style: style),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    return painter.width;
  }
}

class _ContinueReadingAction extends StatelessWidget {
  const _ContinueReadingAction({
    required this.onPressed,
    required this.isPreparing,
  });

  final VoidCallback onPressed;
  final bool isPreparing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Color actionStart = Color.lerp(
      tokens.accent,
      tokens.mutedText,
      0.17,
    )!;
    final Color actionEnd = Color.lerp(tokens.accent, tokens.mutedText, 0.21)!;
    return SizedBox(
      width: AppSpacing.continueReadingActionWidth,
      height: AppSpacing.continueReadingActionHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppRadii.continueReadingAction,
          gradient: LinearGradient(colors: <Color>[actionStart, actionEnd]),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('continue-reading-cta'),
            onTap: isPreparing ? null : onPressed,
            borderRadius: AppRadii.continueReadingAction,
            child: Center(
              child: isPreparing
                  ? SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.onPrimary,
                      ),
                    )
                  : Text(
                      '继续阅读',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onPrimary,
                        fontWeight: FontWeight.w500,
                        height: 1.2,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContinueReadingTexturePainter extends CustomPainter {
  const _ContinueReadingTexturePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final Paint fill = Paint()
      ..color = color.withValues(alpha: color.a * 0.36)
      ..style = PaintingStyle.fill;

    final Offset center = Offset(size.width * 0.83, size.height * 1.04);
    final double baseRadius = size.height * 0.58;
    canvas.drawCircle(center, baseRadius, line);
    canvas.drawCircle(center, baseRadius * 0.72, line);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: baseRadius * 1.22),
      3.68,
      1.82,
      false,
      line,
    );

    final Path lowerWash = Path()
      ..moveTo(size.width * 0.34, size.height)
      ..lineTo(size.width, size.height * 0.56)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(lowerWash, fill);
  }

  @override
  bool shouldRepaint(covariant _ContinueReadingTexturePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

/// A readable and semantic progress indicator for the continue-reading card.
class ReadingProgressBar extends StatelessWidget {
  /// Creates a linear indicator for a normalized [progress] value.
  const ReadingProgressBar({required this.progress, super.key})
    : assert(progress >= 0 && progress <= 1);

  final double progress;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final int percentage = (progress * 100).round();

    return Semantics(
      label: '阅读进度 $percentage%',
      value: '$percentage%',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: AppRadii.pill,
          child: SizedBox(
            height: AppSpacing.readingProgressHeight,
            child: LinearProgressIndicator(
              value: progress,
              color: tokens.accent,
              backgroundColor: tokens.accent.withValues(alpha: 0.14),
            ),
          ),
        ),
      ),
    );
  }
}
