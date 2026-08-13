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
              horizontal: AppSpacing.compact,
              vertical: AppSpacing.unit / 2,
            ),
            child: Text(
              data.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: foreground,
                fontSize: 12,
                height: 1.2,
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
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppSpacing.listCoverHeight),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            data.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 18,
              height: 1.16,
            ),
          ),
          if (data.chapter != null) ...<Widget>[
            const SizedBox(height: AppSpacing.unit),
            Text(
              data.chapter!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.mutedText,
                fontSize: 14,
                height: 1.2,
              ),
            ),
          ],
          if (data.tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpacing.unit),
            Wrap(
              spacing: AppSpacing.compact,
              runSpacing: AppSpacing.unit,
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
      width: AppSpacing.section * 3,
      height: AppSpacing.listCoverHeight,
      child: Stack(
        children: <Widget>[
          Align(
            alignment: Alignment.topRight,
            child: SizedBox(
              width: AppSpacing.section + AppSpacing.compact,
              height: AppSpacing.section + AppSpacing.compact,
              child: IconButton(
                tooltip: AppStrings.bookMoreActionsLabel,
                onPressed: onMore,
                padding: EdgeInsets.zero,
                iconSize: 20,
                icon: const Icon(Icons.more_vert_rounded),
              ),
            ),
          ),
          if (data.updatedLabel != null)
            Positioned(
              top: AppSpacing.page,
              right: 0,
              child: Text(
                data.updatedLabel!,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: tokens.mutedText,
                  fontSize: 13,
                ),
              ),
            ),
          if (data.hasUnreadUpdate)
            Positioned(
              right: AppSpacing.unit,
              bottom: AppSpacing.unit,
              child: Semantics(
                label: AppStrings.unreadUpdateLabel,
                child: ExcludeSemantics(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: tokens.notification,
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox(
                      width: AppSpacing.compact + AppSpacing.unit,
                      height: AppSpacing.compact + AppSpacing.unit,
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
