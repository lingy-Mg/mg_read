/// 已配对设备的首次配对面板和逐设备策略编辑。
///

/// 本文件只负责交互呈现；发现、密钥和同步事务仍由 DeviceSyncController 持有。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mg_read/app/app_theme.dart';
import 'package:mg_read/features/lan_sync/application/device_sync_controller.dart';
import 'package:mg_read/features/lan_sync/domain/lan_pairing_payload.dart';
import 'package:mg_read/features/lan_sync/domain/paired_device_models.dart';

import 'lan_sync_sheet_widgets.dart';
import 'lan_sync_qr_code.dart';

/// “添加设备”底部弹层的配对流程。
///
/// 只展示真实可用的本机配对码和控制器状态；未配对设备尚无发现协议，不能
/// 将已配对设备列表伪装成可配对的附近设备。
class DevicePairingSheet extends StatelessWidget {
  const DevicePairingSheet({
    required this.state,
    required this.onBeginPairing,
    required this.onApprovePairing,
    required this.onRejectPairing,
    required this.onCancelPairing,
    super.key,
  });

  final DeviceSyncState state;
  final VoidCallback onBeginPairing;
  final VoidCallback onApprovePairing;
  final VoidCallback onRejectPairing;
  final VoidCallback onCancelPairing;

  @override
  Widget build(BuildContext context) => LanSyncSheetFrame(
    title: '添加设备',
    description: '让另一台设备扫描本机配对码，确认后会建立长期同步关系。',
    onClose: onCancelPairing,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (state.pairingPhase == DevicePairingPhase.idle)
          const Center(
            child: Padding(padding: EdgeInsets.all(AppSpacing.regular), child: CircularProgressIndicator()),
          )
        else
          _PairingPanel(state: state, onApprove: onApprovePairing, onReject: onRejectPairing, onRetry: onBeginPairing),
        const SizedBox(height: AppSpacing.regular),
        Text(
          '若要连接另一台设备显示的配对码，请使用页面顶部的“扫码连接 / 接收”。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppThemeTokens.of(context).mutedText),
        ),
      ],
    ),
  );
}

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({required this.state, required this.onApprove, required this.onReject, required this.onRetry});

  final DeviceSyncState state;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final offer = state.pairingOffer;
    final AppThemeTokens tokens = AppThemeTokens.of(context);
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
              LanSyncQrCode(
                qrKey: const Key('device-sync-pairing-qr'),
                data: LanPairingQrPayload.encode(offer),
                semanticsLabel: 'MgRead 设备配对二维码',
              ),
              const SizedBox(height: AppSpacing.compact),
              const Text('二维码十分钟内有效。另一台设备扫码后，请核对双方验证码。'),
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
            ] else if (state.pairingPhase == DevicePairingPhase.completed) ...<Widget>[
              Icon(Icons.verified_rounded, color: tokens.success, size: 32),
              const SizedBox(height: AppSpacing.compact),
              const Text('配对完成。以后两端打开即可自动同步。'),
            ] else if (state.pairingPhase == DevicePairingPhase.failed) ...<Widget>[
              Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: AppSpacing.compact),
              Text(_pairingFailureMessage(state.lastErrorCode)),
              if (state.lastErrorDetails case final details?) ...<Widget>[
                const SizedBox(height: AppSpacing.compact),
                SelectableText(
                  '错误码：${state.lastErrorCode ?? 'device_pairing_failed'}\n$details',
                  key: const Key('device-pairing-error-details'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[FilledButton.tonal(onPressed: onRetry, child: const Text('重新配对'))],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _pairingFailureMessage(String? code) => switch (code) {
  'device_pairing_offer_expired' => '配对码已过期，请重新生成。',
  'lan_sync_wifi_required' => '手机未连接 Wi-Fi，无法开始配对。',
  'lan_sync_local_network_unavailable' || 'lan_sync_address_not_private' => '未检测到可用的私有局域网地址。',
  'lan_sync_connect_timeout' => '连接配对设备超时，请检查防火墙和局域网访问权限。',
  'lan_sync_http_failed' || 'lan_sync_connect_failed' => '无法建立局域网 HTTP 连接，请检查代理、防火墙和两端网络。',
  'lan_sync_pairing_invalid' || 'lan_sync_handshake_invalid' => '配对响应无效，请重新生成二维码。',
  'lan_sync_pairing_rejected' => '另一台设备已拒绝配对。',
  _ => '配对未完成，请根据下方错误信息检查后重试。',
};

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
              subtitle: const Text('单向同步，发送端覆盖本机数据'),
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
