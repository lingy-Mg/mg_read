import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

/// Bottom destinations for the mobile-first root feature surfaces.
class AppBottomNavigation extends StatelessWidget {
  /// Creates a navigation bar with one selected destination.
  const AppBottomNavigation({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final AppNavigationDestination selected;
  final ValueChanged<AppNavigationDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return SizedBox(
      key: const Key('app-bottom-navigation'),
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
            children: AppNavigationDestination.values
                .map(
                  (AppNavigationDestination destination) => Expanded(
                    child: _AppNavigationItem(
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

class _AppNavigationItem extends StatelessWidget {
  const _AppNavigationItem({
    required this.destination,
    required this.selected,
    required this.onSelected,
    required this.theme,
    required this.tokens,
  });

  final AppNavigationDestination destination;
  final bool selected;
  final ValueChanged<AppNavigationDestination> onSelected;
  final ThemeData theme;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final _AppNavigationItemData data = _dataFor(destination);
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
          key: ValueKey<String>('app-nav-${destination.name}'),
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

  _AppNavigationItemData _dataFor(AppNavigationDestination value) {
    return switch (value) {
      AppNavigationDestination.home => const _AppNavigationItemData(
        label: AppStrings.homeNavigationLabel,
        icon: Icons.home_outlined,
        selectedIcon: Icons.home_rounded,
      ),
      AppNavigationDestination.search => const _AppNavigationItemData(
        label: AppStrings.searchNavigationLabel,
        icon: Icons.search_rounded,
        selectedIcon: Icons.search_rounded,
      ),
      AppNavigationDestination.discover => const _AppNavigationItemData(
        label: AppStrings.discoverNavigationLabel,
        icon: Icons.explore_outlined,
        selectedIcon: Icons.explore_rounded,
      ),
      AppNavigationDestination.profile => const _AppNavigationItemData(
        label: AppStrings.profileNavigationLabel,
        icon: Icons.person_outline_rounded,
        selectedIcon: Icons.person_rounded,
      ),
    };
  }
}

class _AppNavigationItemData {
  const _AppNavigationItemData({
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}
