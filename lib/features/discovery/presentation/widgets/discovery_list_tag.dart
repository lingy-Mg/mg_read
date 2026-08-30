/// 发现列表标签。
///
/// 职责：
/// - 统一发现分类列表和搜索结果列表中的标签外观。
/// - 保持标签尺寸紧凑，并让文字在胶囊内居中显示。
///
/// 注意：
/// - 组件只负责展示文本，不处理点击、网络或持久化。
/// - IntrinsicWidth 用于保留标签按内容收缩的宽度，避免 Wrap 中被拉伸。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

class DiscoveryListTag extends StatelessWidget {
  const DiscoveryListTag({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    return IntrinsicWidth(
      child: Container(
        height: AppSpacing.discoveryListTagHeight,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: tokens.accentSoft.withValues(alpha: 0.62), borderRadius: AppRadii.pill),
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.accent, fontSize: AppTypography.discoveryListTag),
        ),
      ),
    );
  }
}
