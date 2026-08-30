/// 调试日志查看器的捕获与来源控件。
///
/// 职责：
/// - 展示受限详情捕获模式及其运行状态。
/// - 在 App 与 Runtime 的独立日志数据源之间切换。
///
/// 注意：
/// - 仅通过显式回调改变捕获状态，不直接访问诊断存储或 Runtime。
/// - 控件不保存异步状态，页面负责处理请求世代与生命周期。
///
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/diagnostics/application/diagnostics_viewer_gateway.dart';

/// Displays the explicit, bounded diagnostic detail-capture controls.
class DiagnosticsViewerCapturePanel extends StatelessWidget {
  const DiagnosticsViewerCapturePanel({
    required this.mode,
    required this.busy,
    required this.onModeSelected,
    this.warningCode,
    this.errorCode,
    super.key,
  });

  final DiagnosticsDetailMode mode;
  final bool busy;
  final String? warningCode;
  final String? errorCode;
  final ValueChanged<DiagnosticsDetailMode> onModeSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    final (String title, String description, IconData icon) = switch (mode) {
      DiagnosticsDetailMode.off => ('仅关键日志', '大 JSON、HTML、HTTP 正文和小说正文不会构造、缓存或写入。', Icons.shield_outlined),
      DiagnosticsDetailMode.memoryOnly => ('实时详情 · 仅内存', '最多 8 MiB / 15 分钟；关闭本窗口即停止并清空，不创建详情文件。', Icons.memory_rounded),
      DiagnosticsDetailMode.persistToText => ('详细日志 · TXT', '最多 64 MiB / 15 分钟；详情写入独立 TXT，关闭本窗口停止捕获。', Icons.description_outlined),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, color: tokens.warning),
                const SizedBox(width: AppSpacing.compact),
                Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
                if (busy) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: AppSpacing.compact),
            Text(description, style: theme.textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
            const SizedBox(height: AppSpacing.regular),
            Wrap(
              spacing: AppSpacing.compact,
              runSpacing: AppSpacing.compact,
              children: <Widget>[
                DiagnosticsViewerModeChip(
                  label: '仅关键',
                  selected: mode == DiagnosticsDetailMode.off,
                  enabled: !busy,
                  onSelected: () => onModeSelected(DiagnosticsDetailMode.off),
                ),
                DiagnosticsViewerModeChip(
                  label: '实时详情',
                  selected: mode == DiagnosticsDetailMode.memoryOnly,
                  enabled: !busy,
                  onSelected: () => onModeSelected(DiagnosticsDetailMode.memoryOnly),
                ),
                DiagnosticsViewerModeChip(
                  label: '保存详情 TXT',
                  selected: mode == DiagnosticsDetailMode.persistToText,
                  enabled: !busy,
                  onSelected: () => onModeSelected(DiagnosticsDetailMode.persistToText),
                ),
              ],
            ),
            if (warningCode != null || errorCode != null) ...<Widget>[
              const SizedBox(height: AppSpacing.compact),
              Text(
                errorCode != null ? '模式切换失败：$errorCode' : '部分日志源未开启：$warningCode',
                key: const Key('diagnostics-capture-message'),
                style: theme.textTheme.bodySmall?.copyWith(color: errorCode != null ? theme.colorScheme.error : tokens.warning),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class DiagnosticsViewerModeChip extends StatelessWidget {
  const DiagnosticsViewerModeChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onSelected,
    super.key,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) =>
      ChoiceChip(label: Text(label), selected: selected, onSelected: enabled ? (_) => onSelected() : null);
}
