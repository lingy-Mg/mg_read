import 'package:flutter/material.dart';

import 'package:mg_read/app/app_strings.dart';
import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/app/app_theme_mode_scope.dart';
import 'package:mg_read/features/profile/presentation/profile_view_data.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_overview_card.dart';
import 'package:mg_read/features/profile/presentation/widgets/profile_settings_list.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_bottom_navigation.dart';

/// The mobile-first profile and settings surface.
///
/// It intentionally renders a visual fixture only. Account, notifications,
/// cloud synchronization, and settings persistence remain separate future
/// Runtime capabilities and are not inferred by this UI.
class ProfilePage extends StatefulWidget {
  /// Creates the profile page and delegates root navigation to the app layer.
  const ProfilePage({this.onHomeRequested, this.onToggleTheme, super.key});

  final VoidCallback? onHomeRequested;

  /// Test-friendly override for the app-level temporary theme action.
  final VoidCallback? onToggleTheme;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final ScrollController _scrollController = ScrollController();
  String? _actionFeedback;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppSpacing.mobileContentMaxWidth,
            ),
            child: Scrollbar(
              controller: _scrollController,
              child: ListView(
                key: const Key('profile-page-content'),
                controller: _scrollController,
                primary: false,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.compactPagePadding,
                  AppSpacing.homeContentTopPadding,
                  AppSpacing.compactPagePadding,
                  AppSpacing.page,
                ),
                children: <Widget>[
                  ProfileTopBar(
                    onToggleTheme: () => _handleToggleTheme(context),
                    onNotifications: _showUnavailableMessage,
                  ),
                  const SizedBox(height: AppSpacing.regular),
                  ProfileOverviewCard(
                    data: ProfileFixtures.preview,
                    onEdit: _showUnavailableMessage,
                    onSyncPressed: _showUnavailableMessage,
                  ),
                  if (_actionFeedback != null) ...<Widget>[
                    const SizedBox(height: AppSpacing.regular),
                    _ProfileActionFeedback(
                      message: _actionFeedback!,
                      onDismiss: () {
                        setState(() {
                          _actionFeedback = null;
                        });
                      },
                    ),
                  ],
                  const SizedBox(height: AppSpacing.comfortable + 5),
                  _ProfileSectionTitle(
                    title: AppStrings.profileSettingsManagementTitle,
                  ),
                  const SizedBox(height: AppSpacing.unit / 2),
                  ProfileSettingsList(
                    items: ProfileFixtures.preview.settings,
                    onItemPressed: (_) => _showUnavailableMessage(),
                  ),
                  const SizedBox(height: AppSpacing.compact),
                  _ProfileSectionTitle(
                    title: AppStrings.profileAboutSectionTitle,
                  ),
                  const SizedBox(height: AppSpacing.unit),
                  ProfileSettingsList(
                    items: ProfileFixtures.preview.about,
                    onItemPressed: (_) => _showUnavailableMessage(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AppBottomNavigation(
          selected: AppNavigationDestination.profile,
          onSelected: _handleDestinationSelected,
        ),
      ),
    );
  }

  void _handleToggleTheme(BuildContext context) {
    final VoidCallback? callback = widget.onToggleTheme;
    if (callback != null) {
      callback();
      return;
    }
    AppThemeModeScope.of(context).onToggleTheme(Theme.of(context).brightness);
  }

  void _handleDestinationSelected(AppNavigationDestination destination) {
    if (destination == AppNavigationDestination.profile) {
      return;
    }
    if (destination == AppNavigationDestination.home) {
      final VoidCallback? homeRequested = widget.onHomeRequested;
      if (homeRequested != null) {
        homeRequested();
        return;
      }
    }
    _showUnavailableMessage();
  }

  void _showUnavailableMessage() {
    setState(() {
      _actionFeedback = AppStrings.actionUnavailableMessage;
    });
  }
}

/// The profile page header with the temporary theme and notification actions.
class ProfileTopBar extends StatelessWidget {
  /// Creates the title and fixed-size top actions.
  const ProfileTopBar({
    required this.onToggleTheme,
    required this.onNotifications,
    super.key,
  });

  final VoidCallback onToggleTheme;
  final VoidCallback onNotifications;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Semantics(
            header: true,
            child: Text(
              AppStrings.profileNavigationLabel,
              style: theme.textTheme.displaySmall?.copyWith(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                height: 1.15,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ),
        _ProfileTopBarAction(
          key: const Key('theme-mode-toggle'),
          tooltip: theme.brightness == Brightness.dark
              ? AppStrings.switchToLightThemeLabel
              : AppStrings.switchToDarkThemeLabel,
          onPressed: onToggleTheme,
          icon: theme.brightness == Brightness.dark
              ? Icons.light_mode_outlined
              : Icons.dark_mode_outlined,
        ),
        const SizedBox(width: AppSpacing.compact),
        _ProfileTopBarAction(
          tooltip: AppStrings.profileNotificationsLabel,
          onPressed: onNotifications,
          icon: Icons.notifications_none_rounded,
        ),
      ],
    );
  }
}

class _ProfileTopBarAction extends StatelessWidget {
  const _ProfileTopBarAction({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    super.key,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Semantics(
      button: true,
      label: tooltip,
      onTap: onPressed,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkResponse(
            onTap: onPressed,
            excludeFromSemantics: true,
            radius: AppSpacing.topBarActionSize / 2,
            child: SizedBox(
              width: AppSpacing.topBarActionSize,
              height: AppSpacing.topBarActionSize,
              child: Center(
                child: Icon(
                  icon,
                  size: AppSpacing.topBarActionIconSize,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileSectionTitle extends StatelessWidget {
  const _ProfileSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      header: true,
      child: Text(
        title,
        style: theme.textTheme.titleMedium?.copyWith(
          color: tokens.mutedText,
          fontSize: 18,
          fontWeight: FontWeight.w400,
          height: 1.2,
        ),
      ),
    );
  }
}

class _ProfileActionFeedback extends StatelessWidget {
  const _ProfileActionFeedback({
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          borderRadius: AppRadii.control,
          border: Border.all(color: tokens.accent),
        ),
        child: Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.regular,
            top: AppSpacing.compact,
            right: AppSpacing.compact,
            bottom: AppSpacing.compact,
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, color: tokens.accent),
              const SizedBox(width: AppSpacing.compact),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              IconButton(
                tooltip: AppStrings.dismissLabel,
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
