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
              color: tokens.featureSurface,
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
                    Icon(Icons.hub_outlined, color: tokens.accent, size: 20),
                    const SizedBox(width: AppSpacing.regular),
                    Expanded(
                      child: Text(
                        AppStrings.manageSourcesLabel,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: 16,
                          height: 1.2,
                        ),
                      ),
                    ),
                    if (sourceLabel != null) ...<Widget>[
                      Text(
                        sourceLabel,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: tokens.mutedText,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.compact),
                    ],
                    const Icon(Icons.chevron_right_rounded),
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
