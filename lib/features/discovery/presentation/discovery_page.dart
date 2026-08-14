import 'package:flutter/material.dart';

import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_destination_placeholder_page.dart';

/// Empty discovery destination reserved for the future discovery capability.
class DiscoveryPage extends StatelessWidget {
  /// Creates the currently blank discovery page.
  const DiscoveryPage({required this.onDestinationRequested, super.key});

  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context) {
    return AppDestinationPlaceholderPage(
      destination: AppNavigationDestination.discover,
      onDestinationSelected: onDestinationRequested,
    );
  }
}
