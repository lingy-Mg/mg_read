import 'package:flutter/material.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

import 'network_proxy_settings_page.dart';
import 'profile_general_setting_page.dart';

/// Empty secondary page for a profile setting whose capability is not ready.
///
/// The route is real and navigable now, while the page content makes the
/// unfinished capability explicit instead of silently swallowing the tap.
class ProfileSettingPlaceholderPage extends StatelessWidget {
  const ProfileSettingPlaceholderPage({
    required this.settingId,
    required this.onBackRequested,
    required this.onDestinationRequested,
    super.key,
  });

  final String settingId;
  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context) {
    if (settingId == 'network-proxy') {
      return NetworkProxySettingsPage(onBackRequested: onBackRequested);
    }
    return ProfileGeneralSettingPage(settingId: settingId, onBackRequested: onBackRequested);
  }
}
