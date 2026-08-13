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
          child: SizedBox(
            height: AppSpacing.metadataTagHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.compact,
              ),
              child: Align(
                widthFactor: 1,
                alignment: Alignment.center,
                child: Text(
                  data.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: foreground,
                    fontSize: 10,
                    height: 1,
                  ),
                ),
              ),
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
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.unit),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LibraryBookCover(
                  title: data.title,
                  variant: data.coverVariant,
                  width: AppSpacing.listCoverWidth,
                  height: AppSpacing.listCoverHeight,
                ),
                const SizedBox(width: AppSpacing.compact + AppSpacing.unit),
                Expanded(
                  child: SizedBox(
                    height: AppSpacing.listCoverHeight,
                    child: Semantics(
                      button: true,
                      label: semanticLabel,
                      child: ExcludeSemantics(
                        child: _BookUpdateDetails(data: data, theme: theme),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.compact),
                _BookUpdateTrailing(
                  data: data,
                  onMore: onMore,
                  theme: theme,
                  tokens: tokens,
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
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Text(
            data.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 17,
              height: 1.12,
            ),
          ),
        ),
        if (data.chapter != null)
          Positioned(
            top: AppSpacing.section - AppSpacing.unit,
            left: 0,
            right: 0,
            child: Text(
              data.chapter!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.mutedText,
                fontSize: 13,
                height: 1.1,
              ),
            ),
          ),
        if (data.tags.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Wrap(
              spacing: AppSpacing.compact,
              runSpacing: AppSpacing.unit,
              children: data.tags
                  .map(
                    (LibraryMetadataTagViewData tag) =>
                        LibraryMetadataTag(data: tag),
                  )
                  .toList(growable: false),
            ),
          ),
      ],
    );
  }
}

class _BookUpdateTrailing extends StatelessWidget {
  const _BookUpdateTrailing({
    required this.data,
    required this.onMore,
    required this.theme,
    required this.tokens,
  });

  final LibraryBookUpdateViewData data;
  final VoidCallback onMore;
  final ThemeData theme;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppSpacing.bookUpdateTrailingWidth,
      height: AppSpacing.listCoverHeight,
      child: Stack(
        children: <Widget>[
          if (data.updatedLabel != null)
            Positioned(
              top: AppSpacing.section,
              left: 0,
              right: AppSpacing.section + AppSpacing.unit,
              child: Text(
                data.updatedLabel!,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.mutedText,
                  fontSize: 12,
                  height: 1.1,
                ),
              ),
            ),
          Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: AppSpacing.section,
              height: AppSpacing.section,
              child: IconButton(
                tooltip: AppStrings.bookMoreActionsLabel,
                onPressed: onMore,
                padding: EdgeInsets.zero,
                iconSize: 19,
                icon: const Icon(Icons.more_vert_rounded),
              ),
            ),
          ),
          if (data.hasUnreadUpdate)
            Positioned(
              top: AppSpacing.section + AppSpacing.unit,
              right: AppSpacing.compact,
              child: Semantics(
                label: AppStrings.unreadUpdateLabel,
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.notification,
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox(
                      width: AppSpacing.compact,
                      height: AppSpacing.compact,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
