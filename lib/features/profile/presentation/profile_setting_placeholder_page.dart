/// 个人设置路由分派：专属平台页面优先，其余交给设置分类与配置页。
/// 跳转与返回通过显式回调交给应用层，此处不持有设置或运行时状态。
library;

import 'dart:io';
import 'package:flutter/material.dart';
import 'desktop_runtime_settings_page.dart';
import 'package:mg_read/shared/presentation/app_navigation_destination.dart';

import 'network_proxy_settings_page.dart';
import 'node_runtime_settings_page.dart';
import 'profile_general_setting_page.dart';

/// Preserves existing setting URLs while dispatching real category and detail pages.
class ProfileSettingPlaceholderPage extends StatelessWidget {
  const ProfileSettingPlaceholderPage({
    required this.settingId,
    required this.onBackRequested,
    required this.onDestinationRequested,
    required this.onSettingRequested,
    super.key,
  });

  final String settingId;
  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;
  final ValueChanged<String> onSettingRequested;

  @override
  Widget build(BuildContext context) {
    if (settingId == 'node-runtime' && (Platform.isWindows || Platform.isMacOS)) {
      return DesktopRuntimeSettingsPage(onBackRequested: onBackRequested);
    }
    if (settingId == 'node-runtime') {
      return NodeRuntimeSettingsPage(onBackRequested: onBackRequested);
    }
    if (settingId == 'network-proxy') {
      return NetworkProxySettingsPage(onBackRequested: onBackRequested);
    }
    return ProfileGeneralSettingPage(settingId: settingId, onBackRequested: onBackRequested, onSettingRequested: onSettingRequested);
  }
}
