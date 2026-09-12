/// 局域网同步空闲态的主视觉、角色入口与使用提示。
///
/// 仅负责视觉和点击意图；网络状态与操作生命周期仍由页面控制器持有。
library;

import 'package:flutter/material.dart';

import 'package:mg_read/app/app_theme.dart';

const String _transferTipsAsset = 'assets/illustrations/page_backdrops/lan_sync_transfer_tips.png';

class LanSyncOverviewCard extends StatelessWidget {
  const LanSyncOverviewCard({this.networkReady = false, super.key});

  final bool networkReady;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    final statusColor = networkReady ? tokens.dataSourceAccent : tokens.mutedText;
    return DecoratedBox(
      key: const Key('lan-sync-overview'),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF6EE),
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        border: Border.all(color: tokens.accent.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Row(
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(color: tokens.surface, borderRadius: AppRadii.detailControl),
              child: SizedBox.square(dimension: 42, child: Icon(Icons.wifi_rounded, color: statusColor)),
            ),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    networkReady ? '已连接局域网' : '正在检测局域网',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppSpacing.unit),
                  Text(
                    networkReady ? '附近的已配对设备可自动发现' : '打开后会检测本地网络和可信设备',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                  ),
                ],
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(color: statusColor.withValues(alpha: 0.12), borderRadius: AppRadii.pill),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.compact, vertical: AppSpacing.unit),
                child: Text(networkReady ? '可发现' : '检测中', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: statusColor)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class LanSyncRoleChooser extends StatelessWidget {
  const LanSyncRoleChooser({required this.onSend, required this.onReceive, super.key});

  final VoidCallback onSend;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final List<Widget> cards = <Widget>[
        _RoleCard(
          key: const Key('lan-sync-send'),
          icon: Icons.file_upload_outlined,
          title: '发送数据',
          description: '将本机的数据源、书架和阅读进度发送到其他设备',
          tint: const Color(0xFFF47A1F),
          background: const Color(0xFFFFF8F1),
          onTap: onSend,
        ),
        _RoleCard(
          key: const Key('lan-sync-receive'),
          icon: Icons.file_download_outlined,
          title: '接收数据',
          description: '从其他设备接收数据，预览版本与冲突后再导入',
          tint: const Color(0xFF3E82E6),
          background: const Color(0xFFF4F8FF),
          onTap: onReceive,
        ),
      ];
      if (constraints.maxWidth < 700) {
        return Column(
          children: <Widget>[
            for (int index = 0; index < cards.length; index++) ...<Widget>[
              if (index > 0) const SizedBox(height: AppSpacing.regular),
              cards[index],
            ],
          ],
        );
      }
      final double gap = AppSpacing.regular;
      final double cardWidth = (constraints.maxWidth - gap * (cards.length - 1)) / cards.length;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: cards.map((Widget card) => SizedBox(width: cardWidth, child: card)).toList(),
      );
    },
  );
}

class LanSyncSectionHeader extends StatelessWidget {
  const LanSyncSectionHeader({required this.title, required this.description, super.key});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 5,
          height: 32,
          margin: const EdgeInsets.only(top: 2, right: AppSpacing.regular),
          decoration: BoxDecoration(color: tokens.dataSourceAccent, borderRadius: AppRadii.pill),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: AppSpacing.unit),
              Text(description, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
            ],
          ),
        ),
      ],
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.tint,
    required this.background,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String description;
  final Color tint;
  final Color background;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Material(
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        side: BorderSide(color: tint.withValues(alpha: 0.22)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 136),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.comfortable),
            child: Row(
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(color: tint.withValues(alpha: 0.11), borderRadius: AppRadii.detailControl),
                  child: SizedBox.square(dimension: 58, child: Icon(icon, size: 30, color: tint)),
                ),
                const SizedBox(width: AppSpacing.comfortable),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(title, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: AppSpacing.unit),
                      Text(description, style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.compact),
                Icon(Icons.chevron_right_rounded, color: tint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LanSyncTipsCard extends StatelessWidget {
  const LanSyncTipsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 700;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            border: Border.all(color: tokens.divider),
            boxShadow: <BoxShadow>[BoxShadow(color: tokens.shadow.withValues(alpha: 0.06), blurRadius: 22, offset: const Offset(0, 8))],
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.comfortable),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          DecoratedBox(
                            decoration: BoxDecoration(color: tokens.accentSoft, shape: BoxShape.circle),
                            child: SizedBox.square(
                              dimension: 42,
                              child: Icon(Icons.tips_and_updates_outlined, color: tokens.dataSourceAccent, size: 22),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.regular),
                          Text('使用提示', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.regular),
                      const _TipLine(number: 1, text: '确保所有设备连接到同一 Wi-Fi 或私有局域网'),
                      const _TipLine(number: 2, text: '已配对设备使用认证连接，不会上传云端'),
                      const _TipLine(number: 3, text: '传输期间请保持应用在前台，并等待完成提示'),
                      const _TipLine(number: 4, text: '临时传输仍为首版协议：首版传输不加密，请仅在可信网络内使用'),
                    ],
                  ),
                ),
                if (wide) ...<Widget>[
                  const SizedBox(width: AppSpacing.section),
                  SizedBox(
                    width: 260,
                    height: 180,
                    child: Image.asset(_transferTipsAsset, fit: BoxFit.contain, filterQuality: FilterQuality.high),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TipLine extends StatelessWidget {
  const _TipLine({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final AppThemeTokens tokens = AppThemeTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.compact),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(color: tokens.dataSourceAccent, shape: BoxShape.circle),
            child: SizedBox.square(
              dimension: 24,
              child: Center(
                child: Text(
                  '$number',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.compact),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: tokens.mutedText)),
          ),
        ],
      ),
    );
  }
}
