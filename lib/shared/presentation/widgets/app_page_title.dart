import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

/// Shared page-level title typography for the four primary destinations.
class AppPageTitle extends StatelessWidget {
  /// Creates a semantic page heading with the application-wide title style.
  const AppPageTitle({required this.title, super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Text(
        title,
        style: theme.textTheme.titleLarge?.copyWith(
          fontSize: AppSpacing.pageTitleSize,
          fontWeight: FontWeight.w600,
          height: 1.15,
          letterSpacing: -0.3,
        ),
      ),
    );
  }
}
