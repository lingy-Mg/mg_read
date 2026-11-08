/// TV-side reception overview. Addresses are transient host projections only;
/// this widget does not enable reception or change any device trust policy.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mg_read/app/app_theme.dart';

import 'companion_widgets.dart';

class CompanionReceiverView extends StatelessWidget {
  const CompanionReceiverView({
    required this.enabled,
    required this.label,
    required this.addresses,
    required this.controllers,
    required this.tools,
    this.error,
    super.key,
  });
  final bool enabled;
  final String label;
  final String? error;
  final List<String> addresses, controllers;
  final Widget tools;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(AppSpacing.compactPagePadding),
    children: [
      if (error != null) ...[
        CompanionPanel(
          child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
        const SizedBox(height: AppSpacing.comfortable),
      ],
      CompanionPanel(
        tonal: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CompanionStatusBadge(label: enabled ? 'TV 接收已开启' : 'TV 接收未开启', active: enabled),
            const SizedBox(height: AppSpacing.comfortable),
            Icon(Icons.connected_tv_rounded, size: 48, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: AppSpacing.regular),
            Text(label, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.compact),
            Text(enabled ? '已准备好接收手机选片和遥控。' : '当前无法接收手机连接，请确认已进入 TV 模式。'),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.section),
      CompanionPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('从手机连接', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.regular),
            const Text('手机与本机连接同一局域网，在手机的“局域网 TV 播放”页选择本机；也可从视频播放器右上角发送影片。'),
            const SizedBox(height: AppSpacing.comfortable),
            Text('手动连接地址', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.compact),
            if (addresses.isEmpty) const Text('暂未取得局域网地址，请检查网络后刷新。'),
            for (final address in addresses)
              Row(
                children: [
                  Expanded(child: SelectableText(address, style: Theme.of(context).textTheme.titleMedium)),
                  IconButton(
                    tooltip: '复制地址',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: address));
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('TV 地址已复制')));
                    },
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.comfortable),
      CompanionPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已连接的手机 · ${controllers.length}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.regular),
            if (controllers.isEmpty) const Text('等待手机连接。无需扫码或在电视端批准。'),
            for (final controller in controllers)
              ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.smartphone_rounded), title: Text(controller)),
            const SizedBox(height: AppSpacing.compact),
            Text('手机断开不影响 TV 播放，观看进度按各自设备管理。', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.section),
      tools,
    ],
  );
}
