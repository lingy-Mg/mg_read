import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

/// The common title bar for profile-owned secondary pages.
///
/// The bar deliberately owns only presentation chrome. The surrounding page
/// must place it inside a top [SafeArea] so the title and back action remain
/// below the Android status bar.
class AppSecondaryPageTopBar extends StatelessWidget {
  const AppSecondaryPageTopBar({
    required this.title,
    required this.onBack,
    this.actions = const <Widget>[],
    this.headerKey,
    this.backButtonKey,
    super.key,
  });

  final String title;
  final VoidCallback onBack;
  final List<Widget> actions;
  final Key? headerKey;
  final Key? backButtonKey;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      key: headerKey,
      height: AppDetailMetrics.topBarHeight,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Center(
            child: Semantics(
              header: true,
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
          Positioned(
            left: AppDetailMetrics.backButtonLeft,
            top:
                (AppDetailMetrics.topBarHeight -
                    AppDetailMetrics.backButtonExtent) /
                2,
            child: AppSecondaryPageIconButton(
              key: backButtonKey,
              label: '返回',
              icon: Icons.arrow_back_ios_new_rounded,
              onPressed: onBack,
            ),
          ),
          if (actions.isNotEmpty)
            Positioned(
              right: AppDetailMetrics.backButtonLeft,
              top:
                  (AppDetailMetrics.topBarHeight -
                      AppDetailMetrics.backButtonExtent) /
                  2,
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
        ],
      ),
    );
  }
}

/// A 48dp action slot used by secondary-page title bars.
class AppSecondaryPageIconButton extends StatelessWidget {
  const AppSecondaryPageIconButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: IconButton(
          onPressed: onPressed,
          tooltip: label,
          icon: Icon(icon),
          iconSize: 22,
          color: theme.colorScheme.onSurface,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(
            width: AppDetailMetrics.backButtonExtent,
            height: AppDetailMetrics.backButtonExtent,
          ),
        ),
      ),
    );
  }
}

/// A small, consistent shell for secondary pages that are not implemented yet.
class AppSecondaryPlaceholderPage extends StatelessWidget {
  const AppSecondaryPlaceholderPage({
    required this.title,
    required this.description,
    required this.onBack,
    required this.onDestinationSelected,
    super.key,
  });

  final String title;
  final String description;
  final VoidCallback onBack;
  final ValueChanged<AppNavigationDestination> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppDetailMetrics.viewportWidth,
            ),
            child: Column(
              children: <Widget>[
                AppSecondaryPageTopBar(
                  key: const Key('secondary-placeholder-top-bar'),
                  title: title,
                  onBack: onBack,
                  backButtonKey: const Key('secondary-placeholder-back'),
                ),
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(
                        AppDetailMetrics.horizontalPadding,
                      ),
                      child: Semantics(
                        container: true,
                        label: '$title，功能建设中',
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              Icons.construction_outlined,
                              size: 40,
                              color: tokens.mutedText,
                            ),
                            const SizedBox(height: AppSpacing.regular),
                            Text(
                              '功能建设中',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: AppSpacing.unit),
                            Text(
                              description,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: tokens.mutedText),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(
          selected: AppNavigationDestination.profile,
          onSelected: onDestinationSelected,
          showSelectionIndicator: false,
        ),
      ),
    );
  }
}
