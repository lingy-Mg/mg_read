/// 已配对设备列表、首次配对面板和逐设备策略编辑。
///

/// 本文件只负责交互呈现；发现、密钥和同步事务仍由 DeviceSyncController 持有。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

class PairedDevicesSection extends StatelessWidget {
  const PairedDevicesSection({
    required this.state,
    required this.supportsScanner,
    required this.onBeginPairing,
    required this.onApprovePairing,
    required this.onRejectPairing,
    required this.onCancelPairing,
    required this.onSync,
    required this.onManage,
    this.onScanPairing,
    super.key,
  });

  final DeviceSyncState state;
  final bool supportsScanner;
  final VoidCallback onBeginPairing;
  final VoidCallback? onScanPairing;
  final VoidCallback onApprovePairing;
  final VoidCallback onRejectPairing;
  final VoidCallback onCancelPairing;
  final void Function(String deviceId, PairedSyncOperation operation) onSync;
  final ValueChanged<PairedDevice> onManage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = AppThemeTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: AppRadii.detailCard,
        border: Border.all(color: tokens.divider),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('我的设备', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
                if (!state.pairingBusy)
                  TextButton.icon(
                    key: const Key('device-sync-add-device'),
                    onPressed: onBeginPairing,
                    icon: const Icon(Icons.add_link_rounded),
                    label: const Text('添加设备'),
                  ),
              ],
            ),
            Text(
              state.started ? '两端打开 MgRead 后会自动同步；任意一端也可选择双向同步、拉取或推送。' : '正在准备自动发现服务…',
              style: theme.textTheme.bodySmall?.copyWith(color: tokens.mutedText),
            ),
            if (supportsScanner && !state.pairingBusy) ...<Widget>[
              const SizedBox(height: AppSpacing.compact),
              OutlinedButton.icon(
                key: const Key('device-sync-scan-pairing'),
                onPressed: onScanPairing,
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('扫描另一台设备的配对码'),
              ),
            ],
            if (state.pairingPhase != DevicePairingPhase.idle) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              _PairingPanel(
                state: state,
                onApprove: onApprovePairing,
                onReject: onRejectPairing,
                onCancel: onCancelPairing,
                onRetry: onBeginPairing,
              ),
            ],
            if (state.devices.isEmpty && state.pairingPhase == DevicePairingPhase.idle) ...<Widget>[
              const SizedBox(height: AppSpacing.regular),
              const Card(
                child: ListTile(leading: Icon(Icons.info_outline), title: Text('还没有已配对设备。首次配对后，即使路由器重新分配 IP 也会自动发现。')),
              ),
            ],
            for (final device in state.devices) ...<Widget>[
              const Divider(height: AppSpacing.comfortable),
              _PairedDeviceTile(
                device: device,
                online: state.onlineDeviceIds.contains(device.deviceId),
                busy: state.busyDeviceId == device.deviceId,
                canStartSync: state.busyDeviceId == null,
                onSync: (operation) => onSync(device.deviceId, operation),
                onManage: () => onManage(device),
              ),
            ],
            if (state.lastMessage case final message?) ...<Widget>[
              const SizedBox(height: AppSpacing.compact),
              Text(
                message,
                key: const Key('device-sync-last-message'),
                style: theme.textTheme.bodySmall?.copyWith(color: state.lastErrorCode == null ? tokens.mutedText : theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PairedDeviceTile extends StatelessWidget {
  const _PairedDeviceTile({
    required this.device,
    required this.online,
    required this.busy,
    required this.canStartSync,
    required this.onSync,
    required this.onManage,
  });

  final PairedDevice device;
  final bool online;
  final bool busy;
  final bool canStartSync;
  final ValueChanged<PairedSyncOperation> onSync;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.of(context);
    final actionsEnabled = online && canStartSync;
    const compactButtonStyle = ButtonStyle(visualDensity: VisualDensity.compact);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Badge(
              backgroundColor: online ? Colors.green : tokens.mutedText,
              smallSize: 9,
              child: Icon(device.platform == PairedDevicePlatform.windows ? Icons.computer_rounded : Icons.phone_android_rounded),
            ),
            const SizedBox(width: AppSpacing.regular),
            Expanded(
              child: InkWell(
                key: Key('device-sync-manage-${device.deviceId}'),
                onTap: onManage,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.compact),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(device.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        busy
                            ? '正在同步'
                            : online
                            ? '在线 · ${device.autoSync ? '自动同步已开启' : '仅手动'}'
                            : '离线 · 打开另一台设备后可同步',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText),
                      ),
                      if (device.lastSyncAtUtc != null)
                        Text(_lastSyncText(device), style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tokens.mutedText)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.compact),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: AppSpacing.compact,
            runSpacing: AppSpacing.unit,
            children: <Widget>[
              FilledButton.tonal(
                key: Key('device-sync-bidirectional-${device.deviceId}'),
                style: compactButtonStyle,
                onPressed: actionsEnabled && device.canReceive && device.canSend ? () => onSync(PairedSyncOperation.bidirectional) : null,
                child: const Text('同步'),
              ),
              OutlinedButton(
                key: Key('device-sync-pull-${device.deviceId}'),
                style: compactButtonStyle,
                onPressed: actionsEnabled && device.canReceive ? () => onSync(PairedSyncOperation.pull) : null,
                child: const Text('拉取'),
              ),
              OutlinedButton(
                key: Key('device-sync-push-${device.deviceId}'),
                style: compactButtonStyle,
                onPressed: actionsEnabled && device.canSend ? () => onSync(PairedSyncOperation.push) : null,
                child: const Text('推送'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({
    required this.state,
    required this.onApprove,
    required this.onReject,
    required this.onCancel,
    required this.onRetry,
  });

  final DeviceSyncState state;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final offer = state.pairingOffer;
    return DecoratedBox(
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLow, borderRadius: AppRadii.detailControl),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.regular),
        child: Column(
          children: <Widget>[
            if (state.pairingPhase == DevicePairingPhase.creatingOffer || state.pairingPhase == DevicePairingPhase.joining) ...<Widget>[
              const CircularProgressIndicator(),
              const SizedBox(height: AppSpacing.compact),
              Text(state.pairingPhase == DevicePairingPhase.joining ? '正在建立加密配对连接' : '正在生成一次性配对码'),
            ] else if (state.pairingPhase == DevicePairingPhase.showingOffer && offer != null) ...<Widget>[
              Text('扫描以配对', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: AppSpacing.regular),
              ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.compact),
                  child: QrImageView(
                    key: const Key('device-sync-pairing-qr'),
                    data: LanPairingQrPayload.encode(offer),
                    version: QrVersions.auto,
                    size: 220,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.compact),
              const Text('二维码十分钟内有效。另一台设备扫码后，请核对双方验证码。'),
              TextButton(onPressed: onCancel, child: const Text('取消')),
            ] else if (state.pairingPhase == DevicePairingPhase.confirming) ...<Widget>[
              Text('是否配对 ${state.pairingPeer?.label ?? '这台设备'}？'),
              const SizedBox(height: AppSpacing.compact),
              SelectableText(
                state.pairingCode ?? '------',
                key: const Key('device-sync-pairing-code'),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 5, fontWeight: FontWeight.w700),
              ),
              const Text('确认两台设备显示的六位数字一致。此授权只需要一次。'),
              const SizedBox(height: AppSpacing.regular),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(onPressed: onReject, child: const Text('不是这台设备')),
                  ),
                  const SizedBox(width: AppSpacing.compact),
                  Expanded(
                    child: FilledButton(onPressed: onApprove, child: const Text('一致，允许配对')),
                  ),
                ],
              ),
            ] else if (state.pairingPhase == DevicePairingPhase.waitingApproval) ...<Widget>[
              Text('等待 ${state.pairingPeer?.label ?? '另一台设备'} 批准'),
              const SizedBox(height: AppSpacing.compact),
              SelectableText(
                state.pairingCode ?? '------',
                key: const Key('device-sync-pairing-code'),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 5, fontWeight: FontWeight.w700),
              ),
              const Text('请确认另一台设备显示相同数字，并在那边允许配对。'),
              TextButton(onPressed: onCancel, child: const Text('取消')),
            ] else if (state.pairingPhase == DevicePairingPhase.completed) ...<Widget>[
              const Icon(Icons.verified_rounded, color: Colors.green, size: 32),
              const SizedBox(height: AppSpacing.compact),
              const Text('配对完成。以后两端打开即可自动同步。'),
              TextButton(onPressed: onCancel, child: const Text('完成')),
            ] else if (state.pairingPhase == DevicePairingPhase.failed) ...<Widget>[
              Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: AppSpacing.compact),
              Text(state.lastErrorCode == 'device_pairing_offer_expired' ? '配对码已过期，请重新生成。' : '配对未完成，请确认两台设备在同一局域网后重试。'),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  TextButton(onPressed: onCancel, child: const Text('取消')),
                  FilledButton.tonal(onPressed: onRetry, child: const Text('重新配对')),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class DeviceSettingsSheet extends ConsumerWidget {
  const DeviceSettingsSheet({required this.deviceId, super.key});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(deviceSyncControllerProvider).devices;
    final matches = devices.where((item) => item.deviceId == deviceId);
    if (matches.isEmpty) return const SizedBox.shrink();
    final device = matches.single;
    final controller = ref.read(deviceSyncControllerProvider.notifier);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.regular, 0, AppSpacing.regular, AppSpacing.regular),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(device.label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.compact),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动同步'),
              subtitle: const Text('两端都打开后自动检查变化'),
              value: device.autoSync,
              onChanged: (value) => controller.updateDeviceSettings(device.deviceId, autoSync: value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('数据源插件'),
              subtitle: const Text('包含正式插件和开发书源副本'),
              value: device.syncPlugins,
              onChanged: (value) => controller.updateDeviceSettings(device.deviceId, syncPlugins: value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('书架与阅读进度'),
              subtitle: const Text('智能合并更新，不同步删除'),
              value: device.syncBookshelf,
              onChanged: (value) => controller.updateDeviceSettings(device.deviceId, syncBookshelf: value),
            ),
            const SizedBox(height: AppSpacing.compact),
            Text('同步方向', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: AppSpacing.compact),
            SegmentedButton<PairedSyncMode>(
              segments: const <ButtonSegment<PairedSyncMode>>[
                ButtonSegment(value: PairedSyncMode.bidirectional, label: Text('双向')),
                ButtonSegment(value: PairedSyncMode.receiveOnly, label: Text('仅接收')),
                ButtonSegment(value: PairedSyncMode.sendOnly, label: Text('仅发送')),
              ],
              selected: <PairedSyncMode>{device.mode},
              onSelectionChanged: (value) => controller.updateDeviceSettings(device.deviceId, mode: value.single),
            ),
            const SizedBox(height: AppSpacing.regular),
            TextButton.icon(
              key: const Key('device-sync-remove-device'),
              onPressed: () => _confirmRemove(context, controller, device),
              icon: const Icon(Icons.link_off_rounded),
              label: const Text('解除配对'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, DeviceSyncController controller, PairedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解除配对？'),
        content: Text('将删除 ${device.label} 的本机信任密钥。另一台设备也需要单独解除配对。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('解除')),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.removeDevice(device.deviceId);
    if (context.mounted) Navigator.pop(context);
  }
}

String _lastSyncText(PairedDevice device) {
  final local = device.lastSyncAtUtc!.toLocal();
  final minute = local.minute.toString().padLeft(2, '0');
  final result = switch (device.lastSyncResult) {
    PairedSyncResultState.success => '成功',
    PairedSyncResultState.partial => '部分完成',
    PairedSyncResultState.failed => '失败',
    PairedSyncResultState.cancelled => '已取消',
    null => '未知',
  };
  return '上次同步 ${local.month}/${local.day} ${local.hour}:$minute · $result';
}
