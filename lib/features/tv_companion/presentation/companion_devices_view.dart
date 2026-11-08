/// Device workspace renders live endpoint projections and connection state.
/// The page owns sorting, expiry filtering, IO and discovery subscriptions.
library;

import 'package:flutter/material.dart';
import 'package:mg_read/app/app_theme.dart';

import '../domain/companion_models.dart';
import 'companion_widgets.dart';

class CompanionDevicesView extends StatelessWidget {
  const CompanionDevicesView({
    required this.endpoints,
    required this.status,
    required this.selectedId,
    required this.selectedLabel,
    required this.stale,
    required this.busy,
    required this.discovering,
    required this.onRefresh,
    required this.onManual,
    required this.onConnect,
    required this.onDisconnect,
    required this.onRemote,
    required this.onCatalog,
    required this.tools,
    this.error,
    this.playingTitle,
    super.key,
  });

  final List<CompanionEndpoint> endpoints;
  final CompanionConnectionStatus status;
  final String? selectedId, error, playingTitle;
  final String selectedLabel;
  final bool stale, busy, discovering;
  final VoidCallback onRefresh, onManual, onDisconnect, onRemote, onCatalog;
  final ValueChanged<CompanionEndpoint> onConnect;
  final Widget tools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = status == CompanionConnectionStatus.connected;
    final pending = status == CompanionConnectionStatus.connecting || status == CompanionConnectionStatus.reconnecting;
    final available = endpoints.where((e) => !connected || e.deviceId != selectedId).toList();
    return ListView(
      key: const PageStorageKey('companion-devices-scroll'),
      padding: const EdgeInsets.all(AppSpacing.compactPagePadding),
      children: [
        if (connected || pending)
          _connection(context, connected: connected)
        else
          CompanionPanel(
            tonal: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const CompanionStatusBadge(label: '局域网直连', active: true),
                          const SizedBox(height: AppSpacing.regular),
                          Text('连接 TV\n大屏继续看', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800, height: 1.3)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.regular),
                      child: Icon(Icons.connected_tv_rounded, size: 64, color: theme.colorScheme.primary),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.regular),
                Text('手机选片与遥控，电视独立播放。', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: AppSpacing.regular),
                const Wrap(
                  spacing: AppSpacing.regular,
                  runSpacing: AppSpacing.compact,
                  children: [
                    _FeatureLabel(Icons.play_circle_outline_rounded, '大屏播放'),
                    _FeatureLabel(Icons.touch_app_outlined, '手机遥控'),
                    _FeatureLabel(Icons.search_rounded, 'TV 找片'),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.section),
        Row(
          children: [
            Expanded(
              child: Text(connected ? '其他电视' : '附近的电视', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (available.isNotEmpty) Text('${available.length} 台', style: theme.textTheme.labelMedium),
            IconButton(
              key: const Key('companion-refresh'),
              tooltip: '重新搜索',
              onPressed: busy ? null : onRefresh,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        if (error != null) ...[
          CompanionPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('连接遇到问题', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.error)),
                const SizedBox(height: AppSpacing.compact),
                Text(error!),
                TextButton.icon(onPressed: busy ? null : onRefresh, icon: const Icon(Icons.refresh_rounded), label: const Text('重试')),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.regular),
        ],
        if (available.isEmpty)
          CompanionPanel(
            child: Column(
              children: [
                Icon(busy ? Icons.wifi_find_rounded : Icons.tv_rounded, size: 36, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(height: AppSpacing.regular),
                Text(
                  busy
                      ? '正在寻找局域网中的 TV'
                      : connected
                      ? '暂未发现其他电视'
                      : '还没有发现电视',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: AppSpacing.compact),
                Text(
                  busy ? '正在准备发现服务，请稍候' : '请在同一网络的电视上打开 MgRead，并进入 TV 模式。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (discovering && !busy) ...[const SizedBox(height: AppSpacing.regular), const CompanionStatusBadge(label: '自动发现已开启')],
              ],
            ),
          )
        else
          for (final endpoint in available) ...[_device(context, endpoint), const SizedBox(height: AppSpacing.compact)],
        const SizedBox(height: AppSpacing.regular),
        OutlinedButton.icon(
          key: const Key('companion-manual'),
          onPressed: busy ? null : onManual,
          icon: const Icon(Icons.add_link_rounded),
          label: const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.unit),
            child: Text('手动输入 TV 地址'),
          ),
        ),
        const SizedBox(height: AppSpacing.section),
        _guide(context),
        const SizedBox(height: AppSpacing.section),
        Text('更多功能', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.regular),
        tools,
        const SizedBox(height: AppSpacing.compact),
      ],
    );
  }

  Widget _connection(BuildContext context, {required bool connected}) {
    final theme = Theme.of(context);
    return CompanionPanel(
      tonal: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: CompanionStatusBadge(
              label: !connected
                  ? status == CompanionConnectionStatus.reconnecting
                        ? '正在重新连接'
                        : '正在连接'
                  : stale
                  ? '状态更新延迟'
                  : '已连接',
              active: connected && !stale,
            ),
          ),
          const SizedBox(height: AppSpacing.comfortable),
          Row(
            children: [
              Icon(Icons.connected_tv_rounded, size: 42, color: theme.colorScheme.primary),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: Text(selectedLabel, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.regular),
          Text(
            !connected
                ? '连接建立后即可遥控和选片。'
                : stale
                ? '正在等待 TV 的最新状态，遥控操作暂时停用。'
                : playingTitle != null
                ? '当前视频 · $playingTitle'
                : 'TV 已就绪，可以遥控或挑选影片。',
            style: theme.textTheme.bodyMedium,
          ),
          if (connected) ...[
            const SizedBox(height: AppSpacing.comfortable),
            Wrap(
              spacing: AppSpacing.compact,
              runSpacing: AppSpacing.compact,
              children: [
                FilledButton.icon(onPressed: onRemote, icon: const Icon(Icons.settings_remote_outlined), label: const Text('打开遥控')),
                OutlinedButton.icon(onPressed: onCatalog, icon: const Icon(Icons.search_rounded), label: const Text('去 TV 找片')),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.compact),
          if (connected)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(onPressed: busy ? null : onDisconnect, child: const Text('断开连接')),
            ),
          if (connected) Text('断开手机连接后，TV 仍会继续播放。', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _device(BuildContext context, CompanionEndpoint endpoint) => CompanionPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.tv_rounded, color: Theme.of(context).colorScheme.primary, size: 30),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(endpoint.label, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.unit),
                  Text('${endpoint.address}:${endpoint.port}', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.regular),
        FilledButton.tonalIcon(
          key: Key('companion-connect-${endpoint.deviceId}'),
          onPressed: busy ? null : () => onConnect(endpoint),
          icon: const Icon(Icons.cast_connected_rounded),
          label: const Text('连接电视'),
        ),
      ],
    ),
  );

  Widget _guide(BuildContext context) => CompanionPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('连接只需三步', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: AppSpacing.comfortable),
        for (final step in const [
          ('同一网络', '手机与电视连接到可以互相访问的局域网。'),
          ('打开 TV 模式', '在电视上打开 MgRead，切换到 TV 模式。'),
          ('选择电视', '在上方连接设备，即可遥控、找片和播放。'),
        ].indexed) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text('${step.$1 + 1}', style: Theme.of(context).textTheme.labelSmall),
              ),
              const SizedBox(width: AppSpacing.regular),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(step.$2.$1, style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: AppSpacing.unit),
                    Text(
                      step.$2.$2,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.regular),
        ],
        const Divider(height: AppSpacing.comfortable),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const PageStorageKey('companion-connection-help'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: AppSpacing.compact),
            title: const Text('还是找不到 TV？'),
            leading: const Icon(Icons.help_outline_rounded, size: 20),
            children: const [Text('检查是否使用了访客 Wi-Fi、路由器设备隔离或防火墙。也可在 TV 的“局域网 TV 播放”页查看地址，通过上方入口手动连接。无需扫码配对或在电视端批准。')],
          ),
        ),
      ],
    ),
  );
}

class _FeatureLabel extends StatelessWidget {
  const _FeatureLabel(this.icon, this.label);
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
      const SizedBox(width: AppSpacing.unit),
      Text(label, style: Theme.of(context).textTheme.labelMedium),
    ],
  );
}
