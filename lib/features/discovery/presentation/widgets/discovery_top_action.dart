/// 发现页顶部操作按钮。
///
/// 职责：
/// - 统一发现顶栏的图标尺寸、触摸命中区与语义标签。
///
/// 注意：
/// - 只响应显式回调，不能访问页面状态或发起 IO。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

class DiscoveryTopAction extends StatelessWidget {
  const DiscoveryTopAction({required this.tooltip, required this.icon, required this.onPressed, super.key});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
            child: SizedBox.square(
              dimension: AppSpacing.topBarActionSize,
              child: Icon(icon, size: 21, color: theme.colorScheme.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}
