import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/library/presentation/library_home_view_data.dart';

/// Bottom destinations for the home UI's presentation-only navigation state.
class LibraryBottomNavigation extends StatelessWidget {
  /// Creates a navigation bar with a single selected destination.
  const LibraryBottomNavigation({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final LibraryNavigationDestination selected;
  final ValueChanged<LibraryNavigationDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(top: BorderSide(color: tokens.divider)),
      ),
      child: NavigationBar(
        height: AppSpacing.bottomNavigationHeight,
        selectedIndex: selected.index,
        onDestinationSelected: (int index) {
          onSelected(LibraryNavigationDestination.values[index]);
        },
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded),
            label: AppStrings.homeNavigationLabel,
          ),
          NavigationDestination(
            icon: Icon(Icons.search_rounded),
            label: AppStrings.searchNavigationLabel,
          ),
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            selectedIcon: Icon(Icons.explore_rounded),
            label: AppStrings.discoverNavigationLabel,
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: AppStrings.profileNavigationLabel,
          ),
        ],
      ),
    );
  }
}
