import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';

/// Prominent current-reading card driven only by a display view-model.
class LibraryContinueReadingCard extends StatelessWidget {
  /// Creates the current-reading card for [data].
  const LibraryContinueReadingCard({
    required this.data,
    required this.onContinueReading,
    required this.onReadingHistory,
    super.key,
  });

  final LibraryContinueReadingViewData data;
  final VoidCallback onContinueReading;
  final VoidCallback onReadingHistory;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return Semantics(
      container: true,
      label: '${AppStrings.continueReadingTitle}，${data.title}，${data.chapter}',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppRadii.card,
          border: Border.all(color: tokens.divider.withValues(alpha: 0.8)),
        ),
        child: ClipRRect(
          borderRadius: AppRadii.card,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        tokens.featureSurface,
                        tokens.surface.withValues(alpha: 0.94),
                      ],
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
                padding: const EdgeInsets.all(AppSpacing.regular),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool stacked =
                        constraints.maxWidth <
                        AppSpacing.compactCardStackBreakpoint;
                    final Widget cover = LibraryBookCover(
                      title: data.title,
                      variant: data.coverVariant,
                      width: AppSpacing.continueReadingCoverWidth,
                      height: AppSpacing.continueReadingCoverHeight,
                    );
                    final Widget details = SizedBox(
                      height: AppSpacing.continueReadingCoverHeight,
                      child: _ContinueReadingDetails(
                        data: data,
                        onContinueReading: onContinueReading,
                      ),
                    );

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                AppStrings.continueReadingTitle,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontSize: 22,
                                  height: 1.2,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: onReadingHistory,
                              style: TextButton.styleFrom(
                                backgroundColor: tokens.surface.withValues(
                                  alpha: 0.52,
                                ),
                                foregroundColor: tokens.warning,
                                minimumSize: Size.zero,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.regular,
                                  vertical: AppSpacing.unit,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: const StadiumBorder(),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Text(
                                    AppStrings.readingHistoryLabel,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: tokens.warning,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.unit),
                                  const Icon(
                                    Icons.chevron_right_rounded,
                                    size: 18,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.compact),
                        if (stacked) ...<Widget>[
                          Center(child: cover),
                          const SizedBox(height: AppSpacing.regular),
                          details,
                        ] else
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              cover,
                              const SizedBox(width: AppSpacing.regular),
                              Expanded(child: details),
                            ],
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContinueReadingDetails extends StatelessWidget {
  const _ContinueReadingDetails({
    required this.data,
    required this.onContinueReading,
  });

  final LibraryContinueReadingViewData data;
  final VoidCallback onContinueReading;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final int percentage = (data.progress * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          data.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontSize: 22,
            height: 1.16,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: AppSpacing.unit / 2),
        Text(
          data.chapter,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: tokens.warning,
            fontSize: 15,
            height: 1.2,
          ),
        ),
        const Spacer(),
        Row(
          children: <Widget>[
            Expanded(child: ReadingProgressBar(progress: data.progress)),
            const SizedBox(width: AppSpacing.compact),
            Text(
              '$percentage%',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: tokens.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.unit),
        Text(
          data.lastReadLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: tokens.mutedText,
            fontSize: 13,
          ),
        ),
        const Spacer(),
        _ContinueReadingAction(onPressed: onContinueReading),
      ],
    );
  }
}

class _ContinueReadingAction extends StatelessWidget {
  const _ContinueReadingAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return SizedBox(
      width: AppSpacing.continueReadingActionWidth,
      height: AppSpacing.minimumTouchTarget,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: AppRadii.control,
          gradient: LinearGradient(
            colors: <Color>[tokens.accent, tokens.warning],
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('continue-reading-cta'),
            onTap: onPressed,
            borderRadius: AppRadii.control,
            child: Center(
              child: Text(
                AppStrings.continueReadingLabel,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onPrimary,
                  fontSize: 17,
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
      label: AppStrings.readingProgressLabel(percentage),
      value: '$percentage%',
      child: ExcludeSemantics(
        child: ClipRRect(
          borderRadius: AppRadii.pill,
          child: SizedBox(
            height: AppSpacing.compact,
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
