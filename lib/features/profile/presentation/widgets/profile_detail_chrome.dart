import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

/// The measured back/title bar shared by profile detail pages.
class ProfileDetailTopBar extends StatelessWidget {
  const ProfileDetailTopBar({
    required this.title,
    required this.onBack,
    super.key,
  });

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      key: const Key('profile-detail-top-bar'),
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
            child: Semantics(
              button: true,
              label: AppStrings.detailBackLabel,
              child: Material(
                color: Colors.transparent,
                child: InkResponse(
                  key: const Key('profile-detail-back'),
                  onTap: onBack,
                  radius: AppDetailMetrics.backButtonExtent / 2,
                  child: SizedBox(
                    width: AppDetailMetrics.backButtonExtent,
                    height: AppDetailMetrics.backButtonExtent,
                    child: Center(
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 22,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Keeps the shared app navigation phone-width and profile-selected on details.
class ProfileDetailBottomBar extends StatelessWidget {
  const ProfileDetailBottomBar({required this.onSelected, super.key});

  final ValueChanged<AppNavigationDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    return SizedBox(
      height: AppDetailMetrics.bottomNavigationHeight + bottomInset,
      child: ColoredBox(
        color: tokens.pageBackground,
        child: SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppDetailMetrics.viewportWidth,
              ),
              child: AppBottomNavigation(
                selected: AppNavigationDestination.profile,
                onSelected: onSelected,
                showSelectionIndicator: false,
                height: AppDetailMetrics.bottomNavigationHeight,
                topPadding: AppDetailMetrics.bottomNavigationTopPadding,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
