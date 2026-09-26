/// Recording controls for the diagnostics page.
/// The page owns asynchronous changes, file admission and capture lifetime;
/// these controls keep detailed collection separate from explicit file saving.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';

class DiagnosticsViewerRecordingPanel extends StatelessWidget {
  const DiagnosticsViewerRecordingPanel({
    required this.detailed,
    required this.saving,
    required this.busy,
    required this.onDetailedChanged,
    required this.onSavingChanged,
    this.errorCode,
    super.key,
  });
  final bool detailed;
  final bool saving;
  final bool busy;
  final ValueChanged<bool> onDetailedChanged;
  final ValueChanged<bool> onSavingChanged;
  final String? errorCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.detailCard,
        side: BorderSide(color: tokens.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.regular),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(detailed ? Icons.troubleshoot_rounded : Icons.shield_outlined, color: tokens.accent, size: 28),
                const SizedBox(width: AppSpacing.compact),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(detailed ? '正在记录排查过程' : '仅关注异常', style: theme.textTheme.titleMedium),
                      const SizedBox(height: AppSpacing.unit),
                      Text(
                        detailed ? '临时记录操作过程与诊断字段，可离开此页复现问题，15 分钟后自动停止。' : '只保留最近的警告与错误，普通操作不记录。',
                        style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText),
                      ),
                      const SizedBox(height: AppSpacing.compact),
                      Text(
                        saving ? '文件保存已开启 · 可在历史记录中导出' : '仅在内存中保留 · 不写出日志文件',
                        style: theme.textTheme.labelMedium?.copyWith(color: saving ? tokens.warning : tokens.mutedText),
                      ),
                    ],
                  ),
                ),
                if (busy) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
          ),
          Divider(height: 1, color: tokens.divider),
          SwitchListTile.adaptive(
            key: const Key('diagnostics-detail-switch'),
            secondary: const Icon(Icons.manage_search_rounded),
            title: const Text('详细记录'),
            subtitle: const Text('排查时开启，15 分钟后停止'),
            value: detailed,
            onChanged: busy ? null : onDetailedChanged,
          ),
          SwitchListTile.adaptive(
            key: const Key('diagnostics-master-switch'),
            secondary: const Icon(Icons.save_outlined),
            title: const Text('保存到文件'),
            subtitle: Text(saving ? '保存当前记录级别，关闭后立即停止' : '需要重启后回看或导出时开启'),
            value: saving,
            onChanged: busy ? null : onSavingChanged,
          ),
          if (errorCode != null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.regular),
              child: Text(
                '设置未完成，请重试（$errorCode）',
                key: const Key('diagnostics-capture-message'),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
