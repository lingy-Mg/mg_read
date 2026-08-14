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
    this.showSelectionIndicator = true,
    this.height = AppSpacing.bottomNavigationHeight,
    this.topPadding = AppSpacing.compact + 2,
    super.key,
  });

  final AppNavigationDestination selected;
  final ValueChanged<AppNavigationDestination> onSelected;

  /// Whether the selected icon uses the soft pill used by root destinations.
  ///
  /// Reference-matched detail pages retain the same navigation component and
  /// semantics while using gold icon/text alone for their selected state.
  final bool showSelectionIndicator;
  final double height;
  final double topPadding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);

    return SizedBox(
      key: const Key('app-bottom-navigation'),
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.surface,
          border: Border(top: BorderSide(color: tokens.divider)),
        ),
        child: Padding(
          padding: EdgeInsets.only(top: topPadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: AppNavigationDestination.values
                .map(
                  (AppNavigationDestination destination) => Expanded(
                    child: _AppNavigationItem(
                      destination: destination,
                      selected: destination == selected,
                      onSelected: onSelected,
                      showSelectionIndicator: showSelectionIndicator,
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
    required this.showSelectionIndicator,
    required this.theme,
    required this.tokens,
  });

  final AppNavigationDestination destination;
  final bool selected;
  final ValueChanged<AppNavigationDestination> onSelected;
  final bool showSelectionIndicator;
  final ThemeData theme;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final _AppNavigationItemData data = _dataFor(destination);
    final Color foreground = selected
        ? tokens.accent
        : theme.colorScheme.onSurface.withValues(alpha: 0.82);
    final TextStyle labelStyle =
        (theme.textTheme.bodySmall ?? const TextStyle()).copyWith(
          color: foreground,
          fontSize: AppSpacing.bottomNavigationLabelSize,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          height: 1.1,
        );

    return Semantics(
      button: true,
      selected: selected,
      label: data.label,
      child: Material(
        color: Colors.transparent,
        child: InkResponse(
          key: ValueKey<String>('app-nav-${destination.name}'),
          onTap: () => onSelected(destination),
          radius: AppSpacing.minimumTouchTarget / 2,
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          focusColor: tokens.focusRing.withValues(alpha: 0.16),
          child: SizedBox(
            height: AppSpacing.bottomNavigationItemHeight,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AnimatedContainer(
                  key: ValueKey<String>(
                    'app-nav-indicator-${destination.name}',
                  ),
                  duration: AppMotion.navigationSelection,
                  curve: AppMotion.navigationCurve,
                  width: AppSpacing.bottomNavigationIndicatorWidth,
                  height: AppSpacing.bottomNavigationIndicatorHeight,
                  decoration: BoxDecoration(
                    color: selected && showSelectionIndicator
                        ? tokens.accentSoft
                        : Colors.transparent,
                    borderRadius: AppRadii.pill,
                  ),
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: AppMotion.navigationSelection,
                      switchInCurve: AppMotion.navigationCurve,
                      switchOutCurve: AppMotion.navigationReverseCurve,
                      transitionBuilder:
                          (Widget child, Animation<double> animation) {
                            return FadeTransition(
                              opacity: animation,
                              child: ScaleTransition(
                                scale: Tween<double>(
                                  begin: 0.88,
                                  end: 1,
                                ).animate(animation),
                                child: child,
                              ),
                            );
                          },
                      child: Icon(
                        key: ValueKey<bool>(selected),
                        selected ? data.selectedIcon : data.icon,
                        size: AppSpacing.bottomNavigationIconSize,
                        color: foreground,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.unit),
                AnimatedDefaultTextStyle(
                  duration: AppMotion.navigationSelection,
                  curve: AppMotion.navigationCurve,
                  style: labelStyle,
                  child: Text(data.label),
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
