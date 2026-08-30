import 'package:flutter/material.dart';

import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

import 'network_proxy_settings_page.dart';

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
    final _SettingCopy copy = _copyFor(settingId);
    return AppSecondaryPlaceholderPage(
      title: copy.title,
      description: copy.description,
      onBack: onBackRequested,
      onDestinationSelected: onDestinationRequested,
    );
  }
}

_SettingCopy _copyFor(String settingId) => switch (settingId) {
  'reading-settings' => const _SettingCopy(title: '阅读设置', description: '字体、排版与翻页设置将在这里提供。'),
  'downloads-cache' => const _SettingCopy(title: '缓存管理', description: '数据源网页与文件缓存、封面缓存将在这里统一管理。'),
  'theme-appearance' => const _SettingCopy(title: '主题与外观', description: '主题、显示与外观选项将在这里提供。'),
  'privacy-permissions' => const _SettingCopy(title: '隐私与权限', description: '隐私说明与系统权限管理将在这里提供。'),
  'data-backup' => const _SettingCopy(title: '数据备份与同步', description: '备份与跨设备同步将在这里提供。'),
  _ => const _SettingCopy(title: '设置', description: '这个设置页面正在建设中。'),
};

class _SettingCopy {
  const _SettingCopy({required this.title, required this.description});

  final String title;
  final String description;
}
