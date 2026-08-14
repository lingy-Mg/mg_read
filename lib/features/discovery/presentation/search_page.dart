import 'package:flutter/material.dart';

import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_destination_placeholder_page.dart';

/// Empty search destination reserved for the future discovery capability.
class SearchPage extends StatelessWidget {
  /// Creates the currently blank search page.
  const SearchPage({required this.onDestinationRequested, super.key});

  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context) {
    return AppDestinationPlaceholderPage(
      destination: AppNavigationDestination.search,
      onDestinationSelected: onDestinationRequested,
    );
  }
}
