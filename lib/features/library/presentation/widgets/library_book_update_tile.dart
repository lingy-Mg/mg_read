import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';
import 'package:mg_read/features/library/presentation/widgets/library_book_cover.dart';

/// A source or availability tag with a theme-derived semantic treatment.
class LibraryMetadataTag extends StatelessWidget {
  /// Creates one compact metadata tag.
  const LibraryMetadataTag({required this.data, super.key});

  final LibraryMetadataTagViewData data;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final (Color background, Color foreground) = switch (data.tone) {
      LibraryMetadataTone.neutral => (tokens.mutedSurface, tokens.mutedText),
      LibraryMetadataTone.accent => (tokens.accentSoft, tokens.accent),
      LibraryMetadataTone.success => (
        tokens.success.withValues(alpha: 0.16),
        tokens.success,
      ),
    };

    return Semantics(
      label: data.label,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: AppRadii.pill,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.regular,
              vertical: AppSpacing.compact,
            ),
            child: Text(
              data.label,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
        ),
      ),
    );
  }
}

/// A responsive book update row with visible and semantic unread state.
class LibraryBookUpdateTile extends StatelessWidget {
  /// Creates a presentation-only update row for [data].
  const LibraryBookUpdateTile({
    required this.data,
    required this.onOpen,
    required this.onMore,
    super.key,
  });

  final LibraryBookUpdateViewData data;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final String semanticLabel = AppStrings.bookUpdateLabel(
      title: data.title,
      chapter: data.chapter,
      updatedLabel: data.updatedLabel,
      hasUnreadUpdate: data.hasUnreadUpdate,
    );

    return Semantics(
      container: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadii.surface,
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LibraryBookCover(
                  title: data.title,
                  variant: data.coverVariant,
                  width: AppSpacing.listCoverWidth,
                  height: AppSpacing.listCoverHeight,
                ),
                const SizedBox(width: AppSpacing.regular),
                Expanded(
                  child: Semantics(
                    button: true,
                    label: semanticLabel,
                    child: ExcludeSemantics(
                      child: _BookUpdateDetails(data: data, theme: theme),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.compact),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    IconButton(
                      tooltip: AppStrings.bookMoreActionsLabel,
                      onPressed: onMore,
                      icon: const Icon(Icons.more_vert_rounded),
                    ),
                    if (data.updatedLabel != null) ...<Widget>[
                      const SizedBox(height: AppSpacing.compact),
                      Text(
                        data.updatedLabel!,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tokens.mutedText,
                        ),
                      ),
                    ],
                    if (data.hasUnreadUpdate) ...<Widget>[
                      const SizedBox(height: AppSpacing.regular),
                      Semantics(
                        label: AppStrings.unreadUpdateLabel,
                        child: ExcludeSemantics(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: tokens.notification,
                              shape: BoxShape.circle,
                            ),
                            child: const SizedBox(
                              width: AppSpacing.regular,
                              height: AppSpacing.regular,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BookUpdateDetails extends StatelessWidget {
  const _BookUpdateDetails({required this.data, required this.theme});

  final LibraryBookUpdateViewData data;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.listCoverHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            data.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
          if (data.chapter != null) ...<Widget>[
            const SizedBox(height: AppSpacing.compact),
            Text(
              data.chapter!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.mutedText,
              ),
            ),
          ],
          if (data.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.regular),
            Wrap(
              spacing: AppSpacing.compact,
              runSpacing: AppSpacing.compact,
              children: data.tags
                  .map(
                    (LibraryMetadataTagViewData tag) =>
                        LibraryMetadataTag(data: tag),
                  )
                  .toList(growable: false),
            ),
          ],
        ],
      ),
    );
  }
}
