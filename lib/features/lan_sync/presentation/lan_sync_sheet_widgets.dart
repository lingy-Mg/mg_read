/// 局域网同步各操作共用的底部弹层外壳。
///
/// 这里统一标题、说明、内边距和关闭入口；具体配对、传输与安装内容仍由
/// 各自业务面板呈现，避免不同入口逐渐分叉出不同的弹层结构。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

class LanSyncSheetFrame extends StatelessWidget {
  const LanSyncSheetFrame({
    required this.title,
    required this.description,
    required this.child,
    required this.onClose,
    this.footer,
    this.closeLabel = '关闭',
    super.key,
  });

  final String title;
  final String description;
  final Widget child;
  final VoidCallback onClose;
  final Widget? footer;
  final String closeLabel;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.88),
      child: SingleChildScrollView(
        key: const Key('lan-sync-sheet-scroll'),
        padding: const EdgeInsets.fromLTRB(AppSpacing.comfortable, AppSpacing.compact, AppSpacing.comfortable, AppSpacing.comfortable),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.unit),
            Text(description, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText)),
            const SizedBox(height: AppSpacing.regular),
            child,
            if (footer != null) ...<Widget>[const SizedBox(height: AppSpacing.regular), footer!],
            const SizedBox(height: AppSpacing.compact),
            TextButton(onPressed: onClose, child: Text(closeLabel)),
          ],
        ),
      ),
    ),
  );
}
