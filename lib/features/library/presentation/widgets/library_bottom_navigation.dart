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
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return SizedBox(
      key: const Key('library-bottom-navigation'),
      height: AppSpacing.bottomNavigationHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border(top: BorderSide(color: tokens.divider)),
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.compact + 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: LibraryNavigationDestination.values
                .map(
                  (LibraryNavigationDestination destination) => Expanded(
                    child: _LibraryNavigationItem(
                      destination: destination,
                      selected: destination == selected,
                      onSelected: onSelected,
                      theme: theme,
                      tokens: tokens,
                    ),
                  ),
                )
                .toList(growable: false),
          ),
        ),
      ),
    );
  }
}

class _LibraryNavigationItem extends StatelessWidget {
  const _LibraryNavigationItem({
    required this.destination,
    required this.selected,
    required this.onSelected,
    required this.theme,
    required this.tokens,
  });

  final LibraryNavigationDestination destination;
  final bool selected;
  final ValueChanged<LibraryNavigationDestination> onSelected;
  final ThemeData theme;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final _LibraryNavigationItemData data = _dataFor(destination);
    final Color foreground = selected
        ? tokens.accent
        : theme.colorScheme.onSurface.withValues(alpha: 0.82);

    return Semantics(
      button: true,
      selected: selected,
      label: data.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey<String>('library-nav-${destination.name}'),
          onTap: () => onSelected(destination),
          child: SizedBox(
            height: AppSpacing.section * 2 + AppSpacing.unit,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  selected ? data.selectedIcon : data.icon,
                  size: AppSpacing.bottomNavigationIconSize,
                  color: foreground,
                ),
                const SizedBox(height: AppSpacing.unit),
                Text(
                  data.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: foreground,
                    fontSize: AppSpacing.bottomNavigationLabelSize,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  _LibraryNavigationItemData _dataFor(LibraryNavigationDestination value) {
    return switch (value) {
      LibraryNavigationDestination.home => const _LibraryNavigationItemData(
        label: AppStrings.homeNavigationLabel,
        icon: Icons.home_outlined,
        selectedIcon: Icons.home_rounded,
      ),
      LibraryNavigationDestination.search => const _LibraryNavigationItemData(
        label: AppStrings.searchNavigationLabel,
        icon: Icons.search_rounded,
        selectedIcon: Icons.search_rounded,
      ),
      LibraryNavigationDestination.discover => const _LibraryNavigationItemData(
        label: AppStrings.discoverNavigationLabel,
        icon: Icons.explore_outlined,
        selectedIcon: Icons.explore_rounded,
      ),
      LibraryNavigationDestination.profile => const _LibraryNavigationItemData(
        label: AppStrings.profileNavigationLabel,
        icon: Icons.person_outline_rounded,
        selectedIcon: Icons.person_rounded,
      ),
    };
  }
}

class _LibraryNavigationItemData {
  const _LibraryNavigationItemData({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
