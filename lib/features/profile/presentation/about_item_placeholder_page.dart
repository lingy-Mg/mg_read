import 'package:flutter/material.dart';

import 'package:mg_read/shared/presentation/app_navigation_destination.dart';
import 'package:mg_read/shared/presentation/widgets/app_secondary_page_chrome.dart';

/// Empty third-level page for an item under “关于我们”.
class AboutItemPlaceholderPage extends StatelessWidget {
  const AboutItemPlaceholderPage({
    required this.itemId,
    required this.onBackRequested,
    required this.onDestinationRequested,
    super.key,
  });

  final String itemId;
  final VoidCallback onBackRequested;
  final ValueChanged<AppNavigationDestination> onDestinationRequested;

  @override
  Widget build(BuildContext context) {
    final _AboutItemCopy copy = _copyFor(itemId);
    return AppSecondaryPlaceholderPage(
      title: copy.title,
      description: copy.description,
      onBack: onBackRequested,
      onDestinationSelected: onDestinationRequested,
    );
  }
}

_AboutItemCopy _copyFor(String itemId) => switch (itemId) {
  'update' => const _AboutItemCopy(title: '检查更新', description: '应用版本检查将在这里提供。'),
  'agreement' => const _AboutItemCopy(
    title: '用户协议',
    description: '用户协议内容将在这里提供。',
  ),
  'privacy' => const _AboutItemCopy(
    title: '隐私政策',
    description: '隐私政策内容将在这里提供。',
  ),
  'licenses' => const _AboutItemCopy(
    title: '开源许可',
    description: '开源许可信息将在这里提供。',
  ),
  'contact' => const _AboutItemCopy(title: '联系我们', description: '联系渠道将在这里提供。'),
  _ => const _AboutItemCopy(title: '关于我们', description: '这个页面正在建设中。'),
};

class _AboutItemCopy {
  const _AboutItemCopy({required this.title, required this.description});

  final String title;
  final String description;
}
