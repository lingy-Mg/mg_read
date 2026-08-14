import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';

/// Entry card for the future source-management feature.
class LibrarySourceManagerCard extends StatelessWidget {
  /// Creates a non-networking source-management entry.
  const LibrarySourceManagerCard({
    required this.sourceCount,
    required this.onPressed,
    super.key,
  });

  final int? sourceCount;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final Color sourceSurface = Color.lerp(
      tokens.featureSurface,
      tokens.surface,
      0.45,
    )!;
    final Color sourceTitleColor = Color.lerp(
      theme.colorScheme.onSurface,
      tokens.mutedText,
      0.35,
    )!;
    final String? sourceLabel = sourceCount == null
        ? null
        : AppStrings.availableSourcesLabel(sourceCount!);

    return Semantics(
      button: true,
      label: sourceLabel == null
          ? AppStrings.manageSourcesLabel
          : '${AppStrings.manageSourcesLabel}，$sourceLabel',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: AppRadii.surface,
          child: Ink(
            decoration: BoxDecoration(
              color: sourceSurface,
              borderRadius: AppRadii.surface,
            ),
            child: SizedBox(
              height: AppSpacing.sourceManagerHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.comfortable,
                  vertical: AppSpacing.compact,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.hub_outlined, color: tokens.mutedText, size: 16),
                    const SizedBox(width: AppSpacing.comfortable),
                    Expanded(
                      child: Text(
                        AppStrings.manageSourcesLabel,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          height: 1.2,
                          color: sourceTitleColor,
                        ),
                      ),
                    ),
                    if (sourceLabel != null) ...<Widget>[
                      Text(
                        sourceLabel,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: tokens.mutedText.withValues(alpha: 0.78),
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.compact),
                    ],
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: tokens.mutedText,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
