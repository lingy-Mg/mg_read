import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// Backwards-compatible profile wrapper around the shared secondary header.
class ProfileDetailTopBar extends StatelessWidget {
  const ProfileDetailTopBar({
    required this.title,
    required this.onBack,
    super.key,
  });

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => AppSecondaryPageTopBar(
    title: title,
    onBack: onBack,
    headerKey: const Key('profile-detail-top-bar'),
    backButtonKey: const Key('profile-detail-back'),
  );
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
                maxWidth: AppSpacing.contentMaxWidth,
              ),
              child: AppBottomNavigation(
                selected: AppNavigationDestination.profile,
                onSelected: onSelected,
                height: AppDetailMetrics.bottomNavigationHeight,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
