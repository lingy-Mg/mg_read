/// 局域网同步空闲态的概览与角色入口。
///
/// 仅负责视觉和点击意图；网络状态与操作生命周期仍由页面控制器持有。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

class LanSyncOverviewCard extends StatelessWidget {
  const LanSyncOverviewCard({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      key: const Key('lan-sync-overview'),
      decoration: BoxDecoration(
        color: tokens.featureSurface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.accent.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.comfortable),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                SizedBox.square(
                  dimension: 48,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: tokens.accent, borderRadius: AppRadii.detailControl),
                    child: Icon(Icons.devices_rounded, color: theme.colorScheme.onPrimary, size: 25),
                  ),
                ),
                const SizedBox(width: AppSpacing.regular),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('设备间传输', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: AppSpacing.unit),
                      Text('无需云端，同一网络内直接发送', style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                    ],
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(color: tokens.surface, borderRadius: AppRadii.pill),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.regular, vertical: AppSpacing.compact),
                    child: Text(
                      '局域网',
                      style: theme.textTheme.bodySmall?.copyWith(color: tokens.accent, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.regular),
            Text('仅在可信的家庭或办公局域网使用。当前传输不加密，不会发送 Cookie、凭据、正文或封面文件。', style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
          ],
        ),
      ),
    );
  }
}

class LanSyncRoleChooser extends StatelessWidget {
  const LanSyncRoleChooser({required this.onSend, required this.onReceive, this.onScan, super.key});

  final VoidCallback onSend;
  final VoidCallback onReceive;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      _RoleCard(
        key: const Key('lan-sync-send'),
        icon: Icons.upload_rounded,
        title: '发送数据',
        description: '把本机已安装或正在开发的数据源、书架和阅读进度发送给另一台设备。',
        onTap: onSend,
      ),
      const SizedBox(height: AppSpacing.regular),
      _RoleCard(
        key: const Key('lan-sync-receive'),
        icon: Icons.download_rounded,
        title: '接收数据',
        description: '发现发送设备，预览插件版本和书架冲突后再导入。',
        onTap: onReceive,
      ),
      if (onScan != null) ...<Widget>[
        const SizedBox(height: AppSpacing.regular),
        _RoleCard(
          key: const Key('lan-sync-receive-qr'),
          icon: Icons.qr_code_scanner_rounded,
          title: '扫码接收',
          description: '扫描发送设备显示的二维码，直接建立局域网连接。',
          onTap: onScan!,
        ),
      ],
    ],
  );
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.icon, required this.title, required this.description, required this.onTap, super.key});

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
        boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.07), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: AppRadii.detailCard,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.comfortable),
            child: Row(
              children: <Widget>[
                SizedBox.square(
                  dimension: 44,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: AppRadii.detailControl),
                    child: Icon(icon, size: 23, color: tokens.accent),
                  ),
                ),
                const SizedBox(width: AppSpacing.regular),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: theme.textTheme.titleMedium),
                      const SizedBox(height: AppSpacing.unit),
                      Text(description, style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: tokens.mutedText),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
