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
          color: tokens.featureSurface,
          borderRadius: AppRadii.card,
          border: Border.all(color: tokens.divider),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: tokens.shadow,
              blurRadius: AppSpacing.comfortable,
              offset: const Offset(0, AppSpacing.compact),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.comfortable),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool stacked =
                  constraints.maxWidth < AppSpacing.compactCardStackBreakpoint;
              final Widget cover = LibraryBookCover(
                title: data.title,
                variant: data.coverVariant,
                width: AppSpacing.continueReadingCoverWidth,
                height: AppSpacing.continueReadingCoverHeight,
              );
              final Widget details = _ContinueReadingDetails(
                data: data,
                onContinueReading: onContinueReading,
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          AppStrings.continueReadingTitle,
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: onReadingHistory,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(AppStrings.readingHistoryLabel),
                            SizedBox(width: AppSpacing.compact),
                            Icon(Icons.chevron_right_rounded),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.comfortable),
                  if (stacked) ...<Widget>[
                    Center(child: cover),
                    const SizedBox(height: AppSpacing.comfortable),
                    details,
                  ] else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        cover,
                        const SizedBox(width: AppSpacing.comfortable),
                        Expanded(child: details),
                      ],
                    ),
                ],
              );
            },
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
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: AppSpacing.compact),
        Text(
          data.chapter,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge?.copyWith(color: tokens.warning),
        ),
        const SizedBox(height: AppSpacing.section),
        Row(
          children: <Widget>[
            Expanded(child: ReadingProgressBar(progress: data.progress)),
            const SizedBox(width: AppSpacing.regular),
            Text(
              '$percentage%',
              style: theme.textTheme.titleMedium?.copyWith(
                color: tokens.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.regular),
        Text(
          data.lastReadLabel,
          style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
        ),
        const SizedBox(height: AppSpacing.comfortable),
        SizedBox(
          width: double.infinity,
          height: AppSpacing.minimumTouchTarget,
          child: FilledButton(
            key: const Key('continue-reading-cta'),
            onPressed: onContinueReading,
            child: const Text(AppStrings.continueReadingLabel),
          ),
        ),
      ],
    );
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
              backgroundColor: tokens.divider,
            ),
          ),
        ),
      ),
    );
  }
}
