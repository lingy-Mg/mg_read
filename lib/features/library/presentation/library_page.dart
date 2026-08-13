import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';

/// Temporary library landing page for the main-application skeleton.
class LibraryPage extends StatelessWidget {
  /// Creates the initial library page.
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text(AppStrings.libraryTitle)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: <Widget>[
                Semantics(
                  label: AppStrings.libraryIconLabel,
                  child: Icon(
                    Icons.auto_stories_outlined,
                    color: colors.primary,
                    size: 56,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  AppStrings.bootstrapTitle,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  AppStrings.bootstrapDescription,
                  style: theme.textTheme.bodyLarge,
                ),
                const SizedBox(height: 28),
                _InformationCard(
                  icon: Icons.menu_book_outlined,
                  title: AppStrings.readerIntegrationTitle,
                  description: AppStrings.readerIntegrationDescription,
                ),
                const SizedBox(height: 12),
                _InformationCard(
                  icon: Icons.account_tree_outlined,
                  title: AppStrings.nextStepsTitle,
                  description: AppStrings.nextStepsDescription,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InformationCard extends StatelessWidget {
  const _InformationCard({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(description, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
