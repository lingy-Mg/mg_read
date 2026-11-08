/// Feature-local surfaces, navigation and connection gates for the TV workspace.
/// Widgets render explicit state and callbacks; they own no discovery or leases.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';

class CompanionPanel extends StatelessWidget {
  const CompanionPanel({required this.child, this.tonal = false, this.padding = AppSpacing.comfortable, super.key});
  final Widget child;
  final bool tonal;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: tonal ? colors.primaryContainer.withValues(alpha: .35) : colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadii.card,
        side: BorderSide(color: tonal ? colors.primary.withValues(alpha: .18) : colors.outlineVariant.withValues(alpha: .6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: EdgeInsets.all(padding), child: child),
    );
  }
}

class CompanionStatusBadge extends StatelessWidget {
  const CompanionStatusBadge({required this.label, this.active = false, super.key});
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = active ? colors.primary : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: .08), borderRadius: AppRadii.pill),
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(Icons.circle, size: 6, color: color),
            ),
            TextSpan(text: '  $label'),
          ],
        ),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
      ),
    );
  }
}

class CompanionPageTabs extends StatelessWidget {
  const CompanionPageTabs({required this.selected, required this.onChanged, super.key});
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.unit),
      decoration: BoxDecoration(color: colors.surfaceContainerLow, borderRadius: AppRadii.card),
      child: Row(
        children: [
          for (final item in const [
            (Icons.tv_rounded, '设备'),
            (Icons.settings_remote_outlined, '遥控'),
            (Icons.video_library_outlined, 'TV 找片'),
          ].indexed)
            Expanded(
              child: Semantics(
                button: true,
                selected: selected == item.$1,
                child: Material(
                  color: selected == item.$1 ? colors.surface : Colors.transparent,
                  borderRadius: AppRadii.control,
                  child: InkWell(
                    key: Key('companion-tab-${item.$1}'),
                    borderRadius: AppRadii.control,
                    onTap: () => onChanged(item.$1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppSpacing.regular, horizontal: AppSpacing.unit),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(item.$2.$1, size: 22, color: selected == item.$1 ? colors.primary : colors.onSurfaceVariant),
                          const SizedBox(height: AppSpacing.unit),
                          Text(
                            item.$2.$2,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: selected == item.$1 ? colors.primary : colors.onSurfaceVariant,
                              fontWeight: selected == item.$1 ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CompanionConnectionRequired extends StatelessWidget {
  const CompanionConnectionRequired({required this.catalog, required this.reconnecting, required this.onDevices, super.key});
  final bool catalog, reconnecting;
  final VoidCallback onDevices;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(AppSpacing.compactPagePadding),
    children: [
      CompanionPanel(
        tonal: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: CompanionStatusBadge(label: reconnecting ? '连接恢复中' : '等待连接 TV'),
            ),
            const SizedBox(height: AppSpacing.section),
            Icon(
              catalog ? Icons.video_library_outlined : Icons.settings_remote_rounded,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: AppSpacing.comfortable),
            Text(
              reconnecting
                  ? '正在恢复与 TV 的连接'
                  : catalog
                  ? '用手机找片，在电视上看'
                  : '把手机变成 TV 遥控器',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.compact),
            Text(
              reconnecting
                  ? '连接恢复后即可继续操作。也可以返回设备页，选择其他电视。'
                  : catalog
                  ? '连接后，搜索 TV 上的影视来源，浏览收藏和观看记录，选好直接播放。'
                  : '连接后，可调节进度和音量、切换选集，也能用手机输入搜索内容。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.section),
            FilledButton.icon(onPressed: onDevices, icon: const Icon(Icons.tv_rounded), label: Text(reconnecting ? '查看设备' : '去连接 TV')),
          ],
        ),
      ),
    ],
  );
}

class CompanionTools extends StatelessWidget {
  const CompanionTools({required this.onHistory, required this.onSync, super.key});
  final VoidCallback onHistory;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) => CompanionPanel(
    padding: 0,
    child: Column(
      children: [
        ListTile(
          key: const Key('companion-history'),
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.unit),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.card),
          leading: const Icon(Icons.history_rounded),
          title: const Text('观看记录'),
          subtitle: const Text('查看本机与 TV 的观看进度'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onHistory,
        ),
        const Divider(height: 1, indent: AppSpacing.comfortable, endIndent: AppSpacing.comfortable),
        ListTile(
          key: const Key('companion-sync'),
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.comfortable, vertical: AppSpacing.unit),
          shape: const RoundedRectangleBorder(borderRadius: AppRadii.card),
          leading: const Icon(Icons.sync_rounded),
          title: const Text('设备同步与来源传输'),
          subtitle: const Text('管理设备，向 TV 传输数据源'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onSync,
        ),
      ],
    ),
  );
}
