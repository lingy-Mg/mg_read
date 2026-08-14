import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

/// An intentionally blank top-level destination while its feature is pending.
///
/// The page keeps the shared navigation visible, so its selected state remains
/// tied to the current route rather than a temporary state on another page.
class AppDestinationPlaceholderPage extends StatelessWidget {
  /// Creates an empty surface for [destination].
  const AppDestinationPlaceholderPage({
    required this.destination,
    required this.onDestinationSelected,
    super.key,
  });

  final AppNavigationDestination destination;
  final ValueChanged<AppNavigationDestination> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Semantics(
          container: true,
          scopesRoute: true,
          explicitChildNodes: true,
          label: _labelFor(destination),
          child: SizedBox.expand(
            key: ValueKey<String>('app-empty-${destination.name}-page'),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(
          selected: destination,
          onSelected: onDestinationSelected,
        ),
      ),
    );
  }

  String _labelFor(AppNavigationDestination value) {
    return switch (value) {
      AppNavigationDestination.home => AppStrings.homeNavigationLabel,
      AppNavigationDestination.search => AppStrings.searchNavigationLabel,
      AppNavigationDestination.discover => AppStrings.discoverNavigationLabel,
      AppNavigationDestination.profile => AppStrings.profileNavigationLabel,
    };
  }
}
