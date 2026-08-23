import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

/// Shared centered loading presentation used by feature pages.
class AppLoadingState extends StatelessWidget {
  const AppLoadingState({
    required this.label,
    required this.message,
    this.progressKey,
    super.key,
  });

  final String label;
  final String message;
  final Key? progressKey;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Center(
      child: Semantics(
        label: label,
        liveRegion: true,
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CircularProgressIndicator(key: progressKey, color: tokens.accent),
              const SizedBox(height: AppSpacing.regular),
              Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
